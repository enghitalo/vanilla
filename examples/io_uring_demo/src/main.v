module main

import http_server

fn handle_request(req_buffer []u8, client_conn_fd int) ![]u8 {
	// Simple request handler that returns OK response
	response := 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'
	return response.bytes()
}

fn main() {
	// Get backend from command line arg, default to epoll
	backend := $if io_uring ? {
		http_server.IOBackend.io_uring_backend
	} $else {
		http_server.IOBackend.epoll
	}

	backend_name := match backend {
		.epoll { 'epoll' }
		.io_uring_backend { 'io_uring' }
	}

	println('Starting server with ${backend_name} backend...')

	mut server := http_server.Server{
		request_handler: handle_request
		port:            3000
		backend:         backend
	}

	server.run()
}
