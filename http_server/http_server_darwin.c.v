// Darwin (macOS)-specific HTTP server implementation using kqueue

module http_server

import kqueue
import socket
import response
import request

fn C.perror(s &char)
fn C.close(fd int) int

// Handle readable client connection
fn handle_readable_fd(handler fn ([]u8, int) ![]u8, kq_fd int, client_fd int) {
	request_buffer := request.read_request(client_fd) or {
		response.send_status_444_response(client_fd)
		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}
	defer { unsafe { request_buffer.free() } }

	response_buffer := handler(request_buffer, client_fd) or {
		response.send_bad_request_response(client_fd)
		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}

	response.send_response(client_fd, response_buffer.data, response_buffer.len) or {
		kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
		return
	}

	// Close connection (no keep-alive for simplicity)
	kqueue.remove_fd_from_kqueue(kq_fd, client_fd)
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
				client_fd := C.accept(socket_fd, C.NULL, C.NULL)
				if client_fd < 0 {
					break
				}
				socket.set_blocking(client_fd, false)

				target_kq := worker_kqs[worker_idx]
				worker_idx = (worker_idx + 1) % worker_kqs.len

				if kqueue.add_fd_to_kqueue(target_kq, client_fd, kqueue.evfilt_read) < 0 {
					C.close(client_fd)
				}
			}
		}
	}
}

pub fn run_kqueue_backend(socket_fd int, handler fn ([]u8, int) ![]u8, port int, mut threads []thread) {
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
			on_read:  fn [handler, kq] (fd int) {
				handle_readable_fd(handler, kq, fd)
			}
			on_write: fn (_ int) {}
		}
		threads[i] = spawn kqueue.process_kqueue_events(callbacks, kq)
	}

	println('listening on http://localhost:${port}/ (kqueue)')
	handle_accept_loop(socket_fd, main_kq, worker_kqs)
}

pub fn (mut server Server) run() {
	match server.io_multiplexing {
		.kqueue {
			run_kqueue_backend(server.socket_fd, server.request_handler, server.port, mut
				server.threads)
		}
		else {
			eprintln('Only kqueue is supported on macOS/Darwin.')
			exit(1)
		}
	}
}
