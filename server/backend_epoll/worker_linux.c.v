module backend_epoll

import core
import epoll
import socket
import sync.stdatomic
import tls
import os
import time

#include <errno.h>
#include <sys/epoll.h>
#include <sched.h>
#include <sys/eventfd.h>

fn C.perror(s &char)
fn C.eventfd(initval u32, flags int) int
fn C.sleep(seconds u32) u32
fn C.close(fd int) int
// mask is a cpu_set_t* in <sched.h>; we hand it a raw u64 word array, so keep
// the binding untyped rather than model cpu_set_t (whose header typedef would
// clash with any V-side struct declaration).
fn C.sched_setaffinity(pid int, cpusetsize usize, mask voidptr) int

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
	C.sched_setaffinity(0, usize(sizeof(set)), voidptr(&set[0]))
}

// release_conn closes a connection: decrements the global active-connection
// count, then removes it from epoll (which closes the fd). Every
// connection-close site goes through here so max_connections accounting stays
// exact. Decrement FIRST: once the peer can observe the close, its slot is
// already free, so a client that reconnects on EOF is never refused by a
// count that has not caught up.
@[inline]
fn release_conn(epoll_fd int, fd int, active_conns &core.Counter) {
	stdatomic.add_i64(&active_conns.n, -1)
	epoll.remove_fd_from_epoll(epoll_fd, fd)
}

// (The request-serving cycle lives in async_linux.c.v — handle_readable /
// drain_requests / serve_conn — over the per-fd state in conn_state_linux.c.v.)

// Accept loop for the main epoll thread. Distributes new client connections to worker threads (round-robin).
// `conn_events` is the mask each new fd is registered with (see
// accept_events).
fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int, limits core.Limits, active_conns &core.Counter, conn_events u32, queues []&BirthQueue) {
	mut next_worker := 0
	mut event := C.epoll_event{}
	// With accept-time births (EPOLLOUT in conn_events) the registration is
	// tagged, so the worker knows a connection's first event. Decided once.
	births := conn_events & u32(C.EPOLLOUT) != 0

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
				// A tagged registration needs the fd below epoll.accept_tag; one
				// that high only exists if nr_open was raised past 2^30. Refuse it
				// rather than mistake its events for another fd's.
				if client_conn_fd >= epoll.accept_tag {
					socket.close_socket(client_conn_fd)
					continue
				}
				// Disable Nagle so small responses are not delayed.
				socket.set_tcp_nodelay(client_conn_fd)
				// Distribute client connection to worker threads (round-robin)
				epoll_fd := epoll_fds[next_worker]
				worker := next_worker
				next_worker = (next_worker + 1) % epoll_fds.len
				$if verbose ? {
					eprintln('[epoll] Adding client fd ${client_conn_fd} to worker epoll fd ${epoll_fd}')
				}
				// Count it BEFORE registering: once the fd is in the worker's epoll
				// set the worker can close it (and decrement) at any moment — with
				// the accept-time EPOLLOUT edge that is immediate — so counting
				// after the ADD could briefly undercount and over-admit.
				stdatomic.add_i64(&active_conns.n, 1)
				if !births {
					// Tagged too: the worker tells a connection's events from those
					// of an app's fd left in its epoll (event_tagged) with births
					// off as well, at no cost — the same epoll_ctl.
					if epoll.add_fd_to_epoll_tagged(epoll_fd, client_conn_fd, conn_events) < 0 {
						stdatomic.add_i64(&active_conns.n, -1)
						socket.close_socket(client_conn_fd)
					}
					continue
				}
				// A plain worker is told about the connection through its birth
				// queue instead of an EPOLLOUT edge (which would wake it once more
				// per connection); the entry's close_seq is read BEFORE the fd is
				// registered (see BirthQueue). A full queue falls back to EPOLLOUT,
				// as does the TLS worker (no queue).
				mut q := queues[worker]
				queued := q != unsafe { nil } && q.has_room()
				seq := if queued { stdatomic.load_u64(&q.close_seq) } else { u64(0) }
				events := if queued { u32(C.EPOLLIN) | u32(C.EPOLLET) } else { conn_events }
				if epoll.add_fd_to_epoll_tagged(epoll_fd, client_conn_fd, events) < 0 {
					stdatomic.add_i64(&active_conns.n, -1)
					socket.close_socket(client_conn_fd)
					continue
				}
				if queued {
					q.push(client_conn_fd, seq, time.sys_mono_now())
				}
			}
		}
	}
}

// Plain (HTTP) worker: owns the per-fd connection state table (persistent
// buffers, cross-edge reads, EPOLLOUT writes), plus the watch registry that
// resumes parked requests when a watched fd fires. ONE worker, ONE handler
// contract: a handler that never suspends just appends and returns .done, so
// the only extra hot-path cost over the old synchronous-only worker is a
// per-event `watches[fd].active` load.
@[direct_array_access; manualfree]
fn process_events_plain(worker_id int, epoll_fd int, handler core.Handler, make_state fn () voidptr, on_worker_start core.WorkerStartFn, limits core.Limits, counter &core.Counter, active_conns &core.Counter, listen_port int, listen_uds bool, births_q &BirthQueue) {
	maybe_pin_worker(worker_id)
	// Build THIS worker's per-thread state once (e.g. its own DB connection);
	// every handler call on this worker receives it as the worker_state parameter.
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	mut reactor := Reactor{
		watches: []WatchEntry{len: conn_table_min}
	} // flat fd-indexed table of parked requests (grows by doubling)
	// This worker can stream file bodies with sendfile(2): let handlers hand a
	// file off via core.queue_file instead of copying it through write_buf.
	core.enable_sendfile()
	// ...and it can hand a connection over to another protocol's state machine
	// (the conn-mode seam, issue #136): handlers upgrade via core.queue_takeover.
	core.enable_takeover()
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut st := new_plain_state()
	st.inflight = counter // parked requests count toward the shutdown drain (park_conn)
	st.reactor = unsafe { &reactor }
	reactor.st = unsafe { &st }
	// Arm clientless background watches (timerfd refresh, signalfd, ...) on THIS
	// worker's loop, once, before serving. client_fd = -1 makes the watch + its
	// continuation take the clientless path (no conn, scratch buffer).
	if on_worker_start != unsafe { nil } {
		mut startup_loop := core.EventLoop{
			client_fd: -1
			loop_fd:   epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  register_watch
		}
		on_worker_start(state, mut startup_loop)
	}
	// Only run the clock and the timeout sweep if a deadline is actually
	// configured (sweep_interval_ms is 0 when read, write and idle are all off).
	sweep_ms := limits.sweep_interval_ms()
	sweep_on := sweep_ms > 0
	sweep_ns := u64(sweep_ms) * 1_000_000
	st.read_ns = if limits.read_timeout_ms > 0 {
		u64(limits.read_timeout_ms) * 1_000_000
	} else {
		0
	}
	st.idle_ns = u64(limits.idle_ms()) * 1_000_000
	st.listen_port = listen_port
	st.listen_uds = listen_uds
	st.births_q = births_q
	// With a read or idle timeout on, every connection gets its state and a
	// deadline without having to speak (conn_birth): from births_q, with its
	// accept time, or — when the queue was full, or its first event comes
	// before its entry is drained — at its first event, with the batch clock
	// (the EPOLLOUT edge accept then registered the fd for, see accept_events).
	births := st.read_ns != 0 || st.idle_ns != 0
	if st.births_q != unsafe { nil } {
		// The accept thread's wake-up for this worker when it sleeps (push).
		if epoll.add_fd_to_epoll(epoll_fd, st.births_q.wake_fd, u32(C.EPOLLIN) | u32(C.EPOLLET)) < 0 {
			exit(1) // without it a sleeping worker could never learn of a silent connection
		}
	}
	// Adaptive epoll_wait timeout (busy-poll hybrid). After a wait that returned
	// events, poll again with timeout 0: under sustained load the next batch is
	// usually already queued, so we skip the block→wake scheduler round-trip that
	// a blocking epoll_wait pays per iteration. An EMPTY poll drops straight back
	// to a blocking wait (until the next sweep is due — at most sweep_ms — while
	// a deadline is armed; with a birth queue, one grace wait of sweep_ms; then
	// -1 = sleep until the next event), so an idle worker burns zero CPU — it
	// only ever spins while there is work to do.
	mut hot := false
	// rested: the last grace wait ran out with no event, no birth and no
	// signal, so the next wait may be announced and have no timeout.
	mut rested := false
	mut announced := false // this wait was announced to the accept thread (birth_queue_pending)
	for {
		mut grace := false
		wait_ms := if hot {
			0
		} else if sweep_on && st.parked > 0 {
			rested = false // a quiet stretch starts once nothing is armed
			// The end-of-batch check below keeps next_sweep ahead of st.now
			// whenever a deadline is armed; +1 rounds the ms up.
			if st.next_sweep > st.now { int((st.next_sweep - st.now) / 1_000_000) + 1 } else { 0 }
		} else if st.births_q != unsafe { nil } {
			if !rested {
				// Just went quiet: one bounded look first (a queued connection is
				// born at the next pass), so connection churn does not pay the
				// eventfd wake-up of a sleeping worker.
				grace = true
				sweep_ms
			} else if birth_queue_pending(mut st.births_q) {
				0 // entries arrived while deciding to sleep: take them now
			} else {
				// Quiet for a whole interval: sleep until the next event. The
				// accept thread wakes this worker through its eventfd when it
				// queues a connection (birth_queue_pending announced the sleep).
				announced = true
				-1
			}
		} else {
			-1 // nothing armed: sleep until the next event
		}
		mut num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size,
			wait_ms)
		if num_events < 0 {
			hot = false
			if C.errno != C.EINTR {
				C.perror(c'epoll_wait')
				break
			}
			// Interrupted (e.g. a GC stop-the-world signal): an empty batch. It
			// still reads the clock and reaches the sweep check below, so a
			// steady stream of signals cannot postpone the sweep forever. Not
			// a finished grace wait.
			num_events = 0
			grace = false
		}
		if announced {
			stdatomic.store_u64(&st.births_q.sleeping, 0)
			announced = false
		}
		if sweep_on {
			st.tick() // the batch clock: one read per iteration, reused by every deadline
		}
		st.batch_seq = st.close_seq // closes from here on are in this batch (closed_in_batch)
		reactor.batch++ // watches ADDed from here on are in this batch (WatchEntry.added)
		if st.births_q != unsafe { nil } {
			// Connections the accept thread queued: born now, with their accept
			// time, before their first events below are handled. Any event or
			// birth ends a quiet stretch; a grace wait that ran out ends it rested.
			born := drain_births(mut st)
			if num_events > 0 || born > 0 {
				rested = false
			} else if grace {
				rested = true
			}
		}
		hot = num_events > 0
		for i in 0 .. num_events {
			fd := epoll.event_fd(events[i])
			mut ev := events[i].events
			// A watched external fd became ready → run its continuation (a parked
			// request resume, or a clientless background watch like a refresh
			// timerfd). `reactor.armed` is the pure-sync fast path: until the
			// first watch is ever armed, this is one predictable bool test.
			if reactor.armed && fd < reactor.watches.len && reactor.watches[fd].active {
				if reactor.watches[fd].added == reactor.batch {
					// The watch ADDed this fd earlier in this batch, so the
					// number was not in the epoll set when the batch was
					// collected: this event describes a file that is gone (closed
					// — by the runtime or the app — and its number reused).
					// Routed on, it would run the new owner's continuation with
					// the old mask: "your fd hung up", or a read of an fd that is
					// not ready.
					continue
				}
				on_watch_ready(handler, mut reactor, epoll_fd, fd, ev, limits, counter,
					active_conns, mut st, state)
				continue
			}
			// fd's state, looked up ONCE per event and handed to the handlers.
			mut cs := unsafe { &ConnState(nil) }
			if fd < st.conns.len {
				cs = st.conns[fd]
			}
			if unsafe { cs == nil } {
				if st.births_q != unsafe { nil } && fd == st.births_q.wake_fd {
					// The accept thread queued a connection while this worker
					// slept: reset the eventfd (drain_births above took the entry).
					mut n := u64(0)
					C.read(fd, &n, 8)
					continue
				}
				if st.closed_in_batch(fd) {
					// Closed earlier in this batch — a client, or a watch fd torn
					// down with it: this event describes the registration that
					// close removed (accept may already have reused the number,
					// for a connection whose own first event arrives with a later
					// wait). Handled, it released the closed connection a second
					// time, or built a zombie on the number. Nothing to do.
					continue
				}
				// No state yet, and active watch fds were routed above. Accept
				// registers every connection TAGGED (epoll.add_fd_to_epoll_tagged).
				// With births on it is born before it speaks: from births_q at the
				// top of this iteration, or by its first report here (queued too
				// late for this pass, or queue full, so registered for EPOLLOUT,
				// which a new socket reports at once, even when the peer already
				// reset or half-closed it). With births off its first event gives
				// it its state below (handle_readable).
				if !epoll.event_tagged(events[i]) {
					// Not an accept registration: an app's fd that a finished watch
					// left registered, level-triggered (a pooled connection kept
					// open after .done, or one a continuation stepped away from).
					// Never served as a connection — its zombie state would read
					// the app's bytes, answer into them and later close the fd.
					// Detach it (never close it: the app owns it) so it cannot
					// spin the worker: it would report again on every wait. Its
					// next watch_fd adds it back (register_watch falls back to ADD)
					// and a level-triggered fd then reports its readiness again.
					// Only an OPEN fd that is not a socket accepted on the listener
					// is detached. A closed one has no registration left: a DEL
					// could only hit a connection accept reused the number for in
					// between. An accepted socket is kept: the number was reused,
					// and its own tagged event follows.
					if st.leftover_fd(fd) {
						epoll.detach_fd_from_epoll(epoll_fd, fd)
					}
					continue
				}
				if births {
					// A tagged event on an fd with no state, not closed in this
					// batch: the connection's first report (its birth-queue entry,
					// if any, then finds it born).
					cs = conn_birth(fd, st.now, mut st)
					// Born, with nothing to write: skip the EPOLLOUT half. Read on
					// EPOLLIN (the request often arrives with the connection, and
					// under EPOLLET a skipped edge is never reported again) and on
					// EPOLLHUP/EPOLLERR too (the recv sees the EOF or the error and
					// closes). The fd stays registered for EPOLLOUT until its next
					// event: that one carries EPOLLOUT too, and handle_writable_plain
					// drops it (a spurious wake). Leaving it until then, after this
					// read drained the socket, never re-queues an edge, and a
					// connection closed before its next event never pays a MOD.
					ev = if ev & (u32(C.EPOLLIN) | u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0 {
						u32(C.EPOLLIN)
					} else {
						0
					}
				}
			}
			if ev & (u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0 {
				close_client(mut reactor, epoll_fd, fd, active_conns, mut st) // tears any watch down first
				continue
			}
			if ev & u32(C.EPOLLOUT) != 0 {
				if !handle_writable_plain(epoll_fd, fd, cs, active_conns, mut st) {
					continue // connection closed — skip the EPOLLIN half of this event
				}
			}
			if ev & u32(C.EPOLLIN) != 0 {
				handle_readable(handler, mut reactor, epoll_fd, fd, cs, limits, counter, active_conns, mut
					st, state)
			}
		}
		// After handling this batch (or a timeout wake with num_events == 0),
		// reap any connection whose read/write/idle deadline has passed — at most
		// once per sweep interval, so a busy worker does not walk its connection
		// table after every batch.
		if sweep_on && st.parked > 0 && st.now >= st.next_sweep {
			sweep_timeouts(epoll_fd, active_conns, mut st)
			st.next_sweep = st.now + sweep_ns
		}
	}
}

// TLS (HTTPS) worker: owns the per-fd TLS session map (handshake + ssl read/write).
// The TLS worker has no watch reactor, so handlers here must complete
// synchronously: .suspend closes the connection (async-over-TLS is a follow-up).
@[direct_array_access; manualfree]
fn process_events_tls(worker_id int, epoll_fd int, handler core.Handler, make_state fn () voidptr, limits core.Limits, counter &core.Counter, active_conns &core.Counter, cfg &tls.Config) {
	maybe_pin_worker(worker_id)
	// Build THIS worker's per-thread state ONCE — same as the plaintext worker;
	// every handler call reaches it via worker.state.
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	// This worker can stream file bodies with sendfile(2) on kernel-TLS
	// connections, where the kernel encrypts what sendfile writes. The
	// hand-off (core.queue_file) is gated per request: handle_readable_fd_tls
	// closes it for a userspace-TLS connection before calling the handler.
	core.enable_sendfile()
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut sessions := map[int]&TlsConn{}
	// Resolved once: the keep-alive idle budget (0 = off) and the sweep cadence
	// (0 = no deadline is ever armed: no sweep, no clock reads, no wakes).
	idle_ms := limits.idle_ms()
	sweep_ms := limits.sweep_interval_ms()
	sweep_on := sweep_ms > 0
	sweep_ns := u64(sweep_ms) * 1_000_000
	mut next_sweep := u64(0)
	mut sweep_wait := sweep_ms // ms until next_sweep, as of the last sweep call
	// Reused by every sweep (cleared, never reallocated past its high-water
	// mark): the sweep allocates nothing, which -gc none requires.
	mut expired := []int{cap: 64}
	unsafe { expired.flags.set(.noslices) } // a growth frees the old block
	for {
		// Every session may carry a deadline (from accept on), so while any
		// exists wake no later than the next sweep is due; otherwise sleep
		// until the next event. (sessions only changes in the batch or the
		// sweep, and the sweep runs after any batch that leaves one, so
		// sweep_wait is current whenever it is used.)
		wait_ms := if sweep_on && sessions.len > 0 { sweep_wait } else { -1 }
		mut num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size,
			wait_ms)
		if num_events < 0 {
			if C.errno != C.EINTR {
				C.perror(c'epoll_wait')
				break
			}
			// Interrupted: an empty batch, so the sweep below still runs on a
			// fresh clock and recomputes sweep_wait (a stream of signals must not
			// keep re-arming a stale full-length wait).
			num_events = 0
		}
		for i in 0 .. num_events {
			fd := epoll.event_fd(events[i])
			ev := events[i].events
			if ev & (u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0 {
				close_tls(epoll_fd, fd, active_conns, mut sessions)
				continue
			}
			mut resume := false
			if ev & u32(C.EPOLLOUT) != 0 {
				// Also the birth of a connection accept registered with EPOLLOUT.
				resume = handle_writable_fd_tls(epoll_fd, fd, limits, idle_ms, active_conns,
					cfg, mut sessions)
				if fd !in sessions {
					continue // session closed — skip the EPOLLIN half of this event
				}
			}
			// resume: a parked response drained (or the handshake completed), so
			// read even without EPOLLIN — bytes left unread meanwhile get no new edge.
			if ev & u32(C.EPOLLIN) != 0 || resume {
				handle_readable_fd_tls(handler, state, epoll_fd, fd, limits, idle_ms, counter,
					active_conns, cfg, mut sessions)
			}
		}
		// After the batch (or a timeout wake), reap expired connections — at
		// most once per sweep interval: one clock read per busy batch, not a
		// walk of every session.
		if sweep_on && sessions.len > 0 {
			next_sweep, sweep_wait = sweep_timeouts_tls(epoll_fd, active_conns, next_sweep,
				sweep_ns, mut expired, mut sessions)
		}
	}
}

pub fn run_epoll_backend(socket_fd int, handler core.Handler, make_state fn () voidptr, on_worker_start core.WorkerStartFn, after_server_start core.AfterStartFn, port int, limits core.Limits, inflight []&core.Counter, active_conns &core.Counter, tls_config &tls.Config, mut threads []thread) {
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
	// One worker epoll fd per worker thread. threads was sized by new_server from
	// config.workers (default nr_cpus), so its length is this server's worker count.
	mut epoll_fds := []int{len: threads.len, cap: threads.len}
	// One birth queue per plain worker, only when accept-time births are on
	// (see BirthQueue); the TLS worker is told by an EPOLLOUT edge instead.
	queue_births := tls_config == unsafe { nil } && accept_events(limits) & u32(C.EPOLLOUT) != 0
	mut queues := []&BirthQueue{len: threads.len, init: unsafe { nil }}
	if queue_births {
		for i in 0 .. threads.len {
			queues[i] = &BirthQueue{
				wake_fd: C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
			}
			if queues[i].wake_fd < 0 {
				C.perror(c'eventfd')
				exit(1)
			}
		}
	}
	// The listener's own address (once, here): a plain worker never detaches
	// a socket accepted on it (PlainState.leftover_fd).
	listen_family, listen_port, _ := sock_local(socket_fd)
	listen_uds := listen_family == C.AF_UNIX

	unsafe { epoll_fds.flags.set(.noslices | .noshrink | .nogrow) }
	for i in 0 .. threads.len {
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

		// Spawn the right concrete worker: HTTPS or plain HTTP. The plain worker
		// has no TLS code at all, so the plain hot path carries zero TLS cost.
		counter := inflight[i] // this worker's own in-flight counter
		if tls_config != unsafe { nil } {
			threads[i] = spawn process_events_tls(i, epoll_fds[i], handler, make_state, limits,
				counter, active_conns, tls_config)
		} else {
			threads[i] = spawn process_events_plain(i, epoll_fds[i], handler, make_state,
				on_worker_start, limits, counter, active_conns, listen_port, listen_uds, queues[i])
		}
	}

	if tls_config != unsafe { nil } && threads.len > 1 && !tls.parallel_crypto() {
		// Correct either way (the shim serializes calls into Mbed TLS), but the
		// workers take turns in the crypto library: say how to lift that.
		eprintln('[tls] Mbed TLS was built without MBEDTLS_THREADING_C: the ${threads.len} TLS workers take turns in the crypto library (handshakes, and record crypto without kTLS). Build Mbed TLS with MBEDTLS_THREADING_C and MBEDTLS_THREADING_PTHREAD to run it in parallel.')
	}
	println('listening on http://localhost:${port}/')
	// Server is accepting (listener + workers up); fire the one-shot lifecycle hook
	// on this (main) thread right before we block in the accept loop.
	if after_server_start != unsafe { nil } {
		after_server_start()
	}
	handle_accept_loop(socket_fd, main_epoll_fd, epoll_fds, limits, active_conns, accept_events(limits),
		queues)
}

// accept_events is the epoll mask a freshly accepted fd is registered with.
// Workers create per-connection state lazily, on the fd's first event, and
// their deadline sweeps only see connections that have state — so with plain
// EPOLLIN|EPOLLET a peer that never sends a byte (or a TLS client stuck
// before its ClientHello) is invisible to the worker and is never reaped.
// When a deadline must start at accept (read_timeout_ms, or an idle budget),
// the fd is also registered for EPOLLOUT: a new socket is writable at once,
// so the kernel queues exactly one event on ADD and the worker learns about
// the connection immediately. The registration is tagged
// (epoll.add_fd_to_epoll_tagged), and the worker treats that first tagged
// EPOLLOUT on an fd without state as the connection's birth: the plain worker
// creates the state and arms the deadline, with no syscall; the TLS worker
// creates its session there and switches the fd back to EPOLLIN|EPOLLET. A
// plain worker is told through its BirthQueue instead (registered with
// EPOLLIN|EPOLLET, tagged), so this mask is only its fallback when the queue is
// full. With no timeouts the mask is unchanged and nothing is tagged, so the
// default path pays nothing.
fn accept_events(limits core.Limits) u32 {
	if limits.read_timeout_ms > 0 || limits.idle_ms() > 0 {
		return u32(C.EPOLLIN) | u32(C.EPOLLOUT) | u32(C.EPOLLET)
	}
	return u32(C.EPOLLIN) | u32(C.EPOLLET)
}
