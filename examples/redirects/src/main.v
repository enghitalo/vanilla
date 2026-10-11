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
//     the handler only APPENDS (`core.append_str(mut out, resp_...)`), it
//     never builds.
//   - The ONE dynamic response (303: Location echoes a validated `?next=`) is
//     framed with `core.append_str` around a zero-copy VIEW of the query value
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
const resp_301_old = 'HTTP/1.1 301 Moved Permanently\r\nLocation: /new\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_308_api = 'HTTP/1.1 308 Permanent Redirect\r\nLocation: /api/v2/resource\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_200_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// `[]u8` consts where a `[]u8` value is needed (get_query_slice's key,
// safe_next's return), built ONCE at init — never `'lit'.bytes()` per request.
const next_key = 'next'.bytes()
const slash_bytes = '/'.bytes() // safe_next's reject target
const dashboard_target = '/dashboard' // default post-login landing page

// (BEST_PRACTICES §3b).
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
// targets. Byte checks on a VIEW — no copy, no string API needed. The target
// must start with `/`, and its second byte must not make a browser read it as
// protocol-relative (`//host`, off-site), so these are refused there:
//   - `/`: `//evil.com`;
//   - `\`: browsers treat it as `/` in http(s) URLs (WHATWG URL), so
//     `/\evil.com` is `//evil.com`;
//   - TAB, LF, CR: the URL parser removes them before parsing, so
//     `/<TAB>/evil.com` is `//evil.com`. A raw TAB reaches the handler (the
//     request-target ends only at SP or CR); a raw CR or LF does not (below).
// Past the second byte they are path bytes: `/a\b` stays same-site.
// NOTE: get_query_slice does no percent-decoding, so `%2F%2Fevil.com` does not
// start with `/` and is rejected — same posture as checking after an explicit
// decode — and `/%5Cevil.com` is a plain path: browsers do not decode `%5C` in
// a Location. A raw CR or LF never reaches the Location line: the request-line
// parser ends the target at the first CR, and the request framer answers a
// bare LF with 400 before any handler runs.
@[direct_array_access]
fn safe_next(next []u8) []u8 {
	if next.len == 0 || next[0] != u8(`/`) {
		return slash_bytes // reject absolute / empty targets
	}
	if next.len > 1 {
		c := next[1]
		if c == u8(`/`) || c == u8(`\\`) || c == u8(`\t`) || c == u8(`\n`) || c == u8(`\r`) {
			return slash_bytes // reject protocol-relative targets
		}
	}
	return next // relative, same-origin
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
		core.append_str(mut out, resp_301_old)
	} else if slice_eq(req.buffer, route, '/login') {
		if slice_eq(req.buffer, req.method, 'POST') {
			// Post/Redirect/Get: after handling the POST, send to a GET page.
			// The ONE dynamic response: Location is a validated VIEW of the
			// `?next=` value, appended before the request buffer is recycled.
			core.append_str(mut out, 'HTTP/1.1 303 See Other\r\nLocation: ')
			if s := req.get_query_slice(next_key) {
				if s.len > 0 {
					// The view is taken from `req_buffer`, not `req.buffer`: a
					// view of `req.buffer` returned through safe_next moves `req`
					// to the heap, a copy on every request.
					out << safe_next(unsafe { (&req_buffer[s.start]).vbytes(s.len) })
				} else {
					out << slash_bytes // empty `next=`: reject to '/'
				}
			} else {
				core.append_str(mut out, dashboard_target) // no `next`: default landing page
			}
			core.append_str(mut out, '\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n')
			return .done
		}
		core.append_str(mut out, resp_200_empty) // GET /login: the form page (empty stand-in)
	} else if slice_eq(req.buffer, route, '/api/v1/resource') {
		// API redirect: preserve method + body.
		core.append_str(mut out, resp_308_api)
	} else {
		core.append_str(mut out, resp_200_empty)
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
