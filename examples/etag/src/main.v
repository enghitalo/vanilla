module main

import http_server
import http_server.core
import http_server.http1_1.response
import http_server.http1_1.request_parser

fn handle_request(req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			out << home_controller([]) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		} else if path.starts_with('/user/') {
			id := path[6..]

			out << get_user_controller([id], req) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			out << create_user_controller([]) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		}
	}

	out << response.tiny_bad_request_response
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { http_server.IOBackend(0) }
		handler:         handle_request
	})!

	server.run()
}
