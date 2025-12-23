// http_server_linux.c.v
// Linux-specific HTTP server entry point or helpers

module http_server

import epoll
import io_uring
import socket
import http1_1.response
import http1_1.request

#include <errno.h>
#include <sys/epoll.h>

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
}

const connection_keep_alive_variants = [
	'Connection: keep-alive'.bytes(),
	'connection: keep-alive'.bytes(),
	'Connection: "keep-alive"'.bytes(),
	'connection: "keep-alive"'.bytes(),
	'Connection: Keep-Alive'.bytes(),
	'connection: Keep-Alive'.bytes(),
	'Connection: "Keep-Alive"'.bytes(),
	'connection: "Keep-Alive"'.bytes(),
]!

// Handles a readable client connection: receives the request, routes it, and sends the response.
fn handle_readable_fd(request_handler fn ([]u8, int) ![]u8, epoll_fd int, client_conn_fd int) {
	request_buffer := request.read_request(client_conn_fd) or {
		$if verbose ? {
			eprintln('[epoll-worker] Error reading request from fd ${client_conn_fd}: ${err}')
		}
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

	$if force_keep_alive ? || test {
		// Keep the connection alive unconditionally
		// through -d force_keep_alive flag or during tests
		// tests need to be alive due to how
		// they are implemented in `(mut s Server) test`
		return
	} $else {
		mut keep_alive := false
		for variant in connection_keep_alive_variants {
			mut i := 0
			for i <= request_buffer.len - variant.len {
				if unsafe { vmemcmp(&request_buffer[i], &variant[0], variant.len) } == 0 {
					keep_alive = true
					break
				}
				// Move to next line
				for i < request_buffer.len && request_buffer[i] != `\n` {
					i++
				}
				i++
			}
			if keep_alive {
				break
			}
		}
		if !keep_alive {
			epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		}
	}
}

// Accept loop for the main epoll thread. Distributes new client connections to worker threads (round-robin).
fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int) {
	mut next_worker := 0
	mut event := C.epoll_event{}

	for {
		// Wait for events on the main epoll fd (listening socket)
		num_events := C.epoll_wait(main_epoll_fd, &event, 1, -1)
		$if verbose ? {
			eprintln('[epoll] epoll_wait returned ${num_events}')
		}
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
			$if verbose ? {
				eprintln('[epoll] EPOLLIN event on listening socket')
			}
			for {
				// Accept new client connection
				client_conn_fd := C.accept(socket_fd, C.NULL, C.NULL)
				$if verbose ? {
					println('[epoll] accept() returned ${client_conn_fd}')
				}
				if client_conn_fd < 0 {
					// Check for EAGAIN or EWOULDBLOCK, usually represented by errno 11.
					if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
						$if verbose ? {
							println('[epoll] No more incoming connections to accept (EAGAIN/EWOULDBLOCK)')
						}
						break // No more incoming connections; exit loop.
					}
					eprintln(@LOCATION)
					C.perror(c'Accept failed')
					continue
				}
				// Set client socket to non-blocking
				socket.set_blocking(client_conn_fd, false)
				// Distribute client connection to worker threads (round-robin)
				epoll_fd := epoll_fds[next_worker]
				next_worker = (next_worker + 1) % max_thread_pool_size
				$if verbose ? {
					eprintln('[epoll] Adding client fd ${client_conn_fd} to worker epoll fd ${epoll_fd}')
				}
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
		// Wait for events on the worker's epoll fd
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, -1)
		$if verbose ? {
			eprintln('[epoll-worker] epoll_wait returned ${num_events} on fd ${epoll_fd}')
		}
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
			$if verbose ? {
				eprintln('[epoll-worker] Event for client fd ${client_conn_fd}: events=${events[i].events}')
			}
			// Remove fd if hangup or error
			if events[i].events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				println('[epoll-worker] HUP/ERR on fd ${client_conn_fd}, removing')
				epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
				continue
			}

			// Readable event
			if events[i].events & u32(C.EPOLLIN) != 0 {
				$if verbose ? {
					println('[epoll-worker] EPOLLIN for fd ${client_conn_fd}, calling on_read')
				}
				event_callbacks.on_read(client_conn_fd)
			}

			// Writable event
			if events[i].events & u32(C.EPOLLOUT) != 0 {
				$if verbose ? {
					println('[epoll-worker] EPOLLOUT for fd ${client_conn_fd}, calling on_write')
				}
				event_callbacks.on_write(client_conn_fd)
			}
		}
	}
}

// ==================== Epoll Backend ====================

pub fn run_epoll_backend(socket_fd int, request_handler fn ([]u8, int) ![]u8, port int, mut threads []thread) {
	if socket_fd < 0 {
		return
	}

	// Create main epoll instance
	// the function of the main_epoll_fd is to monitor the listening socket for incoming connections
	// then distribute them to worker threads
	main_epoll_fd := epoll.create_epoll_fd()
	if main_epoll_fd < 0 {
		socket.close_socket(socket_fd)
		exit(1)
	}

	if epoll.add_fd_to_epoll(main_epoll_fd, socket_fd, u32(C.EPOLLIN)) < 0 {
		socket.close_socket(socket_fd)
		socket.close_socket(main_epoll_fd)
		exit(1)
	}

	// the function of this epoll_fds array is to hold epoll fds for each worker thread
	// they are used to distribute client connections among worker threads
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
			socket.close_socket(socket_fd)
			exit(1)
		}

		// Build per-thread callbacks: default to handle_readable_fd; write is a no-op.
		epoll_fd := epoll_fds[i]
		callbacks := epoll.EpollEventCallbacks{
			on_read:  fn [request_handler, epoll_fd] (client_conn_fd int) {
				handle_readable_fd(request_handler, epoll_fd, client_conn_fd)
			}
			on_write: fn (_ int) {}
		}
		threads[i] = spawn process_events(callbacks, epoll_fds[i])
	}

	println('listening on http://localhost:${port}/')
	handle_accept_loop(socket_fd, main_epoll_fd, epoll_fds)
}

// ==================== IO Uring Backend ====================

pub fn run_io_uring_backend(request_handler fn ([]u8, int) ![]u8, port int, mut threads []thread) {
	num_workers := max_thread_pool_size

	for i in 0 .. num_workers {
		mut worker := &io_uring.Worker{}
		worker.cpu_id = i
		worker.listen_fd = -1
		io_uring.pool_init(mut worker)

		// Try to initialize io_uring ring with SQPOLL, fall back if it fails
		mut params := C.io_uring_params{}
		params.flags |= 1 << 3 // IORING_SETUP_SQPOLL
		params.sq_thread_cpu = i // Pin SQ thread to worker CPU
		mut sqpoll_failed := false
		if C.io_uring_queue_init_params(u32(io_uring.default_ring_entries), &worker.ring,
			&params) < 0 {
			eprintln('[io_uring] worker ${i}: SQPOLL failed, falling back to normal io_uring')
			// Try again without SQPOLL
			params = C.io_uring_params{}
			if C.io_uring_queue_init_params(u32(io_uring.default_ring_entries), &worker.ring,
				&params) < 0 {
				eprintln('Failed to initialize io_uring for worker ${i}')
				exit(1)
			}
			sqpoll_failed = true
		}
		// Use single-shot accept for SO_REUSEPORT
		//    worker.use_multishot = false
		if sqpoll_failed {
			eprintln('[io_uring] worker ${i}: single-shot accept enabled (no SQPOLL)')
		} else {
			eprintln('[io_uring] worker ${i}: single-shot accept + SQPOLL enabled')
		}

		// Create per-worker listener
		worker.listen_fd = io_uring.create_listener(port)
		if worker.listen_fd < 0 {
			eprintln('Failed to create listener for worker ${i}')
			exit(1)
		}
		// Spawn worker thread
		threads[i] = spawn io_uring_worker_loop(worker, request_handler)
	}

	println('listening on http://localhost:${port}/ (io_uring)')

	// Keep main thread alive
	for {
		C.sleep(1)
	}
}

// --- io_uring CQE Handlers ---
fn handle_io_uring_accept(worker &io_uring.Worker, cqe &C.io_uring_cqe) {
	res := cqe.res
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
	// Re-arm accept if needed
	if (cqe.flags & u32(1 << 1)) == 0 || res < 0 {
		$if verbose ? {
			eprintln('[DEBUG] Re-arming accept (end of multishot or error)')
		}
		io_uring.prep_accept(&worker.ring, worker.listen_fd, worker.use_multishot)
	}
}

fn handle_io_uring_read(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn ([]u8, int) ![]u8) {
	res := cqe.res
	c_ptr := io_uring.unpack_ptr(C.io_uring_cqe_get_data64(cqe))
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
			return
		}
		conn.response_buffer = response_data
		conn.bytes_sent = 0
		$if verbose ? {
			eprintln('[DEBUG] Preparing write of ${conn.response_buffer.len} bytes')
		}
		io_uring.prep_write(&worker.ring, mut *conn, conn.response_buffer.data, usize(conn.response_buffer.len))
	}
}

fn handle_io_uring_write(worker &io_uring.Worker, cqe &C.io_uring_cqe) {
	res := cqe.res
	c_ptr := io_uring.unpack_ptr(C.io_uring_cqe_get_data64(cqe))
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

fn dispatch_io_uring_cqe(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn ([]u8, int) ![]u8) {
	data := C.io_uring_cqe_get_data64(cqe)
	op := io_uring.unpack_op(data)
	match op {
		io_uring.op_accept { handle_io_uring_accept(worker, cqe) }
		io_uring.op_read { handle_io_uring_read(worker, cqe, handler) }
		io_uring.op_write { handle_io_uring_write(worker, cqe) }
		else {}
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
		dispatch_io_uring_cqe(worker, cqe, handler)
		C.io_uring_cqe_seen(&worker.ring, cqe)
		submitted := C.io_uring_submit(&worker.ring)
		$if verbose ? {
			eprintln('[DEBUG] Submitted ${submitted} SQE(s)\n')
		}
	}

	mut pending := 0
	for {
		mut cqe := &C.io_uring_cqe(unsafe { nil })
		for C.io_uring_peek_cqe(&worker.ring, &cqe) == 0 {
			dispatch_io_uring_cqe(worker, cqe, handler)
			pending++
			C.io_uring_cqe_seen(&worker.ring, cqe)
		}
		if pending > 0 {
			submitted := C.io_uring_submit(&worker.ring)
			$if verbose ? {
				eprintln('[DEBUG] Submitted ${submitted} SQE(s)')
			}
			pending = 0
		}
	}
}

pub fn (mut server Server) run() {
	match server.io_multiplexing {
		.epoll {
			run_epoll_backend(server.socket_fd, server.request_handler, server.port, mut
				server.threads)
		}
		.io_uring {
			run_io_uring_backend(server.request_handler, server.port, mut server.threads)
		}
	}
}
