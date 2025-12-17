module main

import http_server
import http_server.response
import request_parser

fn handle_request(req_buffer []u8, client_conn_fd int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			return home_controller([])
		} else if path.starts_with('/user/') {
			id := path[6..]

			return get_user_controller([id], req)
		}
	} else if method == 'POST' {
		if path == '/user' {
			return create_user_controller([])
		}
	}

	return response.tiny_bad_request_response
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: $if linux {
			.epoll
		} $else $if darwin {
			.kqueue
		} $else {
			.iocp
		}
		request_handler: handle_request
	})!

	server.run()
}
