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

import server
import core
import http1_1.request_parser

// handle_request appends the complete raw HTTP response to `out` and returns a
// Step: `.done` keeps the connection alive, `.close` flushes then closes it. It
// never touches the socket directly (docs/BEST_PRACTICES). The extra handler
// parameters (client_fd, worker_state, event_loop) are unused here — this server
// is stateless and synchronous.
@[direct_array_access]
fn handle_request(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		// Malformed head: emit a self-delimiting 400 and close (RFC 9112 §9.6 —
		// the byte stream can no longer be trusted).
		out << resp_400_bad_request
		return .close
	}

	// Conformance gate: reject malformed requests with the RFC-mandated status.
	// Every rejection is self-delimiting and closes the connection.
	match classify(req) {
		.ok {}
		.bad_request {
			out << resp_400_bad_request
			return .close
		}
		.not_supported {
			out << resp_505_version_not_supported
			return .close
		}
		.not_impl {
			out << resp_501_not_implemented
			return .close
		}
	}

	// Route on the method + target. Methods this server implements: GET, HEAD,
	// POST. Anything else that is syntactically valid is 405 (RFC 9110 §15.5.6),
	// with an Allow header listing what is supported.
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	return match method {
		'GET' {
			serve_get(req, mut out)
		}
		'HEAD' {
			// HEAD is GET without a body: same status/headers, zero body bytes.
			out << resp_200_head
			step_for(req)
		}
		'POST' {
			// A conformant POST target: accept the body the framer already
			// validated and acknowledge it.
			out << resp_200_ok
			step_for(req)
		}
		else {
			// Recognized-but-unimplemented methods (OPTIONS/PUT/DELETE/…) and any
			// other syntactically valid method: 405 with an Allow header.
			out << resp_405_method_not_allowed
			step_for(req)
		}
	}
}

// serve_get answers GET. `/` returns 200; everything else is 404. Returns the
// Step the request asked for (keep-alive vs close).
@[direct_array_access]
fn serve_get(req request_parser.HttpRequest, mut out []u8) core.Step {
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	is_root := path == '/' || path.starts_with('/?') || path.starts_with('http')
	if !is_root {
		out << resp_404_not_found
		return step_for(req)
	}
	if wants_close(req) {
		out << resp_200_ok_close
		return .close
	}
	out << resp_200_ok
	return .done
}

// step_for maps a request's connection intent to a Step: `.close` when the
// request asked to close (or is HTTP/1.0 default-close), else `.done`.
fn step_for(req request_parser.HttpRequest) core.Step {
	return if wants_close(req) { .close } else { .done }
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
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		handler:         handle_request
		io_multiplexing: backend
	})!
	srv.run()
}
