// http_server_windows.c.v
// Windows-specific HTTP server entry point or helpers

module http_server

import iocp

// ==================== Server Startup ====================

fn (mut server Server) run_iocp() {
	// TODO: Implement server startup for IOCP
}

pub fn run(mut server Server) {
	match server.io_multiplexing {
		.epoll {
			eprintln('Selected io_multiplexing is not supported on Windows.')
			exit(1)
		}
		.io_uring_backend {
			eprintln('Selected io_multiplexing is not supported on Windows.')
			exit(1)
		}
		else {
			server.run_iocp()
		}
	}
}
