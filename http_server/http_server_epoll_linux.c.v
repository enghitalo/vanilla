module http_server

import epoll
import socket
import sync.stdatomic
import http_server.tls

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

// (The plain request cycle now lives in the per-fd state machine — see
// conn_state.c.v: handle_readable_plain / handle_writable_plain.)

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

// Plain (HTTP) worker: owns the per-fd connection state map for cross-edge
// reads + EPOLLOUT writes.
@[direct_array_access; manualfree]
fn process_events_plain(epoll_fd int, request_handler fn ([]u8, int) ![]u8, limits Limits, counter &Counter, active_conns &Counter) {
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut conns := map[int]&ConnState{}
	// Only arm the timeout sweep if a deadline is actually configured.
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	for {
		// Block indefinitely unless there are connections parked mid-transfer and a
		// timeout is set — then wake periodically to sweep stale ones. Zero cost on
		// an idle/fast server (conns stays empty ⇒ -1, the original behaviour).
		wait_ms := if sweep_on && conns.len > 0 { 250 } else { -1 }
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, wait_ms)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}
		for i in 0 .. num_events {
			fd := epoll.event_fd(events[i])
			ev := events[i].events
			if ev & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				close_conn(epoll_fd, fd, active_conns, mut conns)
				continue
			}
			if ev & u32(C.EPOLLOUT) != 0 {
				handle_writable_plain(epoll_fd, fd, active_conns, mut conns)
			}
			if ev & u32(C.EPOLLIN) != 0 {
				handle_readable_plain(request_handler, epoll_fd, fd, limits, counter, active_conns, mut
					conns)
			}
		}
		// After handling this batch (or a timeout wake with num_events == 0),
		// reap any connection whose read/write deadline has passed.
		if sweep_on && conns.len > 0 {
			sweep_timeouts(epoll_fd, active_conns, mut conns)
		}
	}
}

// TLS (HTTPS) worker: owns the per-fd TLS session map (handshake + ssl read/write).
@[direct_array_access; manualfree]
fn process_events_tls(epoll_fd int, request_handler fn ([]u8, int) ![]u8, limits Limits, counter &Counter, active_conns &Counter, cfg &tls.Config) {
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut sessions := map[int]&TlsConn{}
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	for {
		wait_ms := if sweep_on && sessions.len > 0 { 250 } else { -1 }
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, wait_ms)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}
		for i in 0 .. num_events {
			fd := epoll.event_fd(events[i])
			ev := events[i].events
			if ev & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				close_tls(epoll_fd, fd, active_conns, mut sessions)
				continue
			}
			if ev & u32(C.EPOLLOUT) != 0 {
				handle_writable_fd_tls(epoll_fd, fd, active_conns, mut sessions)
			}
			if ev & u32(C.EPOLLIN) != 0 {
				handle_readable_fd_tls(request_handler, epoll_fd, fd, limits, counter, active_conns,
					cfg, mut sessions)
			}
		}
		if sweep_on && sessions.len > 0 {
			sweep_timeouts_tls(epoll_fd, active_conns, mut sessions)
		}
	}
}

pub fn run_epoll_backend(socket_fd int, request_handler fn ([]u8, int) ![]u8, port int, limits Limits, inflight []&Counter, active_conns &Counter, tls_config &tls.Config, mut threads []thread) {
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

		// Build per-thread callbacks. The plaintext and TLS paths are SEPARATE
		// Spawn the right concrete worker: HTTPS or plain HTTP. The plain worker
		// has no TLS code at all, so the plain hot path carries zero TLS cost.
		counter := inflight[i] // this worker's own in-flight counter
		if tls_config != unsafe { nil } {
			threads[i] = spawn process_events_tls(epoll_fds[i], request_handler, limits, counter,
				active_conns, tls_config)
		} else {
			threads[i] = spawn process_events_plain(epoll_fds[i], request_handler, limits, counter,
				active_conns)
		}
	}

	println('listening on http://localhost:${port}/')
	handle_accept_loop(socket_fd, main_epoll_fd, epoll_fds, limits, active_conns)
}
