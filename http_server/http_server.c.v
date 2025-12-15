module http_server

import runtime

const max_thread_pool_size = runtime.nr_cpus()

// Backend selection
pub enum IOBackend {
	epoll            // Linux only
	io_uring_backend // Linux only
	kqueue_backend   // Darwin/macOS only
}

pub struct Server {
pub:
	port    int       = 3000
	backend IOBackend = .epoll
pub mut:
	socket_fd       int
	threads         []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	request_handler fn ([]u8, int) ![]u8 @[required]
}
