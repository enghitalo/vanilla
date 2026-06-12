module main

import http_server
import http_server.http1_1.response
import http_server.http1_1.request_parser

fn handle_request(req_buffer []u8, client_conn_fd int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			out << home_controller([])
			return
		} else if path.starts_with('/user/') {
			id := path[6..]

			out << get_user_controller([id], req)
			return
		}
	} else if method == 'POST' {
		if path == '/user' {
			out << create_user_controller([])
			return
		}
	}

	out << response.tiny_bad_request_response
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { http_server.IOBackend(0) }
		request_handler: handle_request
	})!

	server.run()
}
