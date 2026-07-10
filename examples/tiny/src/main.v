// v -prod run examples/tiny/src
module main

import http_server
import http_server.core

const hello_world_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()

fn handle_request(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	out << hello_world_response
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		handler: handle_request
	})!

	server.run()
}
