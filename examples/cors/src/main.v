module main

// CORS (Cross-Origin Resource Sharing) — reference design.
//
// The browser enforces the same-origin policy; CORS is how a server OPTS IN to
// being called from other origins. Two request shapes:
//
//   1. SIMPLE requests (GET/HEAD/POST with simple headers): the browser sends
//      them and just checks `Access-Control-Allow-Origin` on the response.
//   2. PREFLIGHT: for anything else (custom headers, PUT/DELETE, JSON content
//      type) the browser first sends an `OPTIONS` request asking permission.
//      You must answer it with the allowed methods/headers BEFORE the real
//      request is sent. Forgetting the OPTIONS handler is the #1 CORS bug.
//
// SECURITY: do NOT reflect arbitrary Origins with credentials. The combination
//   `Access-Control-Allow-Origin: *` + `Allow-Credentials: true` is forbidden
//   by spec for good reason. With credentials you must echo a SPECIFIC,
//   allowlisted origin — never `*`, never blind reflection.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - NEVER concatenate or interpolate — not even on the slow path. Every
//     response is split into compile-time consts around the one dynamic part
//     (the echoed origin), appended with `out <<` / `push_many`.
//   - VIEWS, NOT COPIES: the Origin value stays in the request buffer. The
//     allowlist check wraps it in a read-only `tos` view (`in` on an array
//     only compares, never retains — same blessing as the §2 map-key views);
//     echoing it back is a `push_many` straight from the buffer offsets.
//   - Routing compares the method IN PLACE by offsets (`slice_eq`) — no
//     `.to_string()`, no `buf[a..b]` slice-marking.
//   After the parse, the handler allocates NOTHING per request.
//
// WORKS TODAY: pure header logic.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response

const allowed_origins = ['https://app.example.com', 'http://localhost:5173']

fn origin_allowed(origin string) bool {
	return origin in allowed_origins
}

// ---- static responses (consts — the handler appends, never builds) ----------
// The echoed origin is the ONLY dynamic byte range; everything around it is a
// compile-time const, so the `{"ok":true}` body's Content-Length is the known
// constant 11 (keep the two in sync if you ever change the body).
const resp_403 = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'.bytes()
const preflight_head = 'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: '.bytes()
const preflight_tail = '\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, X-CSRF-Token\r\nAccess-Control-Allow-Credentials: true\r\nAccess-Control-Max-Age: 86400\r\nVary: Origin\r\nContent-Length: 0\r\n\r\n'.bytes()
const ok_cors_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: '.bytes()
const ok_cors_tail = '\r\nAccess-Control-Allow-Credentials: true\r\nVary: Origin\r\nContent-Length: 11\r\n\r\n{"ok":true}'.bytes()
const resp_ok_plain = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{"ok":true}'.bytes()

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

fn handle(req_buffer []u8, mut out []u8, _client_fdclient_fd int, _worker_stateworker_state voidptr, mut _event_loopevent_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	// Origin as OFFSETS into the request buffer; the allowlist check runs over
	// a read-only `tos` view of those bytes (guarded len > 0 — an empty value
	// is treated as absent). The view never escapes the handler: array `in`
	// only compares, it never retains (BEST_PRACTICES §2, map-key views).
	mut o_start := 0
	mut o_len := 0
	mut allowed := false
	if o := req.get_header_value_slice('Origin') {
		if o.len > 0 {
			allowed = origin_allowed(unsafe { tos(&req.buffer[o.start], o.len) })
			o_start = o.start
			o_len = o.len
		}
	}

	// PREFLIGHT: answer the browser's permission probe. Allowlisted origins
	// get the const 204 block with their origin echoed back (never `*` — see
	// SECURITY above); everything else, including a missing Origin, gets 403.
	if slice_eq(req.buffer, req.method, 'OPTIONS') {
		if !allowed {
			out << resp_403
			return .done
		}
		out << preflight_head
		unsafe { out.push_many(&req.buffer[o_start], o_len) } // echo the allowlisted origin
		out << preflight_tail
		return .done
	}

	// Actual (simple) request: attach CORS headers only for allowlisted
	// origins; other requests still get the resource, just without the CORS
	// grant (the browser blocks the cross-origin read, not the server).
	if allowed {
		out << ok_cors_head
		unsafe { out.push_many(&req.buffer[o_start], o_len) } // echo the allowlisted origin
		out << ok_cors_tail
		return .done
	}
	out << resp_ok_plain
	return .done
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
	})!
	println('CORS demo on http://localhost:3000/  (handles OPTIONS preflight + allowlist)')
	server.run()
}
