module http_server

import epoll
import socket
import http1_1.response
import http1_1.request
import sync.stdatomic

#include <errno.h>
#include <sys/epoll.h>

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int

// release_conn closes a connection: removes it from epoll (which closes the fd)
// and decrements the global active-connection count. Every connection-close site
// goes through here so max_connections accounting stays exact.
@[inline]
fn release_conn(epoll_fd int, fd int, active_conns &Counter) {
	epoll.remove_fd_from_epoll(epoll_fd, fd)
	stdatomic.add_i64(&active_conns.n, -1)
}

// Handles a readable client connection: receives the request, routes it, and sends the response.
@[manualfree]
fn handle_readable_fd(request_handler fn ([]u8, int) ![]u8, epoll_fd int, client_conn_fd int, limits Limits, counter &Counter, active_conns &Counter) {
	// Mark this worker busy for the whole request so shutdown() can drain
	// precisely. Per-worker counter on its own cache line: no contention.
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}
	request_buffer := request.read_request(client_conn_fd, limits.max_header_bytes, limits.max_body_bytes) or {
		$if verbose ? {
			eprintln('[epoll-worker] Error reading request from fd ${client_conn_fd}: ${err}')
		}
		// The framer/read loop puts the HTTP status to send in err.code().
		match err.code() {
			413 { response.send_status_413_response(client_conn_fd) }
			431 { response.send_status_431_response(client_conn_fd) }
			400 { response.send_bad_request_response(client_conn_fd) }
			else { response.send_status_444_response(client_conn_fd) } // connection-level
		}
		release_conn(epoll_fd, client_conn_fd, active_conns)
		return
	}

	defer {
		unsafe { request_buffer.free() }
	}

	response_buffer := request_handler(request_buffer, client_conn_fd) or {
		eprintln('Error handling request: ${err}')
		response.send_bad_request_response(client_conn_fd)
		release_conn(epoll_fd, client_conn_fd, active_conns)
		return
	}
	defer {
		unsafe { response_buffer.free() }
	}

	response.send_response(client_conn_fd, response_buffer.data, response_buffer.len) or {
		release_conn(epoll_fd, client_conn_fd, active_conns)
		return
	}
}

// Accept loop for the main epoll thread. Distributes new client connections to worker threads (round-robin).
fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int, limits Limits, active_conns &Counter) {
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
				// Accept new client connection (already non-blocking via accept4).
				client_conn_fd := socket.accept_client(socket_fd)
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
				// Enforce max_connections: refuse (close immediately) once at the cap.
				if limits.max_connections > 0
					&& stdatomic.load_i64(&active_conns.n) >= i64(limits.max_connections) {
					socket.close_socket(client_conn_fd)
					continue
				}
				// Disable Nagle so small responses are not delayed.
				socket.set_tcp_nodelay(client_conn_fd)
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
				// Registered successfully — count it (released at close via release_conn).
				stdatomic.add_i64(&active_conns.n, 1)
			}
		}
	}
}

@[direct_array_access; manualfree]
fn process_events(event_callbacks epoll.EpollEventCallbacks, epoll_fd int, active_conns &Counter) {
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
			client_conn_fd := epoll.event_fd(events[i])
			$if verbose ? {
				eprintln('[epoll-worker] Event for client fd ${client_conn_fd}: events=${events[i].events}')
			}
			// Remove fd if hangup or error
			if events[i].events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				$if verbose ? {
					println('[epoll-worker] HUP/ERR on fd ${client_conn_fd}, removing')
				}
				release_conn(epoll_fd, client_conn_fd, active_conns)
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

pub fn run_epoll_backend(socket_fd int, request_handler fn ([]u8, int) ![]u8, port int, limits Limits, inflight []&Counter, active_conns &Counter, mut threads []thread) {
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
		counter := inflight[i] // this worker's own in-flight counter
		callbacks := epoll.EpollEventCallbacks{
			on_read:  fn [request_handler, epoll_fd, limits, counter, active_conns] (client_conn_fd int) {
				handle_readable_fd(request_handler, epoll_fd, client_conn_fd, limits, counter,
					active_conns)
			}
			on_write: fn (_ int) {}
		}
		threads[i] = spawn process_events(callbacks, epoll_fds[i], active_conns)
	}

	println('listening on http://localhost:${port}/')
	handle_accept_loop(socket_fd, main_epoll_fd, epoll_fds, limits, active_conns)
}
