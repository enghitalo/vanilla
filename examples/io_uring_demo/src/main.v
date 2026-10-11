module main

import server
import core

// A static response is a const string, appended with core.append_str: no
// per-request copy (docs/BEST_PRACTICES.md §3a).
const hello_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'

fn handle_request(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	// Simple request handler that returns OK response
	core.append_str(mut out, hello_response)
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
