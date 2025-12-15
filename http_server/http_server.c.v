module http_server

import runtime
import epoll
import socket
import request
import response
import io_uring

const max_thread_pool_size = runtime.nr_cpus()

#include <errno.h>

$if !windows {
	#include <sys/epoll.h>
}

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int

// Backend selection for I/O multiplexing
pub enum IOBackend {
	epoll
	io_uring_backend
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

// Socket and epoll helpers moved to dedicated files: socket.v, epoll.v, response.v, request.v

// Handles readable client connection: recv, route, and send response.
// Extracted to simplify the event loop.
fn handle_readable_fd(request_handler fn ([]u8, int) ![]u8, epoll_fd int, client_conn_fd int) {
	request_buffer := request.read_request(client_conn_fd) or {
		eprintln('Error reading request: ${err}')
		response.send_status_444_response(client_conn_fd)
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}

	defer {
		unsafe { request_buffer.free() }
	}

	response_buffer := request_handler(request_buffer, client_conn_fd) or {
		eprintln('Error handling request: ${err}')
		response.send_bad_request_response(client_conn_fd)
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}

	response.send_response(client_conn_fd, response_buffer.data, response_buffer.len) or {
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}
}

fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int) {
	mut next_worker := 0
	mut event := C.epoll_event{}

	for {
		num_events := C.epoll_wait(main_epoll_fd, &event, 1, -1)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}

		if num_events > 1 {
			eprintln('More than one event in epoll_wait, this should not happen.')
			continue
		}

		if event.events & u32(C.EPOLLIN) != 0 {
			for {
				client_conn_fd := C.accept(socket_fd, C.NULL, C.NULL)
				if client_conn_fd < 0 {
					// Check for EAGAIN or EWOULDBLOCK, usually represented by errno 11.
					if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
						break // No more incoming connections; exit loop.
					}
					eprintln(@LOCATION)
					C.perror(c'Accept failed')
					continue
				}
				socket.set_blocking(client_conn_fd, false)
				// Load balance the client connection to the worker threads.
				// this is a simple round-robin approach.
				epoll_fd := epoll_fds[next_worker]
				next_worker = (next_worker + 1) % max_thread_pool_size
				if epoll.add_fd_to_epoll(epoll_fd, client_conn_fd, u32(C.EPOLLIN | C.EPOLLET)) < 0 {
					socket.close_socket(client_conn_fd)
					continue
				}
			}
		}
	}
}

@[direct_array_access; manualfree]
fn process_events(event_callbacks epoll.EpollEventCallbacks, epoll_fd int) {
	mut events := [socket.max_connection_size]C.epoll_event{}

	for {
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, -1)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			eprintln(@LOCATION)
			C.perror(c'epoll_wait')
			break
		}

		for i in 0 .. num_events {
			client_conn_fd := unsafe { events[i].data.fd }
			if events[i].events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
				continue
			}

			if events[i].events & u32(C.EPOLLIN) != 0 {
				event_callbacks.on_read(client_conn_fd)
			}

			if events[i].events & u32(C.EPOLLOUT) != 0 {
				event_callbacks.on_write(client_conn_fd)
			}
		}
	}
}

pub fn (mut server Server) run() {
	$if windows {
		eprintln('Windows is not supported yet. Please, use WSL or Linux.')
		exit(1)
	}

	match server.backend {
		.epoll {
			server.run_epoll()
		}
		.io_uring_backend {
			server.run_io_uring()
		}
	}
}

// ==================== Epoll Backend ====================

fn (mut server Server) run_epoll() {
	server.socket_fd = socket.create_server_socket(server.port)
	if server.socket_fd < 0 {
		return
	}

	main_epoll_fd := epoll.create_epoll_fd()
	if main_epoll_fd < 0 {
		socket.close_socket(server.socket_fd)
		exit(1)
	}

	if epoll.add_fd_to_epoll(main_epoll_fd, server.socket_fd, u32(C.EPOLLIN)) < 0 {
		socket.close_socket(server.socket_fd)
		socket.close_socket(main_epoll_fd)
		exit(1)
	}

	mut epoll_fds := []int{len: max_thread_pool_size, cap: max_thread_pool_size}
	unsafe { epoll_fds.flags.set(.noslices | .noshrink | .nogrow) }
	for i in 0 .. max_thread_pool_size {
		epoll_fds[i] = epoll.create_epoll_fd()
		if epoll_fds[i] < 0 {
			C.perror(c'epoll_create1')
			for j in 0 .. i {
				socket.close_socket(epoll_fds[j])
			}
			socket.close_socket(main_epoll_fd)
			socket.close_socket(server.socket_fd)
			exit(1)
		}

		// Build per-thread callbacks: default to handle_readable_fd; write is a no-op.
		epfd := epoll_fds[i]
		handler := server.request_handler
		callbacks := epoll.EpollEventCallbacks{
			on_read:  fn [handler, epfd] (fd int) {
				handle_readable_fd(handler, epfd, fd)
			}
			on_write: fn (_ int) {}
		}
		server.threads[i] = spawn process_events(callbacks, epoll_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	handle_accept_loop(server.socket_fd, main_epoll_fd, epoll_fds)
}

// ==================== IO Uring Backend ====================

fn (mut server Server) run_io_uring() {
	num_workers := max_thread_pool_size

	for i in 0 .. num_workers {
		mut worker := &io_uring.Worker{}
		worker.cpu_id = i
		worker.listen_fd = -1
		io_uring.pool_init(mut worker)

		// Initialize io_uring ring
		mut params := C.io_uring_params{}
		if C.io_uring_queue_init_params(u32(io_uring.default_ring_entries), &worker.ring,
			&params) < 0 {
			eprintln('Failed to initialize io_uring for worker ${i}')
			exit(1)
		}
		// User indicates multishot accept is supported; enable it
		worker.use_multishot = true
		eprintln('[io_uring] worker ${i}: forcing multishot accept')

		// Create per-worker listener
		worker.listen_fd = io_uring.create_listener(server.port)
		if worker.listen_fd < 0 {
			eprintln('Failed to create listener for worker ${i}')
			exit(1)
		}
		// Spawn worker thread
		handler := server.request_handler
		server.threads[i] = spawn io_uring_worker_loop(worker, handler)
	}

	println('listening on http://localhost:${server.port}/ (io_uring)')

	// Keep main thread alive
	for {
		C.sleep(1)
	}
}

fn io_uring_worker_loop(worker &io_uring.Worker, handler fn ([]u8, int) ![]u8) {
	       io_uring.prep_accept(&worker.ring, worker.listen_fd, worker.use_multishot)
	       C.io_uring_submit(&worker.ring)
	       $if verbose ? {
		       eprintln('[DEBUG] Worker started, listening on fd=${worker.listen_fd}')
	       }

	       for {
		       $if verbose ? {
			       eprintln('[DEBUG] Waiting for CQE...')
		       }
		       mut cqe := &C.io_uring_cqe(unsafe { nil })
		       ret := C.io_uring_wait_cqe(&worker.ring, &cqe)

		       if ret == -C.EINTR {
			       continue
		       }
		       if ret < 0 {
			       $if verbose ? {
				       eprintln('[DEBUG] wait_cqe error: ${ret}')
			       }
			       break
		       }

		       data := C.io_uring_cqe_get_data64(cqe)
		       op := io_uring.unpack_op(data)
		       c_ptr := io_uring.unpack_ptr(data)
		       res := cqe.res

		       $if verbose ? {
			       eprintln('[DEBUG] CQE: op=${op} res=${res} flags=${cqe.flags}')
		       }

		       match op {
			       io_uring.op_accept {
				       if res >= 0 {
					       fd := res
					       $if verbose ? {
						       eprintln('[DEBUG] Accept: new fd=${fd}')
					       }
					       io_uring.tune_socket(fd)
					       mut nc := io_uring.pool_acquire_from_ptr(worker, fd)
					       if unsafe { nc != nil } {
						       io_uring.prep_read(&worker.ring, mut *nc)
					       } else {
						       C.close(fd)
					       }
				       }
				       if (cqe.flags & u32(1 << 1)) == 0 {
					       $if verbose ? {
						       eprintln('[DEBUG] Re-arming accept')
					       }
					       io_uring.prep_accept(&worker.ring, worker.listen_fd, worker.use_multishot)
				       }
			       }
			       io_uring.op_read {
				       if res <= 0 {
					       $if verbose ? {
						       eprintln('[DEBUG] Read EOF/error: ${res}')
					       }
					       if unsafe { c_ptr != nil } {
						       mut conn := unsafe { &io_uring.Connection(c_ptr) }
						       io_uring.pool_release_from_ptr(worker, mut *conn)
					       }
				       } else if unsafe { c_ptr != nil } {
					       mut conn := unsafe { &io_uring.Connection(c_ptr) }
					       conn.bytes_read = res
					       $if verbose ? {
						       eprintln('[DEBUG] Read ${res} bytes from fd=${conn.fd}')
					       }

					       request_data := unsafe { conn.buf[..conn.bytes_read] }

					       response_data := handler(request_data, conn.fd) or {
						       response.send_bad_request_response(conn.fd)
						       io_uring.pool_release_from_ptr(worker, mut *conn)
						       C.io_uring_cqe_seen(&worker.ring, cqe)
						       C.io_uring_submit(&worker.ring)
						       continue
					       }

					       conn.response_buffer = response_data
					       conn.bytes_sent = 0
					       $if verbose ? {
						       eprintln('[DEBUG] Preparing write of ${conn.response_buffer.len} bytes')
					       }
					       io_uring.prep_write(&worker.ring, mut *conn, conn.response_buffer.data,
						       usize(conn.response_buffer.len))
				       }
			       }
			       io_uring.op_write {
				       if res >= 0 {
					       $if verbose ? {
						       eprintln('[DEBUG] Wrote ${res} bytes')
					       }
					       if unsafe { c_ptr != nil } {
						       mut conn := unsafe { &io_uring.Connection(c_ptr) }
						       conn.bytes_sent += res

						       if conn.bytes_sent < conn.response_buffer.len {
							       remaining := conn.response_buffer.len - conn.bytes_sent
							       io_uring.prep_write(&worker.ring, mut *conn, unsafe {
								       &u8(u64(conn.response_buffer.data) + u64(conn.bytes_sent))
							       }, usize(remaining))
						       } else {
							       $if verbose ? {
								       eprintln('[DEBUG] Write complete, keep-alive next read')
							       }
							       conn.bytes_read = 0
							       unsafe { conn.response_buffer.free() }
							       conn.response_buffer = []u8{}
							       io_uring.prep_read(&worker.ring, mut *conn)
						       }
					       }
				       } else {
					       $if verbose ? {
						       eprintln('[DEBUG] Write error: ${res}')
					       }
					       if unsafe { c_ptr != nil } {
						       mut conn := unsafe { &io_uring.Connection(c_ptr) }
						       io_uring.pool_release_from_ptr(worker, mut *conn)
					       }
				       }
			       }
			       else {}
		       }

		       C.io_uring_cqe_seen(&worker.ring, cqe)
		       submitted := C.io_uring_submit(&worker.ring)
		       $if verbose ? {
			       eprintln('[DEBUG] Submitted ${submitted} SQE(s)\n')
		       }
	       }

	// No global verbose flag needed; debug logs are compile-time gated
}
