module main

import http_server
import http_server.core

fn handle_request(req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
	// Simple request handler that returns OK response
	res :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
	out << res
	return .done
}

fn main() {
	// println('Starting server with ${io_multiplexing} io_multiplexing...')

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { http_server.IOBackend(0) }
		handler:         handle_request
	})!

	server.run()
}
