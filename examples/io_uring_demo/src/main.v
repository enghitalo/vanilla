module main

import server
import core

fn handle_request(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	// Simple request handler that returns OK response
	res :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
	out << res
	return .done
}

fn main() {
	// println('Starting server with ${io_multiplexing} io_multiplexing...')

	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { server.IOBackend(0) }
		handler:         handle_request
	})!

	srv.run()
}
