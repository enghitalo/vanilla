// Darwin (macOS)-specific HTTP server implementation using kqueue

module server

import kqueue
import socket
import core

// Backend selection
pub enum IOBackend {
	kqueue = 0 // Darwin/macOS only
}

fn C.perror(s &char)
fn C.close(fd int) int

// Accept loop for main thread
fn handle_accept_loop(socket_fd int, main_kq int, worker_kqs []int) {
	mut worker_idx := 0
	mut events := [1]C.kevent{}

	for {
		nev := kqueue.wait_kqueue(main_kq, &events[0], 1, -1)
		if nev <= 0 {
			if nev < 0 && C.errno != C.EINTR {
				C.perror(c'kevent accept')
			}
			continue
		}

		if events[0].filter == kqueue.evfilt_read {
			for {
				// Non-blocking fd + SO_NOSIGPIPE (no MSG_NOSIGNAL on macOS).
				client_fd := socket.accept_client(socket_fd)
				if client_fd < 0 {
					break
				}
				// Disable Nagle so small responses are not delayed (parity with Linux).
				socket.set_tcp_nodelay(client_fd)

				target_kq := worker_kqs[worker_idx]
				worker_idx = (worker_idx + 1) % worker_kqs.len

				if kqueue.add_fd_to_kqueue(target_kq, client_fd, kqueue.evfilt_read) < 0 {
					C.close(client_fd)
				}
			}
		}
	}
}

pub fn run_kqueue_backend(socket_fd int, handler core.Handler, make_state fn () voidptr, after_server_start core.AfterStartFn, port int, limits Limits, mut threads []thread) {
	main_kq := kqueue.create_kqueue_fd()
	if main_kq < 0 {
		return
	}
	if kqueue.add_fd_to_kqueue(main_kq, socket_fd, kqueue.evfilt_read) < 0 {
		C.close(main_kq)
		return
	}

	// Worker count = the thread array new_server sized from config.workers.
	n_workers := threads.len
	mut worker_kqs := []int{len: n_workers}

	for i in 0 .. n_workers {
		kq := kqueue.create_kqueue_fd()
		if kq < 0 {
			// Cleanup already created
			for j in 0 .. i {
				C.close(worker_kqs[j])
			}
			C.close(main_kq)
			return
		}
		worker_kqs[i] = kq

		// One worker loop for every handler: it owns a watch registry and resumes
		// parked requests when a watched fd fires (see async_darwin.c.v); a handler
		// that never suspends just appends and returns .done.
		threads[i] = spawn process_kqueue_worker(kq, handler, make_state, limits)
	}

	println('listening on http://localhost:${port}/ (kqueue)')
	// Server is accepting (listener + worker kqueues up); fire the one-shot
	// lifecycle hook on this (main) thread right before we block in the accept loop.
	if after_server_start != unsafe { nil } {
		after_server_start()
	}
	handle_accept_loop(socket_fd, main_kq, worker_kqs)
}

// run_selected_backend dispatches to the configured macOS backend. Defined per
// OS so the all-platform facade (server.c.v) needs no platform-specific
// backend import. Blocks in the accept loop.
fn run_selected_backend(srv Server, mut threads []thread) {
	match srv.io_multiplexing {
		.kqueue {
			run_kqueue_backend(srv.socket_fd, srv.handler, srv.make_state, srv.after_server_start,
				srv.port, srv.limits, mut threads)
		}
	}
}

pub fn (mut srv Server) run() {
	run_selected_backend(srv, mut srv.threads)
}

// iou_backend_available: io_uring is Linux-only, so it is never available here.
// See the Linux definition (server_io_uring_linux.c.v) for the real probe.
pub fn iou_backend_available() bool {
	return false
}
