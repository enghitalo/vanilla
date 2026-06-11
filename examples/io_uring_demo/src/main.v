module main

import http_server

fn handle_request(req_buffer []u8, client_conn_fd int) ![]u8 {
	// Simple request handler that returns OK response
	res :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
	return res
}

fn main() {
	// println('Starting server with ${io_multiplexing} io_multiplexing...')

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { http_server.IOBackend(0) }
		request_handler: handle_request
	})!

	server.run()
}
