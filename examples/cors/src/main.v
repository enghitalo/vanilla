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
// WORKS TODAY: pure header logic.
import http_server
import http_server.http1_1.request_parser

const allowed_origins = ['https://app.example.com', 'http://localhost:5173']

fn origin_allowed(origin string) bool {
	return origin in allowed_origins
}

fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	origin := if o := req.get_header_value_slice('Origin') {
		o.to_string(req.buffer)
	} else {
		''
	}

	// Resolve the allow-origin header value once (allowlisted, never blind `*`
	// when credentials are involved).
	allow_origin := if origin_allowed(origin) { origin } else { '' }

	// PREFLIGHT: answer the browser's permission probe.
	if method == 'OPTIONS' {
		if allow_origin == '' {
			out << 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'.bytes()
			return
		}
		out << ('HTTP/1.1 204 No Content\r\n' + 'Access-Control-Allow-Origin: ${allow_origin}\r\n' +
			'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n' +
			'Access-Control-Allow-Headers: Content-Type, Authorization, X-CSRF-Token\r\n' +
			'Access-Control-Allow-Credentials: true\r\n' + 'Access-Control-Max-Age: 86400\r\n' +
			'Vary: Origin\r\n' + 'Content-Length: 0\r\n\r\n').bytes()
		return
	}

	// Actual request: attach CORS headers to the real response.
	mut cors := ''
	if allow_origin != '' {
		cors = 'Access-Control-Allow-Origin: ${allow_origin}\r\n' +
			'Access-Control-Allow-Credentials: true\r\nVary: Origin\r\n'
	}
	body := '{"ok":true}'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n${cors}Content-Length: ${body.len}\r\n\r\n${body}'.bytes()
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
	println('CORS demo on http://localhost:3000/  (handles OPTIONS preflight + allowlist)')
	server.run()
}
