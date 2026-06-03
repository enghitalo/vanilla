module http_server

import http_server.backend_epoll

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
}

// run_selected_backend dispatches to the configured Linux backend. Defined per
// OS (here, darwin, windows) so the all-platform facade (http_server.c.v) needs
// no platform-specific backend import. Blocks in the accept loop.
fn run_selected_backend(server Server, mut threads []thread) {
	match server.io_multiplexing {
		.epoll {
			backend_epoll.run_epoll_backend(server.socket_fd, server.request_handler, server.port,
				server.limits, server.inflight, server.active_conns, server.tls_config, mut threads)
		}
		.io_uring {
			run_io_uring_backend(server.request_handler, server.port, mut threads)
		}
	}
}

pub fn (mut server Server) run() {
	run_selected_backend(server, mut server.threads)
}
