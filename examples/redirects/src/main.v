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
// Everything here WORKS TODAY — redirects are just a status line + Location.
import http_server
import http_server.http1_1.request_parser

fn redirect(status int, reason string, location string) []u8 {
	return 'HTTP/1.1 ${status} ${reason}\r\nLocation: ${location}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
}

// SECURITY: only allow same-site relative redirects from user-supplied targets.
fn safe_next(next string) string {
	if next.starts_with('/') && !next.starts_with('//') {
		return next // relative, same-origin
	}
	return '/' // reject absolute / protocol-relative targets
}

fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	mut path := req.path.to_string(req.buffer)
	if qi := path.index('?') {
		path = path[..qi]
	}

	match path {
		'/old' {
			// Canonical move: permanent, cacheable.
			out << redirect(301, 'Moved Permanently', '/new')
		}
		'/login' {
			if method == 'POST' {
				// Post/Redirect/Get: after handling the POST, send to a GET page.
				nxt := if s := req.get_query_slice('next'.bytes()) {
					safe_next(s.to_string(req.buffer))
				} else {
					'/dashboard'
				}
				out << redirect(303, 'See Other', nxt)
				return
			}
			out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
		'/api/v1/resource' {
			// API redirect: preserve method + body.
			out << redirect(308, 'Permanent Redirect', '/api/v2/resource')
		}
		else {
			out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
		}
	}
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
		request_handler: handle
	})!
	println('Redirect demo on http://localhost:3000/  (/old -> 301, /login POST -> 303, /api/v1 -> 308)')
	server.run()
}
