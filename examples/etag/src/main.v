module main

import server
import core
import http1_1.response
import http1_1.request_parser

fn handle_request(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	// Views into `req_buffer`, not `req.buffer`: a view of `req.buffer` that
	// reaches a callee moves `req` to the heap, a copy on every request.
	method := unsafe { tos(&req_buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req_buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			home_controller(mut out)
			return .done
		} else if path.starts_with('/user/') {
			id := unsafe { tos(path.str + 6, path.len - 6) } // view, no copy
			get_user_controller(id, req, mut out)
			return .done
		}
	} else if method == 'OPTIONS' {
		if path.starts_with('/user/') {
			core.append_str(mut out, preflight_response)
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			create_user_controller(mut out)
			return .done
		}
	}

	out << response.tiny_bad_request_response
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { server.IOBackend(0) }
		handler:         handle_request
	})!

	srv.run()
}
