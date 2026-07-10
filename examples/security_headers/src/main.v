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
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response

const security_headers = 'Strict-Transport-Security: max-age=63072000; includeSubDomains\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n" + 'X-Content-Type-Options: nosniff\r\n' +
	'X-Frame-Options: DENY\r\n' + 'Referrer-Policy: strict-origin-when-cross-origin\r\n' +
	'Permissions-Policy: geolocation=(), camera=(), microphone=()\r\n'

// with_security_headers wraps any handler and injects the headers into its
// response, right after the status line. Composition, not inheritance.
fn with_security_headers(next core.Handler) core.Handler {
	return fn [next] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		start := out.len
		step := next(req_buffer, mut out, -1, unsafe { nil }, mut event_loop)
		if step != .done {
			return step
		}
		s := out[start..].bytestr()
		// Insert headers after the first CRLF (the status line).
		idx := s.index('\r\n') or { return .done }
		injected := s[..idx + 2] + security_headers + s[idx + 2..]
		out.trim(start)
		out << injected.bytes()
		return .done
	}
}

fn app(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	_ := req
	body := '<h1>secure</h1>'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
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
		// The whole point: one wrap, every response hardened.
		handler: with_security_headers(app)
	})!
	println('Security-headers demo on http://localhost:3000/  (every response hardened via wrapper)')
	server.run()
}
