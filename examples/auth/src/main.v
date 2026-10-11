module main

// Authentication — reference design (password hashing + JWT + API key).
//
// This REPLACES the misleading plaintext `password == password` check in the
// hexagonal example. Three real mechanisms, each for its right context — and
// ALL of them work today, on stdlib alone:
//
//   1. PASSWORD HASHING — never store or compare plaintext. `crypto.argon2`
//      (RFC 9106) provides argon2id with PHC-encoded output: random per-user
//      salt, parameters embedded in the string, constant-time verification.
//      (bcrypt/scrypt/pbkdf2 are also in the stdlib; argon2id is preferred.)
//      Argon2id is SLOW AND MEMORY-HARD BY DESIGN (~200 ms, 64 MiB at the
//      RFC defaults) — that is the security property, not a bug.
//
//   2. JWT (HMAC-SHA256) — stateless bearer token: header.payload.signature,
//      base64url, signed with a server secret. Verify signature AND `exp` in
//      constant time (a signature check without expiry is half a check).
//
//   3. API KEY — opaque high-entropy key for service-to-service. Store only
//      its hash; compare in constant time.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3/§4, docs/V_PERF_TOOLBOX.md):
//   - NEVER concatenate or interpolate — not even on the slow path. Response
//     bytes are appended straight into `out` (`core.append_str`/`wi`, §3b); the
//     login's JWT is base64url-encoded straight into `out` and signed over a
//     view of those bytes — no builder, no return-then-copy.
//   - VIEWS, NOT COPIES: password, API key and bearer token are zero-copy
//     views into the request buffer (`vbytes`); jwt_verify scans view windows
//     of the token — the HMAC and the base64 decoder only read them.
//   - PER-WORKER STATE, NOT PER-REQUEST OBJECTS (§4): the HMAC is keyed and the
//     SHA-256 digest allocated ONCE per worker (AuthState, built by make_state);
//     requests reuse them (`write`/`sum_into`/`checksum_into` never allocate).
//     MACs and their base64url land in stack arrays; the JWT payload decodes
//     into a bounded per-worker scratch (an oversized payload is rejected).
//   - Routing and the `Bearer ` prefix compare bytes IN PLACE by offsets —
//     no `.to_string()`, no `buf[a..b]` slice-marking.
//
// HOT PATH vs SLOW PATH — know which is which:
//   - `/token` (login) is DELIBERATELY SLOW: argon2id dominates at ~200 ms. On
//     epoll/kqueue it is OFFLOADED to a bounded per-worker pool and the
//     connection is PARKED (.suspend), so the worker is never blocked by a
//     login — a burst of logins cannot head-of-line-block other connections
//     (see offload_nix.c.v). Still rate-limit logins to bound CPU/memory.
//     argon2's 64 MiB and the password copy that crosses .suspend are its only
//     allocations: minting and framing the token allocate nothing.
//   - `/protected` and `/service` run PER REQUEST and allocate NOTHING
//     (test_hot_path_allocates_nothing holds them to it): static responses are
//     consts, the crypto state is per-worker, everything else is a view or a
//     stack array.
//
// CONSTANT-TIME COMPARISON is the cross-cutting rule: any secret comparison
// must not short-circuit, or timing leaks the secret. `hmac.equal()` for
// every token/hash check; argon2's verifier uses it internally.
import server
import core
import http1_1.request_parser
import http1_1.response
import crypto.argon2
import crypto.hmac
import crypto.rand
import crypto.sha256
import encoding.base64
import os
import strconv
import time

// ---- JWT signing key ---------------------------------------------------------
// The HMAC key comes from the environment, never from source: a key in a repo
// is a key anyone can mint tokens with. main() refuses to start without
// JWT_SECRET (>= 32 bytes), e.g. `JWT_SECRET=$(openssl rand -base64 32)`.
const jwt_secret_min_len = 32
const jwt_secret = load_jwt_secret()

// load_jwt_secret reads JWT_SECRET once at init. Unset or too short, it falls
// back to a random per-process key, so a token is never signed with a known
// value even where main()'s check is skipped (the tests call handle() directly).
fn load_jwt_secret() []u8 {
	s := os.getenv('JWT_SECRET')
	if s.len >= jwt_secret_min_len {
		return s.bytes()
	}
	return rand.bytes(jwt_secret_min_len) or { panic(err) }
}

// ---- password hashing (argon2id, RFC 9106) ---------------------------------
// The demo user's PHC hash is computed ONCE at init (~200 ms at the RFC
// defaults: t=3, m=64 MiB, p=4 — several seconds in a debug build). A real
// service stores this string at registration time; the random salt and the
// parameters live inside it.
const demo_password = 'correct horse battery staple' // demo only — never a const in production
const demo_password_phc = argon2.generate_from_password(demo_password.bytes()) or { panic(err) }

// verify_password re-derives the key with the salt+params embedded in the PHC
// string and compares in constant time. ~200 ms BY DESIGN — see header.
fn verify_password(password []u8, encoded_phc string) bool {
	argon2.compare_hash_and_password(password, unsafe { encoded_phc.str.vbytes(encoded_phc.len) }) or {
		return false
	}
	return true
}

// ---- per-worker state --------------------------------------------------------
// AuthState is this worker's make_state value, handed to every handler call as
// worker_state: what the routes would otherwise allocate per request, built
// ONCE per worker thread. The worker is single-threaded, so it needs no lock.
// The keyed HMAC state is equivalent to jwt_secret: treat it as the secret.
struct AuthState {
mut:
	jwt_mac  &hmac.Hmac[&sha256.Digest] // keyed with jwt_secret; write/sum_into never allocate
	key_hash &sha256.Digest             // the API-key digest; reset/write/checksum_into never allocate
	// payload is the decode scratch for a JWT payload segment of up to
	// jwt_payload_b64_max chars: that decodes to at most 3/4 as many bytes, and
	// the decoder writes up to 3 bytes beyond what it returns (4 for every 3).
	payload [jwt_payload_b64_max]u8
	pool    &HashPool // the argon2 offload pool (offload_nix.c.v); nil where logins verify inline
}

// new_auth_state keys the HMAC (two SHA-256 blocks) and allocates the digests;
// make_auth_state calls it once per worker.
fn new_auth_state(pool &HashPool) &AuthState {
	return &AuthState{
		jwt_mac:  hmac.new_hmac(sha256.new, jwt_secret)
		key_hash: sha256.new()
		pool:     pool
	}
}

// auth_state returns this worker's AuthState. worker_state is nil only when
// handle() runs without make_state — the unit tests: they get a fresh state per
// call (it allocates, but nothing is shared). main() always sets make_state.
fn auth_state(worker_state voidptr) &AuthState {
	if worker_state != unsafe { nil } {
		return unsafe { &AuthState(worker_state) }
	}
	return new_auth_state(unsafe { nil })
}

// ---- base64url (RFC 7515 §2: URL-safe alphabet, no padding) ------------------
// b64url_encode writes the base64url form of `data` to `dst` and returns its
// length. `dst` needs 4 * ((data.len + 2) / 3) bytes. vlib's encode_in_buffer
// writes standard base64 without allocating; the alphabet swap (`+/` -> `-_`)
// and the padding trim happen in place.
@[direct_array_access]
fn b64url_encode(data []u8, dst &u8) int {
	mut n := base64.encode_in_buffer(data, dst)
	mut b := unsafe { dst.vbytes(n) }
	for n > 0 && b[n - 1] == `=` {
		n--
	}
	for i in 0 .. n {
		if b[i] == `+` {
			b[i] = `-`
		} else if b[i] == `/` {
			b[i] = `_`
		}
	}
	return n
}

// b64url_len is the length of the base64url form of n bytes.
fn b64url_len(n int) int {
	return (4 * n + 2) / 3
}

// append_b64url appends the base64url form of `data` to `out`: it is encoded
// in `out`'s spare capacity, then `out.len` is rolled back over the padding.
fn append_b64url(mut out []u8, data []u8) {
	start := out.len
	unsafe { out.grow_len(4 * ((data.len + 2) / 3)) }
	n := b64url_encode(data, unsafe { &u8(out.data) + start })
	unsafe {
		out.len = start + n
	}
}

// b64url_decode decodes the base64url `src` into `dst` without allocating and
// returns the decoded length, or -1 when no base64 has that length (len % 4 ==
// 1). vlib's decoder already maps `-` and `_`, but decodes whole 4-char quads
// only: those decode straight from `src`, and a 2-3 char tail from a
// `=`-padded stack quad. `dst` needs src.len * 3 / 4 + 3 bytes (see AuthState).
@[direct_array_access]
fn b64url_decode(src []u8, dst &u8) int {
	whole := src.len & ~3
	tail := src.len & 3
	if tail == 1 {
		return -1
	}
	mut n := 0
	if whole > 0 {
		n = base64.decode_in_buffer_bytes(unsafe { (&src[0]).vbytes(whole) }, dst)
	}
	if tail > 0 {
		mut quad := [u8(`=`), `=`, `=`, `=`]!
		for i in 0 .. tail {
			quad[i] = src[whole + i]
		}
		n += base64.decode_in_buffer_bytes(unsafe { (&quad[0]).vbytes(4) }, unsafe { dst + n })
	}
	return n
}

// ---- JWT (HS256) -----------------------------------------------------------
// The JOSE header never changes — encode it ONCE at init.
const jwt_header_b64 = base64.url_encode('{"alg":"HS256","typ":"JWT"}'.bytes())

// A 32-byte HMAC-SHA256 is 43 base64url chars (44 with the one `=` it drops).
const jwt_sig_b64_len = 43

// jwt_payload_b64_max bounds the payload segment a token may carry. The tokens
// this server mints carry ~47 chars; a longer payload is rejected before it is
// decoded, so it always fits the fixed per-worker scratch (AuthState.payload).
const jwt_payload_b64_max = 512

// The claims of every token we mint (the demo user's), up to the expiry digits.
const jwt_claims_head = '{"sub":"user-42","exp":'

// jwt_len is the length of a token whose payload is payload_len bytes.
fn jwt_len(payload_len int) int {
	return jwt_header_b64.len + 1 + b64url_len(payload_len) + 1 + jwt_sig_b64_len
}

// append_jwt appends the compact JWS `header.payload.signature` (RFC 7515 §7.1)
// to `out` in one pass: header and payload are base64url-encoded straight into
// `out`, the worker's keyed HMAC signs a VIEW of those bytes, and the encoded
// MAC follows — jwt_len(payload.len) bytes, no intermediate buffer, no allocation.
fn append_jwt(mut out []u8, mut st AuthState, payload []u8) {
	start := out.len
	core.append_str(mut out, jwt_header_b64)
	out << `.`
	append_b64url(mut out, payload)
	st.jwt_mac.write(unsafe { (&out[start]).vbytes(out.len - start) }) or {}
	mut mac := [sha256.size]u8{}
	st.jwt_mac.sum_into(mut unsafe { (&mac[0]).vbytes(mac.len) })
	out << `.`
	append_b64url(mut out, unsafe { (&mac[0]).vbytes(mac.len) })
}

// exp_of extracts the numeric `exp` claim from the decoded payload, or -1.
// A byte scan instead of json.decode: the only claim we enforce is a number.
@[direct_array_access]
fn exp_of(payload []u8) i64 {
	pat := '"exp":'
	if payload.len < pat.len {
		return -1
	}
	for i in 0 .. payload.len - pat.len + 1 {
		mut j := 0
		for j < pat.len && payload[i + j] == pat[j] {
			j++
		}
		if j < pat.len {
			continue
		}
		mut k := i + pat.len
		for k < payload.len && payload[k] == ` ` {
			k++
		}
		mut v := i64(0)
		mut digits := 0
		for k < payload.len && payload[k] >= `0` && payload[k] <= `9` {
			v = v * 10 + (payload[k] - `0`)
			k++
			digits++
		}
		return if digits > 0 { v } else { i64(-1) }
	}
	return -1
}

// jwt_verify checks the signature in constant time, then REQUIRES a future
// `exp` claim — a token that never expires is rejected, not trusted forever.
// The token is scanned in place: `vbytes` views of it feed the HMAC and the
// base64 decoder (they only read), the MAC and its encoding are stack arrays,
// and the payload decodes into the worker's scratch — no allocation.
@[direct_array_access]
fn jwt_verify(mut st AuthState, token []u8) bool {
	if token.len < 5 { // shortest possible h.p.s
		return false
	}
	mut first := -1
	mut last := -1
	mut dots := 0
	for i in 0 .. token.len {
		if token[i] == `.` {
			dots++
			if dots == 1 {
				first = i
			} else {
				last = i
			}
		}
	}
	if dots != 2 || first == 0 || last == first + 1 || last == token.len - 1 {
		return false
	}
	payload_len := last - first - 1
	if payload_len > jwt_payload_b64_max {
		return false // longer than any token we mint: never decoded
	}
	st.jwt_mac.write(unsafe { (&token[0]).vbytes(last) }) or { return false } // view: "header.payload"
	mut mac := [sha256.size]u8{}
	st.jwt_mac.sum_into(mut unsafe { (&mac[0]).vbytes(mac.len) })
	// Compare in the ENCODED domain (constant-time): re-encode the expected
	// MAC and match the presented base64url bytes exactly. Comparing DECODED
	// bytes silently accepts non-canonical encodings — a 32-byte MAC leaves 2
	// free padding bits in the 43rd base64url char, so every token would have
	// 4 accepted spellings (RFC 8725 token-malleability; it also made the
	// tamper test flake whenever the flipped bit landed in the padding).
	mut expected := [jwt_sig_b64_len + 1]u8{}
	n := b64url_encode(unsafe { (&mac[0]).vbytes(mac.len) }, &expected[0])
	if !hmac.equal(unsafe { (&expected[0]).vbytes(n) }, unsafe { (&token[last + 1]).vbytes(token.len - last - 1) }) {
		return false
	}
	decoded := b64url_decode(unsafe { (&token[first + 1]).vbytes(payload_len) }, &st.payload[0])
	if decoded < 0 {
		return false
	}
	exp := exp_of(unsafe { (&st.payload[0]).vbytes(decoded) })
	return exp > 0 && exp > time.unix_now()
}

// ---- API key ---------------------------------------------------------------
// Store only the hash of issued keys; never the keys themselves.
const known_api_key_hash = sha256.sum('secret-api-key-123'.bytes())

// check_api_key hashes the presented key with the worker's digest (reset, write,
// checksum into a stack array — no allocation) and compares in constant time.
fn check_api_key(mut st AuthState, key []u8) bool {
	st.key_hash.reset()
	st.key_hash.write(key) or { return false }
	mut sum := [sha256.size]u8{}
	st.key_hash.checksum_into(mut unsafe { (&sum[0]).vbytes(sum.len) })
	return hmac.equal(unsafe { (&sum[0]).vbytes(sum.len) }, known_api_key_hash)
}

// ---- static responses (consts — the fast path appends, never builds) -------
const resp_ok_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_401_bearer = 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_401 = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// write_token_200 mints a fresh JWT and appends the 200 response in ONE pass:
// the token's length follows from the claims' length (jwt_len), so
// Content-Length goes first and append_jwt then encodes and signs the token
// straight into `out`. Shared by the synchronous /token path (fallback) and the
// async resume (token_done) so both emit BYTE-IDENTICAL responses.
fn write_token_200(mut out []u8, mut st AuthState) {
	// The claims, {"sub":"user-42","exp":<now + 1 h>}, in a stack scratch: the
	// base64url encoder only reads them.
	mut claims := [64]u8{}
	unsafe { vmemcpy(&claims[0], jwt_claims_head.str, jwt_claims_head.len) }
	mut n := jwt_claims_head.len
	n += strconv.write_dec(time.unix_now() + 3600, mut unsafe { (&claims[n]).vbytes(claims.len - n - 1) })
	claims[n] = `}`
	n++
	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, jwt_len(n) + 12) // len of {"token":""} wrapper = 12
	core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n{"token":"')
	append_jwt(mut out, mut st, unsafe { (&claims[0]).vbytes(n) })
	core.append_str(mut out, '"}')
}

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// ---- routing ---------------------------------------------------------------
// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// bearer_token returns a zero-copy VIEW of the token bytes after `Bearer `
// (scheme match case-insensitive, RFC 9110 §11.1 — `| 0x20` lowercases ASCII
// letters). The view borrows the request buffer `buf` (handle()'s own
// parameter, so `req` stays on the stack); the handler finishes with it
// before the buffer is recycled, so nothing needs to be copied.
@[direct_array_access]
fn bearer_token(buf []u8, req request_parser.HttpRequest) []u8 {
	s := req.get_header_value_slice('Authorization') or { return []u8{} }
	prefix := 'bearer '
	if s.len <= prefix.len {
		return []u8{}
	}
	for i in 0 .. prefix.len {
		if (buf[s.start + i] | 0x20) != prefix[i] {
			return []u8{}
		}
	}
	return unsafe { (&buf[s.start + prefix.len]).vbytes(s.len - prefix.len) }
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req_buffer, req.path, '/token') {
		// LOGIN — argon2id (~200 ms, 64 MiB) verifies the password. It is CPU-heavy
		// and memory-hard BY DESIGN, so running it INLINE would block this worker
		// for the whole span, head-of-line-blocking every other connection the
		// worker is holding. Instead we OFFLOAD the verify to a bounded per-worker
		// pool and PARK the connection (.suspend): the worker keeps serving others
		// and resumes this one (token_done) once the verdict is ready. Offload is
		// epoll/kqueue only, and only when a pool exists — the unit test calls
		// handle() with worker_state == nil and reads the response on return, so
		// that path stays synchronous. See offload_nix.c.v.
		if !slice_eq(req_buffer, req.method, 'POST') {
			core.append_str(mut out, resp_405)
			return .done
		}
		if req.body.len <= 0 {
			core.append_str(mut out, resp_401) // empty password: reject before paying for argon2
			return .done
		}
		password := unsafe { (&req_buffer[req.body.start]).vbytes(req.body.len) } // view
		mut st := auth_state(worker_state)
		$if !windows {
			if st.pool != unsafe { nil } {
				// try_offload copies the password OUT of the request buffer (the
				// view dies at .suspend), queues the verify on the pool, and arms
				// the resume on the pipe the pool signals.
				if try_offload(st.pool, password, mut event_loop) {
					return .suspend
				}
				core.append_str(mut out, resp_503) // pool saturated: shed load rather than block the worker
				return .done
			}
		}
		// Fallback — synchronous verify on this worker. Taken by the unit test
		// (nil worker_state) and by any backend with no watch reactor (IOCP).
		if !verify_password(password, demo_password_phc) {
			core.append_str(mut out, resp_401)
			return .done
		}
		write_token_200(mut out, mut st)
	} else if slice_eq(req_buffer, req.path, '/protected') {
		// FAST PATH — per-request JWT check over a view, const responses.
		mut st := auth_state(worker_state)
		if !jwt_verify(mut st, bearer_token(req_buffer, req)) {
			core.append_str(mut out, resp_401_bearer)
			return .done
		}
		core.append_str(mut out, resp_ok_empty)
	} else if slice_eq(req_buffer, req.path, '/service') {
		// FAST PATH — API-key check over a view of the header bytes.
		s := req.get_header_value_slice('X-API-Key') or {
			core.append_str(mut out, resp_401)
			return .done
		}
		if s.len <= 0 {
			core.append_str(mut out, resp_401)
			return .done
		}
		key := unsafe { (&req_buffer[s.start]).vbytes(s.len) } // view
		mut st := auth_state(worker_state)
		if !check_api_key(mut st, key) {
			core.append_str(mut out, resp_401)
			return .done
		}
		core.append_str(mut out, resp_ok_empty)
	} else {
		core.append_str(mut out, resp_404)
	}
	return .done
}

fn main() {
	// A per-process random key would make every token die with the process and
	// differ between replicas: require the real one instead of starting with it.
	if os.getenv('JWT_SECRET').len < jwt_secret_min_len {
		eprintln('JWT_SECRET must be set to at least ${jwt_secret_min_len} random bytes, e.g.')
		eprintln('  JWT_SECRET=$(openssl rand -base64 32) v run examples/auth/src')
		exit(1)
	}
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
		// Per-worker AuthState: the keyed HMAC and API-key digest every request
		// reuses, plus the argon2 offload pool (real on epoll/kqueue; none on
		// Windows, where handle falls back to a synchronous verify).
		make_state:      make_auth_state
	})!
	println('Auth demo on http://localhost:3000/')
	println('  POST /token      (body = password)           -> JWT')
	println('  GET  /protected  (Authorization: Bearer ..)  -> 200/401')
	println('  GET  /service    (X-API-Key: ..)             -> 200/401')
	print('  demo password: ')
	println(demo_password)
	srv.run()
}
