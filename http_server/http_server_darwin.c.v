// Darwin (macOS)-specific HTTP server implementation using kqueue

module http_server

import kqueue
import socket
import http1_1.response
import http1_1.request

// Backend selection
pub enum IOBackend {
	kqueue = 0 // Darwin/macOS only
}

fn C.perror(s &char)
fn C.close(fd int) int

// Handle readable client connection.
//
// Connections are KEPT ALIVE after a successful response: the fd stays
// registered in the worker's kqueue (level-triggered), so the next request on
// the same connection just fires another read event. The kernel's EV_EOF (or a
// read of 0 bytes) cleans up when the client goes away. This matches the
// `Connection: keep-alive` the example handlers advertise — the previous
// close-per-request behaviour both lied to clients and crippled throughput.
fn handle_readable_fd(handler fn ([]u8, int, mut []u8) !, kq_fd int, client_fd int, limits Limits) {
	request_buffer := request.read_request(client_fd, limits.max_header_bytes,
		limits.max_body_bytes) or {
		match err.code() {
			413 {
				response.send_status_413_response(client_fd)
			}
			431 {
				response.send_status_431_response(client_fd)
			}
			400 {
				response.send_bad_request_response(client_fd)
			}
			else {
				if err.msg() == 'no data available' {
					// Spurious wakeup on an idle keep-alive connection — keep it.
					return
				}
				if err.msg() != 'client closed connection' {
					response.send_status_444_response(client_fd)
				}
			}
		}

		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}
	defer { unsafe { request_buffer.free() } }

	// Server-owned response buffer: the handler appends raw response bytes.
	mut response_buffer := []u8{len: 0, cap: 4096}
	defer { unsafe { response_buffer.free() } }
	handler(request_buffer, client_fd, mut response_buffer) or {
		response.send_bad_request_response(client_fd)
		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}

	response.send_response(client_fd, response_buffer.data, response_buffer.len) or {
		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}
	// Keep-alive: leave the fd registered for the next request.
}

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

pub fn run_kqueue_backend(socket_fd int, handler fn ([]u8, int, mut []u8) !, port int, limits Limits, mut threads []thread) {
	main_kq := kqueue.create_kqueue_fd()
	if main_kq < 0 {
		return
	}
	if kqueue.add_fd_to_kqueue(main_kq, socket_fd, kqueue.evfilt_read) < 0 {
		C.close(main_kq)
		return
	}

	n_workers := max_thread_pool_size
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

		callbacks := kqueue.KqueueEventCallbacks{
			on_read:  fn [handler, kq, limits] (fd int) {
				handle_readable_fd(handler, kq, fd, limits)
			}
			on_write: fn (_ int) {}
		}
		threads[i] = spawn kqueue.process_kqueue_events(callbacks, kq)
	}

	println('listening on http://localhost:${port}/ (kqueue)')
	handle_accept_loop(socket_fd, main_kq, worker_kqs)
}

// run_selected_backend dispatches to the configured macOS backend. Defined per
// OS so the all-platform facade (http_server.c.v) needs no platform-specific
// backend import. Blocks in the accept loop.
fn run_selected_backend(server Server, mut threads []thread) {
	match server.io_multiplexing {
		.kqueue {
			run_kqueue_backend(server.socket_fd, server.request_handler, server.port,
				server.limits, mut threads)
		}
	}
}

pub fn (mut server Server) run() {
	run_selected_backend(server, mut server.threads)
}
