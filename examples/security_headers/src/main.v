module main

// Security response headers — reference design.
//
// A set of headers that cost nothing to send and close whole classes of
// browser-side attacks. The pure design applies them in ONE place to every
// response (a wrapper around the handler), so no endpoint can forget them.
//
//   Strict-Transport-Security  — force HTTPS for future visits (HSTS).
//   Content-Security-Policy    — the big one: restrict where scripts/styles/
//                                connections may come from; kills most XSS.
//   X-Content-Type-Options     — `nosniff`: stop MIME-sniffing attacks.
//   X-Frame-Options            — `DENY`: stop clickjacking via <iframe>.
//   Referrer-Policy            — limit referrer leakage to other sites.
//   Permissions-Policy         — disable powerful APIs (camera, geolocation).
//
// PURITY GOAL: this wrapper pattern is how cross-cutting concerns SHOULD compose
// on vanilla — a plain function that takes a handler and returns a handler.
// No framework, no magic, just function composition. The same shape works for
// logging, auth gates, CORS, rate limiting.
//
// WORKS TODAY.
import server
import core
import http1_1.request_parser
import http1_1.response

const security_headers = ('Strict-Transport-Security: max-age=63072000; includeSubDomains\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n" + 'X-Content-Type-Options: nosniff\r\n' +
	'X-Frame-Options: DENY\r\n' + 'Referrer-Policy: strict-origin-when-cross-origin\r\n' +
	'Permissions-Policy: geolocation=(), camera=(), microphone=()\r\n').bytes()

// Content-Length 15 = len('<h1>secure</h1>').
const app_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 15\r\n\r\n<h1>secure</h1>'.bytes()

// with_security_headers wraps any handler and injects the headers into its
// response, right after the status line. Composition, not inheritance. Every
// input reaches `next` unchanged: the wrapped handler may key on its
// connection (client_fd) or dereference its make_state value (worker_state).
fn with_security_headers(next core.Handler) core.Handler {
	return fn [next] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		start := out.len
		step := next(req_buffer, mut out, client_fd, worker_state, mut event_loop)
		if step != .done {
			return step
		}
		insert_after_status_line(mut out, start, security_headers)
		return .done
	}
}

// insert_after_status_line splices `headers` into the response that begins at
// out[start], right after its status line (the first CRLF), in place: append
// to make room, shift the tail right, copy the headers into the gap. No
// allocation once `out` (the connection's reused write buffer) has grown to
// its high-water mark. A response without a CRLF is left untouched.
@[direct_array_access]
fn insert_after_status_line(mut out []u8, start int, headers []u8) {
	if headers.len == 0 {
		return
	}
	mut end := -1
	for i in start .. out.len - 1 {
		if out[i] == `\r` && out[i + 1] == `\n` {
			end = i + 2
			break
		}
	}
	if end < 0 {
		return
	}
	tail := out.len - end
	out << headers // grows `out` by headers.len; those bytes are rewritten below
	unsafe {
		p := &u8(out.data)
		vmemmove(p + end + headers.len, p + end, tail)
		vmemcpy(p + end, headers.data, headers.len)
	}
}

fn app(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	_ := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	out << app_response
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
		// The whole point: one wrap, every response hardened.
		handler:         with_security_headers(app)
	})!
	println('Security-headers demo on http://localhost:3000/  (every response hardened via wrapper)')
	srv.run()
}
