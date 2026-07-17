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
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3):
//   - The Cookie header is scanned IN PLACE by offsets (cookie_value) — no
//     split(), no map[string]string, no substr copies per request.
//   - The sid reaches the store lookup as a `tos` VIEW of the request buffer;
//     the map only hashes/compares the key bytes and never retains them.
//   - Static responses are consts; /login and /me frame their one dynamic part
//     with ws/wi straight into `out` — no `${}`, no `+`, no body string.
//   - The only per-request-path allocations left are Store.create's owned
//     strings, and those run per LOGIN, not per request (see new_token).
import server
import core
import http1_1.request_parser
import http1_1.response
import sync
import crypto.rand
import encoding.hex
import strconv

struct Session {
	user_id    string
	csrf_token string
}

struct Store {
mut:
	mu       &sync.RwMutex = sync.new_rwmutex()
	sessions map[string]Session
}

// create mints a session keyed by a fresh CSPRNG id. The id and token are
// OWNED strings on purpose: they live in the store beyond this request, so a
// view into the request buffer could never back them (use-after-free). This
// allocates — acceptably: it runs once per login, not per request.
fn (mut s Store) create(user_id string) string {
	id := new_token()
	s.mu.lock()
	s.sessions[id] = Session{
		user_id:    user_id
		csrf_token: new_token()
	}
	s.mu.unlock()
	return id
}

// get looks a session up by id. The caller may pass a `tos` VIEW into the
// request buffer: a map lookup only hashes/compares the key bytes and never
// retains the key (static_assets uses the same pattern for
// zero-alloc routing), so the view never escapes.
fn (mut s Store) get(id string) ?Session {
	s.mu.rlock()
	defer { s.mu.runlock() }
	return s.sessions[id] or { return none }
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
const resp_401 = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'.bytes()
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'.bytes()
// /logout is FULLY static — expiring the cookie is the same bytes every time,
// so the complete response is one const (BEST_PRACTICES §3a).
const resp_logout = 'HTTP/1.1 200 OK\r\nSet-Cookie: sid=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0\r\nContent-Length: 0\r\n\r\n'.bytes()
// /login is const-around-dynamic: everything except the 64-hex sid is literal.
// Set-Cookie precedes Content-Length, so the length header stays a literal 0.
const resp_login_prefix = 'HTTP/1.1 200 OK\r\nSet-Cookie: sid='.bytes()
const resp_login_suffix = '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400\r\nContent-Length: 0\r\n\r\n'.bytes()
const resp_me_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()

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

fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut store Store) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req.buffer, req.path, '/login') {
		// (Authenticate first — see examples/auth.) Then mint a session.
		sid := store.create('user-42')
		// Note ALL the security attributes on the Set-Cookie: two consts with
		// the sid appended between them — the only dynamic bytes in the reply.
		out << resp_login_prefix
		ws(mut out, sid)
		out << resp_login_suffix
	} else if slice_eq(req.buffer, req.path, '/me') {
		c := req.get_header_value_slice('Cookie') or {
			out << resp_401
			return .done
		}
		vstart, vlen := cookie_value(req.buffer, c.start, c.len, 'sid')
		if vlen <= 0 { // absent or empty sid — also guards &buf[vstart] below
			out << resp_401
			return .done
		}
		// Zero-copy lookup key: a string VIEW into the request buffer. Only
		// valid because get() never retains it — see the Store.get comment.
		sid := unsafe { tos(&req.buffer[vstart], vlen) }
		sess := store.get(sid) or {
			out << resp_401
			return .done
		}
		// {"user":"<id>"} — const head, computed Content-Length via wi, then
		// the three body parts via ws. No intermediate body string (§3b).
		out << resp_me_prefix
		wi(mut out, i64(sess.user_id.len + 11)) // 11 = len('{"user":"') + len('"}')
		ws(mut out, '\r\n\r\n{"user":"')
		ws(mut out, sess.user_id)
		ws(mut out, '"}')
	} else if slice_eq(req.buffer, req.path, '/logout') {
		// Expire the cookie (Max-Age=0). A real impl also deletes the
		// server-side session — the cookie alone is just the client half.
		out << resp_logout
	} else {
		out << resp_404
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
	println('Cookies/sessions demo on http://localhost:3000/  (/login, /me, /logout)')
	srv.run()
}
