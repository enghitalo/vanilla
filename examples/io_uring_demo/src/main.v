module main

import server
import core

// A static response is a const string, appended with core.append_str: no
// per-request copy (docs/BEST_PRACTICES.md §3a).
const hello_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'

// The handler is the same on every backend: it never sees the I/O model.
fn handle_request(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	core.append_str(mut out, hello_response)
	return .done
}

// pick_backend returns io_uring on Linux when this process can run it, and
// epoll otherwise; elsewhere the platform's only backend (kqueue on macOS, IOCP
// on Windows). iou_backend_available sets up one small ring per worker the
// server will spawn, so a kernel without io_uring, kernel.io_uring_disabled,
// a seccomp policy that denies io_uring_setup (Docker's default, GitHub's
// hosted runners), VANILLA_NO_IOURING or a memlock limit too small for even the
// smallest rings all fall back here instead of failing at startup.
fn pick_backend() server.IOBackend {
	$if linux {
		if server.iou_backend_available() {
			return .io_uring
		}
		eprintln('io_uring is not available to this process; serving on epoll')
		return .epoll
	} $else {
		return unsafe { server.IOBackend(0) }
	}
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: pick_backend()
		handler:         handle_request
	})!

	srv.run()
}
