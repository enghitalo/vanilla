module main

// Cookies + sessions — reference design.
//
// HTTP is stateless; sessions bolt state on via a cookie carrying an opaque,
// unguessable id that keys server-side state. The cookie itself holds NO
// secrets — just the id.
//
// SECURITY ATTRIBUTES (all mandatory for a session cookie):
//   HttpOnly             — JS cannot read it (blunts XSS token theft)
//   Secure               — only sent over HTTPS
//   SameSite=Lax/Strict  — not sent on cross-site requests (CSRF defense)
//   Path=/; Max-Age=...   — scope + lifetime
//   The id must come from a CSPRNG (crypto.rand), never a counter or timestamp.
//
// Cookie handling is plain header work: the parser hands the Cookie value as a
// zero-copy Slice (get_header_value_slice) and Set-Cookie is just response
// bytes; crypto.rand + encoding.hex are stdlib. The only shared state is the
// session store (a mutex-guarded map here; Redis/db in production).
//
// THIS IS NOT AUTHENTICATION: `store.create('user-42')` stands in for a real
// credential check (see examples/auth). A server must never mint sessions for
// unauthenticated requests — /login is POST-only so that, behind that check,
// crawlers, prefetchers and `<img src>` cannot create them either.
//
// BOUNDED STATE: every session is a map entry, so an unbounded store is a
//   memory-exhaustion vector (#280). Each session carries a server-side expiry
//   from the SAME constant as the cookie's Max-Age (the cookie's lifetime is
//   only a client-side hint): get() treats an expired entry as absent, a lazy
//   sweep inside create() drops them, /logout deletes its entry, and
//   `max_sessions` caps the table on top, failing CLOSED (503) for new logins
//   while it is full — never evicting a live user's session to make room. The
//   cap bounds memory; it is not a rate limiter (pair with examples/rate_limit).
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3):
//   - The Cookie header is scanned IN PLACE by offsets (cookie_value) — no
//     split(), no map[string]string, no substr copies per request.
//   - The sid reaches the store lookup as a `tos` VIEW of the request buffer;
//     the map only hashes/compares the key bytes and never retains them.
//   - Static responses are consts; /login and /me frame their one dynamic part
//     with core.append_str/wi straight into `out` — no `${}`, no `+`, no body string.
//   - The only per-request-path allocations left are Store.create's owned
//     strings: one session per successful POST /login, bounded by
//     `max_sessions` (see new_token).
import server
import core
import http1_1.request_parser
import http1_1.response
import sync
import crypto.rand
import encoding.hex
import strconv
import time

// Session lifetime: ONE constant feeds both the server-side expiry and the
// cookie's Max-Age (resp_login_suffix), so the two can never drift.
const session_ttl_s = 86400
const session_ttl_ns = i64(session_ttl_s) * 1_000_000_000
// Expired sessions are swept at most this often; a full store also answers
// `Retry-After` with it, since a sweep is the earliest room can appear.
const sweep_every_s = 60
const sweep_every_ns = i64(sweep_every_s) * 1_000_000_000

struct Session {
	user_id    string
	csrf_token string
	expires_ns i64 // monotonic ns; past this the session is gone
}

struct Store {
	max_sessions int = 100_000 // hard cap (~0.5 KB resident each, measured)
mut:
	mu         &sync.RwMutex = sync.new_rwmutex()
	sessions   map[string]Session
	next_sweep i64 // monotonic ns of the next expiry sweep
}

// create mints a session keyed by a fresh CSPRNG id, or returns none when the
// store is full. The id and token are OWNED strings on purpose: they live in
// the store beyond this request, so a view into the request buffer could never
// back them (use-after-free). This allocates — once per successful login.
//
// The clock is INJECTED (`now`, monotonic ns — handle() passes
// `time.sys_mono_now()`), so tests drive expiry without sleeping.
fn (mut s Store) create(user_id string, now i64) ?string {
	s.mu.lock()
	defer { s.mu.unlock() }
	// Expiry sweep, at most once per sweep_every_ns: its O(n) walk runs under
	// the write lock create() already holds, amortized over every login in
	// that window — no extra thread, no cost on the /me read path.
	if now >= s.next_sweep {
		s.sweep(now)
		s.next_sweep = now + sweep_every_ns
	}
	if s.sessions.len >= s.max_sessions {
		// Full: fail CLOSED until a sweep frees room. Evicting live sessions
		// instead would let an anonymous flood log real users out.
		return none
	}
	id := new_token()
	s.sessions[id] = Session{
		user_id:    user_id
		csrf_token: new_token()
		expires_ns: now + session_ttl_ns
	}
	return id
}

// get looks a session up by id; an expired one is absent. The caller may pass
// a `tos` VIEW into the request buffer: a map lookup only hashes/compares the
// key bytes and never retains the key (static_assets uses the same pattern for
// zero-alloc routing), so the view never escapes.
fn (mut s Store) get(id string, now i64) ?Session {
	s.mu.rlock()
	defer { s.mu.runlock() }
	sess := s.sessions[id] or { return none }
	if now >= sess.expires_ns {
		return none // the sweep reclaims it; a read lock cannot delete
	}
	return sess
}

// delete drops a session (logout). Like get(), it takes a `tos` view: map
// delete only hashes/compares the key and never retains it.
fn (mut s Store) delete(id string) {
	s.mu.lock()
	s.sessions.delete(id)
	s.mu.unlock()
}

// sweep drops every expired session. Caller holds the write lock. Deleting
// inside the loop is safe: V's map iteration tolerates it (as in
// examples/rate_limit's sweep).
fn (mut s Store) sweep(now i64) {
	for id, sess in s.sessions {
		if now >= sess.expires_ns {
			s.sessions.delete(id)
		}
	}
}

// CSPRNG token — 32 bytes of entropy, hex-encoded. Never a predictable value.
// rand.bytes + hex.encode allocate; that is fine here — the token must outlive
// the request as a map key (string API), and this runs per login/session mint.
fn new_token() string {
	buf := rand.bytes(32) or { panic('csprng unavailable') }
	return hex.encode(buf)
}

// cookie_value scans the Cookie header value — addressed by OFFSETS into the
// request buffer, never `buf[a..b]` (V array slicing marks the source buffer
// per call; see docs/V_PERF_TOOLBOX.md) — for cookie `name` and returns the
// (start, len) of its value, or (-1, 0) when absent. Returning offsets keeps
// the scanner unit-testable AND copy-free: the caller materializes a view only
// on a hit. Matching rules:
//   - pairs are delimited by ';' with optional whitespace (RFC 6265 says '; ',
//     real clients vary — be lenient in what you accept);
//   - the name must sit at a pair boundary and be terminated by '=' — a WHOLE
//     token, so `xsid=` never matches `sid`, and a `sid=` inside another
//     cookie's VALUE never matches either (non-matching pairs are skipped
//     whole);
//   - names are case-SENSITIVE (RFC 6265 — cookie names are exact bytes;
//     contrast the `| 0x20` case-insensitive scan in examples/compression,
//     which is for RFC 9110 content-coding tokens);
//   - the value runs to the next ';' or the end — '=' inside a value is data.
// In-bounds by construction: the parser guarantees start/len sit inside buf.
@[direct_array_access]
fn cookie_value(buf []u8, start int, len int, name string) (int, int) {
	if name.len == 0 || len <= name.len {
		return -1, 0
	}
	end := start + len
	mut i := start
	for i < end {
		// Skip pair delimiters: ';' plus optional whitespace.
		for i < end && (buf[i] == `;` || buf[i] == ` ` || buf[i] == 9) {
			i++
		}
		if i >= end {
			break
		}
		// Whole-token name match at the pair boundary, terminated by '='.
		mut j := 0
		for j < name.len && i + j < end && buf[i + j] == name[j] {
			j++
		}
		if j == name.len && i + j < end && buf[i + j] == `=` {
			vstart := i + j + 1
			mut vend := vstart
			for vend < end && buf[vend] != `;` {
				vend++
			}
			return vstart, vend - vstart
		}
		// Not this pair — skip it whole (to the next ';').
		for i < end && buf[i] != `;` {
			i++
		}
	}
	return -1, 0
}

// ---- static responses (consts — the handler appends, never builds) ---------
const resp_401 = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
// /login changes server state, so it is POST-only (RFC 9110 §15.5.6: 405 must
// list the allowed methods).
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\nContent-Length: 0\r\n\r\n'
// Store full (max_sessions): new logins fail closed until a sweep frees room.
// The `${}` here and in resp_login_suffix runs ONCE at const init, never per
// request.
const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nRetry-After: ${sweep_every_s}\r\nContent-Length: 0\r\n\r\n'
// /logout is FULLY static — expiring the cookie is the same bytes every time,
// so the complete response is one const (BEST_PRACTICES §3a).
const resp_logout = 'HTTP/1.1 200 OK\r\nSet-Cookie: sid=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0\r\nContent-Length: 0\r\n\r\n'
// /login is const-around-dynamic: everything except the 64-hex sid is literal.
// Set-Cookie precedes Content-Length, so the length header stays a literal 0.
const resp_login_prefix = 'HTTP/1.1 200 OK\r\nSet-Cookie: sid='
const resp_login_suffix = '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=${session_ttl_s}\r\nContent-Length: 0\r\n\r\n'
const resp_me_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '

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

// session_id returns the request's `sid` cookie as a zero-copy `tos` VIEW into
// the request buffer, or none when the header or the cookie is absent/empty.
// The view is only valid while the buffer is: pass it to lookups that never
// retain the key (Store.get / Store.delete), never store it.
fn session_id(req request_parser.HttpRequest) ?string {
	c := req.get_header_value_slice('Cookie') or { return none }
	vstart, vlen := cookie_value(req.buffer, c.start, c.len, 'sid')
	if vlen <= 0 { // absent or empty sid — also guards &buf[vstart] below
		return none
	}
	return unsafe { tos(&req.buffer[vstart], vlen) }
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut store Store) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req.buffer, req.path, '/login') {
		if !slice_eq(req.buffer, req.method, 'POST') {
			core.append_str(mut out, resp_405)
			return .done
		}
		// (Authenticate first — see examples/auth; answer 401 on failure.)
		// Only then mint a session.
		sid := store.create('user-42', i64(time.sys_mono_now())) or {
			core.append_str(mut out, resp_503)
			return .done
		}
		// Note ALL the security attributes on the Set-Cookie: two consts with
		// the sid appended between them — the only dynamic bytes in the reply.
		core.append_str(mut out, resp_login_prefix)
		core.append_str(mut out, sid)
		core.append_str(mut out, resp_login_suffix)
	} else if slice_eq(req.buffer, req.path, '/me') {
		// Zero-copy lookup key: a string VIEW into the request buffer. Only
		// valid because get() never retains it — see the Store.get comment.
		sid := session_id(req) or {
			core.append_str(mut out, resp_401)
			return .done
		}
		sess := store.get(sid, i64(time.sys_mono_now())) or {
			core.append_str(mut out, resp_401)
			return .done
		}
		// {"user":"<id>"} — const head, computed Content-Length via wi, then
		// the three body parts via core.append_str. No intermediate body string (§3b).
		core.append_str(mut out, resp_me_prefix)
		wi(mut out, i64(sess.user_id.len + 11)) // 11 = len('{"user":"') + len('"}')
		core.append_str(mut out, '\r\n\r\n{"user":"')
		core.append_str(mut out, sess.user_id)
		core.append_str(mut out, '"}')
	} else if slice_eq(req.buffer, req.path, '/logout') {
		// Delete the server-side session, then expire the cookie (Max-Age=0)
		// — the cookie alone is just the client half. A logout without a live
		// session still clears the cookie: logout is idempotent.
		if sid := session_id(req) {
			store.delete(sid)
		}
		core.append_str(mut out, resp_logout)
	} else {
		core.append_str(mut out, resp_404)
	}
	return .done
}

fn main() {
	mut store := &Store{}
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
		handler:         fn [mut store] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut store)
		}
	})!
	println('Cookies/sessions demo on http://localhost:3000/  (POST /login, /me, /logout)')
	srv.run()
}
