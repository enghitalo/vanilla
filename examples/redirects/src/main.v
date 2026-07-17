module main

// Redirects — reference design.
//
// Small but easy to get subtly wrong. The status code carries SEMANTICS:
//   301 Moved Permanently  — cacheable forever; SEO weight transfers. Method
//                            MAY change to GET (historically did).
//   302 Found              — temporary; method may change to GET.
//   303 See Other          — after a POST, send the client to a GET (the
//                            Post/Redirect/Get pattern that stops double-submits).
//   307 Temporary Redirect — temporary AND preserves method + body (a POST
//                            stays a POST).
//   308 Permanent Redirect — permanent AND preserves method + body.
//
// RULE OF THUMB: use 308/307 for API redirects (method-preserving), 303 after
// form POSTs, 301 for canonical URL moves.
//
// SECURITY: never build a redirect target from unvalidated user input
// (`?next=...`) without checking it against an allowlist — open redirects are a
// phishing primitive. The `safe_next` helper shows the guard.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - Every fully static response (301, 308, empty 200) is a module const —
//     the handler only APPENDS (`out << resp_...`), it never builds.
//   - The ONE dynamic response (303: Location echoes a validated `?next=`) is
//     framed with `ws` (push_many) around a zero-copy VIEW of the query value
//     — no `${}`, no `+`, no `.to_string()`.
//   - Routing compares bytes IN PLACE by offsets (`slice_eq`). req.path
//     INCLUDES the query string (the parser ends the request-target at the
//     first SP/CR; it does not split on `?`), so the route is the sub-slice up
//     to the first `?` (`route_len`) — otherwise `/old?utm=1` would miss `/old`.
//
// Everything here WORKS TODAY — redirects are just a status line + Location.
import server
import core
import http1_1.request_parser
import http1_1.response

// ---- static responses (consts — the fast path appends, never builds) --------
const resp_301_old = 'HTTP/1.1 301 Moved Permanently\r\nLocation: /new\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_308_api = 'HTTP/1.1 308 Permanent Redirect\r\nLocation: /api/v2/resource\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_200_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// Byte keys/targets allocated ONCE at init — never `'lit'.bytes()` per request.
const next_key = 'next'.bytes()
const slash_bytes = '/'.bytes() // safe_next's reject target
const dashboard_bytes = '/dashboard'.bytes() // default post-login landing page

// ws appends a string's bytes straight into `out` — no allocation
// (BEST_PRACTICES §3b).
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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

// route_len returns the path length up to (not including) the first `?`, so
// the route Slice excludes the query string (see BYTE DISCIPLINE above).
@[direct_array_access]
fn route_len(buf []u8, path request_parser.Slice) int {
	for i in 0 .. path.len {
		if buf[path.start + i] == u8(`?`) {
			return i
		}
	}
	return path.len
}

// SECURITY: only allow same-site relative redirects from user-supplied
// targets. Two byte checks on a VIEW — no copy, no string API needed.
// NOTE: get_query_slice does no percent-decoding, so `%2F%2Fevil.com` does not
// start with `/` and is rejected — same posture as checking after an explicit
// decode. A bare LF in the request-target could still reach the Location line
// (the parser only terminates the path at SP/CR); rejecting bytes < 0x21 here
// would close that, left out to keep the guard minimal.
@[direct_array_access]
fn safe_next(next []u8) []u8 {
	if next.len > 0 && next[0] == u8(`/`) && !(next.len > 1 && next[1] == u8(`/`)) {
		return next // relative, same-origin
	}
	return slash_bytes // reject absolute / protocol-relative / empty targets
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	// Effective route = path with the query string stripped, as offsets.
	route := request_parser.Slice{
		start: req.path.start
		len:   route_len(req.buffer, req.path)
	}

	if slice_eq(req.buffer, route, '/old') {
		// Canonical move: permanent, cacheable.
		out << resp_301_old
	} else if slice_eq(req.buffer, route, '/login') {
		if slice_eq(req.buffer, req.method, 'POST') {
			// Post/Redirect/Get: after handling the POST, send to a GET page.
			// The ONE dynamic response: Location is a validated VIEW of the
			// `?next=` value, appended before the request buffer is recycled.
			ws(mut out, 'HTTP/1.1 303 See Other\r\nLocation: ')
			if s := req.get_query_slice(next_key) {
				if s.len > 0 {
					out << safe_next(unsafe { (&req.buffer[s.start]).vbytes(s.len) })
				} else {
					out << slash_bytes // empty `next=`: reject to '/'
				}
			} else {
				out << dashboard_bytes // no `next`: default landing page
			}
			ws(mut out, '\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n')
			return .done
		}
		out << resp_200_empty // GET /login: the form page (empty stand-in)
	} else if slice_eq(req.buffer, route, '/api/v1/resource') {
		// API redirect: preserve method + body.
		out << resp_308_api
	} else {
		out << resp_200_empty
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
	})!
	println('Redirect demo on http://localhost:3000/  (/old -> 301, /login POST -> 303, /api/v1 -> 308)')
	srv.run()
}
