module http_server

import runtime
import socket

const max_thread_pool_size = runtime.nr_cpus()

// Backend selection
pub enum IOBackend {
	epoll            // Linux only
	io_uring_backend // Linux only
	kqueue_backend   // Darwin/macOS only
}

struct Server {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = .epoll
	socket_fd       int
pub mut:
	threads         []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	request_handler fn ([]u8, int) ![]u8 @[required]
}

pub struct ServerConfig {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = .epoll
	request_handler fn ([]u8, int) ![]u8 @[required]
}

pub fn new_server(config ServerConfig) Server {
	socket_fd := socket.create_server_socket(config.port)
	return Server{
		port:            config.port
		io_multiplexing: config.io_multiplexing
		socket_fd:       socket_fd
		request_handler: config.request_handler
		threads:         []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	}
}
