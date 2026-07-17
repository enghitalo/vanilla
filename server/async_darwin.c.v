// Request serving + watch/park/resume runtime for the macOS (kqueue) backend —
// the counterpart of backend_epoll/async_linux.c.v. Same handler contract
// (core.Handler + worker.watch(fd, interest, cont, udata) + core.Step), so a
// handler that parks on a DB socket / upstream / timer / pipe runs unchanged on
// Linux and macOS; only the fd registration differs (kqueue EVFILT_READ here,
// epoll EPOLLIN there).
//
// The macOS HTTP path is per-request (no persistent ConnState, no pipelining), so
// this is a small, self-contained reactor: a per-worker watch registry plus a
// per-connection response buffer (KqConn.out) held across a suspend. Scope
// matches the Linux runtime minus the Linux-only pipelining/streaming.

module server

import kqueue
import http1.request
import http1.response
import core

// KqConn holds a connection's response buffer across a suspend (the macOS sync
// path allocates a fresh buffer per request; an async request must keep it while
// the watch is pending). awaiting_fd is the ext fd this conn is parked on (-1 if
// not parked) so a client close can tear the watch down.
@[heap]
struct KqConn {
mut:
	out         []u8
	awaiting_fd int = -1
}

// KqWatch records one parked request keyed by the watched ext fd.
struct KqWatch {
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
}

// KqReactor is the per-worker async state: response buffers per client + the
// watch registry. One per worker thread, so no lock.
@[heap]
struct KqReactor {
mut:
	conns   map[int]&KqConn
	watches map[int]KqWatch
}

// kqueue_async_register is installed into EventLoop.register on macOS: record
// the parked request and add the ext fd to this worker's kqueue.
fn kqueue_async_register(mut w core.EventLoop, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	mut r := unsafe { &KqReactor(w.reactor) }
	r.watches[ext_fd] = KqWatch{
		client_fd: w.client_fd
		cont:      cont
		udata:     udata
	}
	filter := if interest == .writable { kqueue.evfilt_write } else { kqueue.evfilt_read }
	kqueue.add_fd_to_kqueue(w.loop_fd, ext_fd, filter)
	w.last_watched = ext_fd
}

// process_kqueue_worker is the worker loop (one per worker thread). Client
// fds (registered by the accept loop) and watched ext fds share this kqueue.
fn process_kqueue_worker(kq int, handler core.Handler, make_state fn () voidptr, limits Limits) {
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	mut reactor := KqReactor{
		conns:   map[int]&KqConn{}
		watches: map[int]KqWatch{}
	}
	mut events := [1024]C.kevent{}
	for {
		nev := kqueue.wait_kqueue(kq, &events[0], 1024, -1)
		if nev < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'kevent worker')
			break
		}
		for i in 0 .. nev {
			fd := int(events[i].ident)
			// A watched ext fd became ready → run its continuation.
			if watch := reactor.watches[fd] {
				reactor.watches.delete(fd)
				rerr := (events[i].flags & (kqueue.ev_eof | kqueue.ev_error)) != 0
				kq_run_cont(mut reactor, kq, watch, fd, rerr, state)
				continue
			}
			// Client connection.
			eof := (events[i].flags & (kqueue.ev_eof | kqueue.ev_error)) != 0
			if eof && events[i].data == 0 {
				// EOF with no unread bytes: the peer closed and there is nothing left
				// to answer — drop the connection.
				kq_close(mut reactor, kq, fd)
				continue
			}
			// Either a normal readable event, OR EV_EOF WITH unread bytes still
			// queued: a client that sent a complete request and then half-closed its
			// write side (SHUT_WR) shows up here. We MUST still read and answer that
			// request on the open write half (RFC 9112 §9.6, issue #103) instead of
			// closing on the EOF flag alone.
			kq_handle_request(handler, mut reactor, kq, fd, limits, state)
			// After answering a half-closed peer, close — it can send nothing more,
			// so keep-alive is pointless. But NOT if the handler parked the request
			// on a watch (.suspend): its continuation still owes a response on the
			// open write half, and kq_close would abort it. kq_handle_request may
			// also have already closed the fd (send error / .close); re-closing a
			// gone fd is a harmless no-op, but skip it when the request parked.
			if eof {
				parked := if conn := reactor.conns[fd] { conn.awaiting_fd >= 0 } else { false }
				if !parked {
					kq_close(mut reactor, kq, fd)
				}
			}
		}
	}
}

// kq_handle_request reads one request and dispatches the handler.
@[manualfree]
fn kq_handle_request(h core.Handler, mut reactor KqReactor, kq int, fd int, limits Limits, state voidptr) {
	request_buffer := request.read_request(fd, limits.max_header_bytes, limits.max_body_bytes) or {
		match err.code() {
			413 {
				response.send_status_413_response(fd)
			}
			431 {
				response.send_status_431_response(fd)
			}
			400 {
				response.send_bad_request_response(fd)
			}
			else {
				if err.msg() == 'no data available' {
					return
				}
				if err.msg() != 'client closed connection' {
					response.send_status_444_response(fd)
				}
			}
		}

		kq_close(mut reactor, kq, fd)
		return
	}
	defer {
		unsafe { request_buffer.free() }
	}
	mut conn := reactor.conns[fd] or {
		c := &KqConn{
			out: []u8{len: 0, cap: 4096}
		}
		reactor.conns[fd] = c
		c
	}
	conn.out.clear()
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   kq
		reactor:   unsafe { voidptr(&reactor) }
		register:  kqueue_async_register
	}
	match h(request_buffer, mut conn.out, fd, state, mut event_loop) {
		.done {
			response.send_response(fd, conn.out.data, conn.out.len) or {
				kq_close(mut reactor, kq, fd)
			}
			// keep-alive: fd stays registered for the next request
		}
		.suspend {
			conn.awaiting_fd = event_loop.last_watched // parked; resumed by kq_run_cont
		}
		.close {
			// Flush-then-close (the core.Step contract): the handler's error
			// response, if any, must reach the client before the drop.
			if conn.out.len > 0 {
				response.send_response(fd, conn.out.data, conn.out.len) or {}
			}
			kq_close(mut reactor, kq, fd)
		}
	}
}

// kq_run_cont resumes a parked request when its watched fd fires.
fn kq_run_cont(mut reactor KqReactor, kq int, watch KqWatch, ext_fd int, ready_err bool, state voidptr) {
	mut conn := reactor.conns[watch.client_fd] or { return } // client went away
	conn.awaiting_fd = -1
	mut event_loop := core.EventLoop{
		client_fd: watch.client_fd
		loop_fd:   kq
		reactor:   unsafe { voidptr(&reactor) }
		register:  kqueue_async_register
	}
	match watch.cont(mut conn.out, ext_fd, ready_err, watch.udata, state, mut event_loop) {
		.done {
			response.send_response(watch.client_fd, conn.out.data, conn.out.len) or {
				kq_close(mut reactor, kq, watch.client_fd)
			}
		}
		.suspend {
			conn.awaiting_fd = event_loop.last_watched // re-armed (multi-step); stay parked
		}
		.close {
			// Flush-then-close: send whatever the continuation appended first.
			if conn.out.len > 0 {
				response.send_response(watch.client_fd, conn.out.data, conn.out.len) or {}
			}
			kq_close(mut reactor, kq, watch.client_fd)
		}
	}
}

// kq_close drops a connection, first tearing down any watch it is parked on
// (which closes that request-owned ext fd) so nothing leaks.
fn kq_close(mut reactor KqReactor, kq int, fd int) {
	if mut conn := reactor.conns[fd] {
		if conn.awaiting_fd >= 0 {
			reactor.watches.delete(conn.awaiting_fd)
			kqueue.remove_fd_from_kqueue(kq, conn.awaiting_fd) // EV_DELETE + close the ext fd
		}
		unsafe { conn.out.free() }
		reactor.conns.delete(fd)
	}
	kqueue.remove_fd_from_kqueue(kq, fd) // EV_DELETE + close the client fd
}
