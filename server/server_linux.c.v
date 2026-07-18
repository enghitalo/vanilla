module server

import server.backend_epoll

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
	// The pure-POSIX poll(2) portability floor (QNX/VxWorks tier). Compiled
	// on Linux ONLY under `-d vanilla_poll` (new_server rejects it otherwise)
	// so CI can exercise the RTOS reactor at zero cost to normal builds.
	poll = 2
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
		.poll {
			// Implemented in run_poll_d_vanilla_poll.c.v; the notd twin stub
			// keeps this arm linkable when the flag is off (new_server already
			// rejected the config by then).
			run_poll_backend_impl(srv, mut threads)
		}
	}
}

pub fn (mut srv Server) run() {
	run_selected_backend(srv, mut srv.threads)
}
