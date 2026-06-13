module backend_epoll

import http_server.core
import http_server.epoll
import http_server.socket
import sync.stdatomic
import http_server.tls
import os

#include <errno.h>
#include <sys/epoll.h>
#include <sched.h>

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int
fn C.sched_setaffinity(pid int, cpusetsize usize, mask &u64) int

// maybe_pin_worker pins the calling worker thread to `cpu` when VANILLA_PIN_CPUS
// is set. Opt-in: pinning warms caches and stops migration on dedicated
// hardware, but can hurt on a shared box (a co-located load generator competing
// for the same core), so it is off by default. A failure (offline CPU, cgroup
// cpuset restriction) is non-fatal — the thread just stays schedulable anywhere.
fn maybe_pin_worker(cpu int) {
	if cpu < 0 || cpu >= 1024 || os.getenv('VANILLA_PIN_CPUS') == '' {
		return
	}
	mut set := [16]u64{} // CPU_SETSIZE/64 words → up to 1024 CPUs
	set[cpu / 64] |= u64(1) << u32(cpu % 64)
	C.sched_setaffinity(0, usize(sizeof(set)), &set[0])
}

// release_conn closes a connection: removes it from epoll (which closes the fd)
// and decrements the global active-connection count. Every connection-close site
// goes through here so max_connections accounting stays exact.
@[inline]
fn release_conn(epoll_fd int, fd int, active_conns &core.Counter) {
	epoll.remove_fd_from_epoll(epoll_fd, fd)
	stdatomic.add_i64(&active_conns.n, -1)
}

// (The plain request cycle now lives in the per-fd state machine — see
// conn_state.c.v: handle_readable_plain / handle_writable_plain.)

// Accept loop for the main epoll thread. Distributes new client connections to worker threads (round-robin).
fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int, limits core.Limits, active_conns &core.Counter) {
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
				next_worker = (next_worker + 1) % core.max_thread_pool_size
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

// Plain (HTTP) worker: owns the per-fd connection state table (persistent
// buffers, cross-edge reads, EPOLLOUT writes).
@[direct_array_access; manualfree]
fn process_events_plain(worker_id int, epoll_fd int, request_handler core.RequestHandler, limits core.Limits, counter &core.Counter, active_conns &core.Counter) {
	maybe_pin_worker(worker_id)
	// This worker can stream file bodies with sendfile(2): let handlers hand a
	// file off via core.queue_file instead of copying it through write_buf.
	core.enable_sendfile()
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut st := new_plain_state()
	// Only arm the timeout sweep if a deadline is actually configured.
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	// Adaptive epoll_wait timeout (busy-poll hybrid). After a wait that returned
	// events, poll again with timeout 0: under sustained load the next batch is
	// usually already queued, so we skip the block→wake scheduler round-trip that
	// a blocking epoll_wait pays per iteration. An EMPTY poll drops straight back
	// to a blocking wait (250 ms when something is parked so the timeout sweep
	// still fires, otherwise -1 = sleep until the next event), so an idle worker
	// burns zero CPU — it only ever spins while there is work to do.
	mut hot := false
	for {
		wait_ms := if hot {
			0
		} else if sweep_on && st.parked > 0 {
			250
		} else {
			-1
		}
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, wait_ms)
		if num_events < 0 {
			hot = false
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}
		hot = num_events > 0
		for i in 0 .. num_events {
			fd := epoll.event_fd(events[i])
			ev := events[i].events
			if ev & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				continue
			}
			if ev & u32(C.EPOLLOUT) != 0 {
				if !handle_writable_plain(epoll_fd, fd, active_conns, mut st) {
					continue // connection closed — skip the EPOLLIN half of this event
				}
			}
			if ev & u32(C.EPOLLIN) != 0 {
				handle_readable_plain(request_handler, epoll_fd, fd, limits, counter, active_conns, mut
					st)
			}
		}
		// After handling this batch (or a timeout wake with num_events == 0),
		// reap any connection whose read/write deadline has passed.
		if sweep_on && st.parked > 0 {
			sweep_timeouts(epoll_fd, active_conns, mut st)
		}
	}
}

// TLS (HTTPS) worker: owns the per-fd TLS session map (handshake + ssl read/write).
@[direct_array_access; manualfree]
fn process_events_tls(worker_id int, epoll_fd int, request_handler core.RequestHandler, limits core.Limits, counter &core.Counter, active_conns &core.Counter, cfg &tls.Config) {
	maybe_pin_worker(worker_id)
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
				if fd !in sessions {
					continue // session closed — skip the EPOLLIN half of this event
				}
			}
			if ev & u32(C.EPOLLIN) != 0 {
				handle_readable_fd_tls(request_handler, epoll_fd, fd, limits, counter,
					active_conns, cfg, mut sessions)
			}
		}
		if sweep_on && sessions.len > 0 {
			sweep_timeouts_tls(epoll_fd, active_conns, mut sessions)
		}
	}
}

pub fn run_epoll_backend(socket_fd int, request_handler core.RequestHandler, port int, limits core.Limits, inflight []&core.Counter, active_conns &core.Counter, tls_config &tls.Config, mut threads []thread) {
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
	mut epoll_fds := []int{len: core.max_thread_pool_size, cap: core.max_thread_pool_size}

	unsafe { epoll_fds.flags.set(.noslices | .noshrink | .nogrow) }
	for i in 0 .. core.max_thread_pool_size {
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
			threads[i] = spawn process_events_tls(i, epoll_fds[i], request_handler, limits,
				counter, active_conns, tls_config)
		} else {
			threads[i] = spawn process_events_plain(i, epoll_fds[i], request_handler, limits,
				counter, active_conns)
		}
	}

	println('listening on http://localhost:${port}/')
	handle_accept_loop(socket_fd, main_epoll_fd, epoll_fds, limits, active_conns)
}
