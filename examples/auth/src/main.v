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
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - NEVER concatenate or interpolate — not even on the slow path. Response
//     bytes are appended straight into `out` (`ws`/`wi`, §3b); the JWT is
//     assembled in ONE strings.Builder, no `+`, no `${}`.
//   - VIEWS, NOT COPIES: password, API key and bearer token are zero-copy
//     views into the request buffer (`vbytes`); jwt_verify scans view
//     sub-strings of the token (`tos`) — base64/hmac only read them, never
//     retain them. Bytes are allocated only where an output must exist
//     (base64 encode/decode results, the signed token itself).
//   - Routing and the `Bearer ` prefix compare bytes IN PLACE by offsets —
//     no `.to_string()`, no `buf[a..b]` slice-marking.
//
// HOT PATH vs SLOW PATH — know which is which:
//   - `/token` (login) is DELIBERATELY SLOW: argon2id dominates at ~200 ms. On
//     epoll/kqueue it is OFFLOADED to a bounded per-worker pool and the
//     connection is PARKED (.suspend), so the worker is never blocked by a
//     login — a burst of logins cannot head-of-line-block other connections
//     (see offload_nix.c.v). Still rate-limit logins to bound CPU/memory.
//   - `/protected` and `/service` run PER REQUEST: static responses are
//     consts; the only allocations left are the JWT format's own (split-free
//     scan, but base64 decode must produce bytes).
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
import crypto.sha256
import encoding.base64
import strconv
import strings
import time

const jwt_secret = 'change-me-in-production'.bytes()

// ---- password hashing (argon2id, RFC 9106) ---------------------------------
// The demo user's PHC hash is computed ONCE at init (~200 ms at the RFC
// defaults: t=3, m=64 MiB, p=4 — several seconds in a debug build). A real
// service stores this string at registration time; the random salt and the
// parameters live inside it.
const demo_user = 'user-42'
const demo_password = 'correct horse battery staple' // demo only — never a const in production
const demo_password_phc = argon2.generate_from_password(demo_password.bytes()) or { panic(err) }

// verify_password re-derives the key with the salt+params embedded in the PHC
// string and compares in constant time. ~200 ms BY DESIGN — see header.
fn verify_password(password []u8, encoded_phc string) bool {
	argon2.compare_hash_and_password(password, encoded_phc.bytes()) or { return false }
	return true
}

// ---- JWT (HS256) -----------------------------------------------------------
// The JOSE header never changes — encode it ONCE at init.
const jwt_header_b64 = base64.url_encode('{"alg":"HS256","typ":"JWT"}'.bytes())

// jwt_sign assembles the compact JWS (header.payload.signature) in a single
// builder: sign the builder's bytes in place (Builder IS []u8), then append
// the signature. No intermediate strings, no concatenation.
fn jwt_sign(payload []u8) []u8 {
	mut sb := strings.new_builder(96 + payload.len * 2)
	sb.write_string(jwt_header_b64)
	sb.write_u8(`.`)
	sb.write_string(base64.url_encode(payload))
	sig := hmac.new(jwt_secret, sb, sha256.sum, sha256.block_size)
	sb.write_u8(`.`)
	sb.write_string(base64.url_encode(sig))
	return sb
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
// The token is scanned in place: `vbytes`/`tos` views feed hmac and base64
// (they only read), so verification adds no split() garbage — the only
// allocations are the two base64 decode outputs.
@[direct_array_access]
fn jwt_verify(token []u8) bool {
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
	signing := unsafe { (&token[0]).vbytes(last) } // view: "header.payload"
	expected := hmac.new(jwt_secret, signing, sha256.sum, sha256.block_size)
	sig_b64 := unsafe { tos(&token[last + 1], token.len - last - 1) } // view string
	if !hmac.equal(expected, base64.url_decode(sig_b64)) {
		return false
	}
	payload_b64 := unsafe { tos(&token[first + 1], last - first - 1) } // view string
	exp := exp_of(base64.url_decode(payload_b64))
	return exp > 0 && exp > time.unix_now()
}

// ---- API key ---------------------------------------------------------------
// Store only the hash of issued keys; never the keys themselves.
const known_api_key_hash = sha256.sum('secret-api-key-123'.bytes())

fn check_api_key(key []u8) bool {
	return hmac.equal(sha256.sum(key), known_api_key_hash)
}

// ---- static responses (consts — the fast path appends, never builds) -------
const resp_ok_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_401_bearer = 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_401 = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// write_token_200 mints a fresh JWT and appends the 200 response. Shared by the
// synchronous /token path (fallback) and the async resume (token_done) so both
// emit BYTE-IDENTICAL responses. Reads only consts + time; safe off any stack.
fn write_token_200(mut out []u8) {
	mut payload := strings.new_builder(48)
	payload.write_string('{"sub":"')
	payload.write_string(demo_user)
	payload.write_string('","exp":')
	payload.write_decimal(time.unix_now() + 3600)
	payload.write_u8(`}`)
	token := jwt_sign(payload)
	ws(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, token.len + 12) // len of {"token":""} wrapper = 12
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"token":"')
	out << token
	ws(mut out, '"}')
}

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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
// letters). The view borrows the request buffer; the handler finishes with it
// before the buffer is recycled, so nothing needs to be copied.
@[direct_array_access]
fn bearer_token(req request_parser.HttpRequest) []u8 {
	s := req.get_header_value_slice('Authorization') or { return []u8{} }
	prefix := 'bearer '
	if s.len <= prefix.len {
		return []u8{}
	}
	for i in 0 .. prefix.len {
		if (req.buffer[s.start + i] | 0x20) != prefix[i] {
			return []u8{}
		}
	}
	return unsafe { (&req.buffer[s.start + prefix.len]).vbytes(s.len - prefix.len) }
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req.buffer, req.path, '/token') {
		// LOGIN — argon2id (~200 ms, 64 MiB) verifies the password. It is CPU-heavy
		// and memory-hard BY DESIGN, so running it INLINE would block this worker
		// for the whole span, head-of-line-blocking every other connection the
		// worker is holding. Instead we OFFLOAD the verify to a bounded per-worker
		// pool and PARK the connection (.suspend): the worker keeps serving others
		// and resumes this one (token_done) once the verdict is ready. Offload is
		// epoll/kqueue only, and only when a pool exists — the unit test calls
		// handle() with worker_state == nil and reads the response on return, so
		// that path stays synchronous. See offload_nix.c.v.
		if !slice_eq(req.buffer, req.method, 'POST') {
			out << resp_405
			return .done
		}
		if req.body.len <= 0 {
			out << resp_401 // empty password: reject before paying for argon2
			return .done
		}
		password := unsafe { (&req.buffer[req.body.start]).vbytes(req.body.len) } // view
		$if !windows {
			if worker_state != unsafe { nil } {
				// try_offload copies the password OUT of the request buffer (the
				// view dies at .suspend), queues the verify on the pool, and arms
				// the resume on the pipe the pool signals.
				if try_offload(worker_state, password, mut event_loop) {
					return .suspend
				}
				out << resp_503 // pool saturated: shed load rather than block the worker
				return .done
			}
		}
		// Fallback — synchronous verify on this worker. Taken by the unit test
		// (nil worker_state) and by any backend with no watch reactor (IOCP).
		if !verify_password(password, demo_password_phc) {
			out << resp_401
			return .done
		}
		write_token_200(mut out)
	} else if slice_eq(req.buffer, req.path, '/protected') {
		// FAST PATH — per-request JWT check over a view, const responses.
		if !jwt_verify(bearer_token(req)) {
			out << resp_401_bearer
			return .done
		}
		out << resp_ok_empty
	} else if slice_eq(req.buffer, req.path, '/service') {
		// FAST PATH — API-key check over a view of the header bytes.
		s := req.get_header_value_slice('X-API-Key') or {
			out << resp_401
			return .done
		}
		if s.len <= 0 {
			out << resp_401
			return .done
		}
		key := unsafe { (&req.buffer[s.start]).vbytes(s.len) } // view
		if !check_api_key(key) {
			out << resp_401
			return .done
		}
		out << resp_ok_empty
	} else {
		out << resp_404
	}
	return .done
}

fn main() {
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
		// Per-worker argon2 offload pool (real on epoll/kqueue; a nil-returning
		// stub on Windows, where handle falls back to a synchronous verify).
		make_state: make_auth_state
	})!
	println('Auth demo on http://localhost:3000/')
	println('  POST /token      (body = password)           -> JWT')
	println('  GET  /protected  (Authorization: Bearer ..)  -> 200/401')
	println('  GET  /service    (X-API-Key: ..)             -> 200/401')
	print('  demo password: ')
	println(demo_password)
	srv.run()
}
