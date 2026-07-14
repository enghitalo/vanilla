// examples/conformance — an RFC 9112/9110-conformant handler.
//
// Every other example optimizes for a specific feature; this one exists to be
// *correct* under an HTTP/1.1 conformance probe (h1spec, Http11Probe). It calls
// the stdlib `validate_http1()` plus the extra field-syntax and framing checks
// in validate.v, so malformed requests get the right 4xx/5xx status instead of
// being served as if valid.
//
// Run:   v -prod run examples/conformance/src
// Probe: uvx --from git+https://github.com/dropseed/h1spec h1spec --strict localhost:3000
module main

import http_server
import http_server.http1_1.request_parser

// handle_request is a pure (request) -> []u8 handler: it appends the complete
// raw HTTP response to `out` and never touches the socket (docs/BEST_PRACTICES).
@[direct_array_access]
fn handle_request(req_buffer []u8, client_conn_fd int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer) or {
		out << resp_400_bad_request
		return
	}

	// Conformance gate: reject malformed requests with the RFC-mandated status.
	match classify(req) {
		.ok {}
		.bad_request {
			out << resp_400_bad_request
			return
		}
		.not_supported {
			out << resp_505_version_not_supported
			return
		}
		.not_impl {
			out << resp_501_not_implemented
			return
		}
	}

	// Route on the method + target. Methods this server implements: GET, HEAD,
	// POST. Anything else that is syntactically valid is 405 (RFC 9110 §15.5.6),
	// with an Allow header listing what is supported.
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	match method {
		'GET' {
			serve_get(req, mut out)
		}
		'HEAD' {
			// HEAD is GET without a body: same status/headers, zero body bytes.
			out << resp_200_head
		}
		'POST' {
			// A conformant POST target: accept the body the framer already
			// validated and acknowledge it.
			out << resp_200_ok
		}
		'OPTIONS', 'PUT', 'DELETE', 'PATCH', 'CONNECT', 'TRACE' {
			// Recognized methods we deliberately don't implement here.
			out << resp_405_method_not_allowed
		}
		else {
			out << resp_405_method_not_allowed
		}
	}
}

// serve_get answers GET. `/` returns 200; everything else is 404. The response
// honors a `Connection: close` request by echoing it, so the connection-close
// conformance check passes (RFC 9112 §9.6).
@[direct_array_access]
fn serve_get(req request_parser.HttpRequest, mut out []u8) {
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	is_root := path == '/' || path.starts_with('/?') || path.starts_with('http')
	if !is_root {
		out << resp_404_not_found
		return
	}
	if wants_close(req) {
		out << resp_200_ok_close
		return
	}
	out << resp_200_ok
}

// wants_close reports whether the request asked to close the connection, either
// via `Connection: close` or by being HTTP/1.0 without `Connection: keep-alive`.
fn wants_close(req request_parser.HttpRequest) bool {
	if c := req.get_header_value_slice('Connection') {
		val := unsafe { tos(&req.buffer[c.start], c.len) }
		if token_list_has(val, 'close') {
			return true
		}
		if version_is(req.buffer, req.version, 'HTTP/1.0') {
			return !token_list_has(val, 'keep-alive')
		}
		return false
	}
	// No Connection header: HTTP/1.0 defaults to close, HTTP/1.1 to keep-alive.
	return version_is(req.buffer, req.version, 'HTTP/1.0')
}

// token_list_has reports whether a comma-separated header value contains `want`
// (case-insensitive), e.g. `Connection: keep-alive, close`.
fn token_list_has(val string, want string) bool {
	for part in val.split(',') {
		if part.trim_space().to_lower() == want {
			return true
		}
	}
	return false
}

fn main() {
	// Per-OS backend selection (parity with the other examples).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		request_handler: handle_request
		io_multiplexing: backend
	})!
	server.run()
}
