module server

import server.backend_epoll

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
}

// run_selected_backend dispatches to the configured Linux backend. Defined per
// OS (here, darwin, windows) so the all-platform facade (server.c.v) needs
// no platform-specific backend import. Blocks in the accept loop.
fn run_selected_backend(srv Server, mut threads []thread) {
	match srv.io_multiplexing {
		.epoll {
			backend_epoll.run_epoll_backend(srv.socket_fd, srv.handler, srv.make_state,
				srv.on_worker_start, srv.after_server_start, srv.port, srv.limits, srv.inflight,
				srv.active_conns, srv.tls_config, mut threads)
		}
		.io_uring {
			run_io_uring_backend(srv, mut threads)
		}
	}
}

pub fn (mut srv Server) run() {
	run_selected_backend(srv, mut srv.threads)
}
