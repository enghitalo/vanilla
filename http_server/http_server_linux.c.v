module http_server

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
}

const connection_keep_alive_variants = [
	'Connection: keep-alive'.bytes(),
	'connection: keep-alive'.bytes(),
	'Connection: "keep-alive"'.bytes(),
	'connection: "keep-alive"'.bytes(),
	'Connection: Keep-Alive'.bytes(),
	'connection: Keep-Alive'.bytes(),
	'Connection: "Keep-Alive"'.bytes(),
	'connection: "Keep-Alive"'.bytes(),
]!

pub fn (mut server Server) run() {
	match server.io_multiplexing {
		.epoll {
			run_epoll_backend(server.socket_fd, server.request_handler, server.port, mut
				server.threads)
		}
		.io_uring {
			run_io_uring_backend(server.request_handler, server.port, mut server.threads)
		}
	}
}
