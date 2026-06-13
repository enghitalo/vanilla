// v -prod run examples/tiny/src
module main

import http_server

const hello_world_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()

fn handle_request(req_buffer []u8, client_conn_fd int, mut out []u8) ! {
	out << hello_world_response
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		request_handler: handle_request
	})!

	server.run()
}
