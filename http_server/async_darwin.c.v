// Request serving + watch/park/resume runtime for the macOS (kqueue) backend —
// the counterpart of backend_epoll/async_linux.c.v. Same handler contract
// (core.Handler + ctx.watch(fd, interest, cont, udata) + core.Step), so a
// handler that parks on a DB socket / upstream / timer / pipe runs unchanged on
// Linux and macOS; only the fd registration differs (kqueue EVFILT_READ here,
// epoll EPOLLIN there).
//
// The macOS HTTP path is per-request (no persistent ConnState, no pipelining), so
// this is a small, self-contained reactor: a per-worker watch registry plus a
// per-connection response buffer (KqConn.out) held across a suspend. Scope
// matches the Linux runtime minus the Linux-only pipelining/streaming.

module http_server

import kqueue
import http1_1.request
import http1_1.response
import http_server.core

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

// kqueue_async_register is installed into Ctx.register on macOS: record the
// parked request and add the ext fd to this worker's kqueue.
fn kqueue_async_register(mut ac core.Ctx, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	mut r := unsafe { &KqReactor(ac.reactor) }
	r.watches[ext_fd] = KqWatch{
		client_fd: ac.client_fd
		cont:      cont
		udata:     udata
	}
	filter := if interest == .writable { kqueue.evfilt_write } else { kqueue.evfilt_read }
	kqueue.add_fd_to_kqueue(ac.loop_fd, ext_fd, filter)
	ac.last_watched = ext_fd
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
			if w := reactor.watches[fd] {
				reactor.watches.delete(fd)
				rerr := (events[i].flags & (kqueue.ev_eof | kqueue.ev_error)) != 0
				kq_run_cont(mut reactor, kq, w, fd, rerr, state)
				continue
			}
			// Client connection.
			if (events[i].flags & (kqueue.ev_eof | kqueue.ev_error)) != 0 {
				kq_close(mut reactor, kq, fd)
				continue
			}
			kq_handle_request(handler, mut reactor, kq, fd, limits, state)
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
	mut ac := core.Ctx{
		client_fd: fd
		state:     state
		loop_fd:   kq
		reactor:   unsafe { voidptr(&reactor) }
		register:  kqueue_async_register
	}
	match h(request_buffer, mut conn.out, mut ac) {
		.done {
			response.send_response(fd, conn.out.data, conn.out.len) or {
				kq_close(mut reactor, kq, fd)
			}
			// keep-alive: fd stays registered for the next request
		}
		.suspend {
			conn.awaiting_fd = ac.last_watched // parked; resumed by kq_run_cont
		}
		.close {
			kq_close(mut reactor, kq, fd)
		}
	}
}

// kq_run_cont resumes a parked request when its watched fd fires.
fn kq_run_cont(mut reactor KqReactor, kq int, w KqWatch, ext_fd int, ready_err bool, state voidptr) {
	mut conn := reactor.conns[w.client_fd] or { return } // client went away
	conn.awaiting_fd = -1
	mut ac := core.Ctx{
		client_fd: w.client_fd
		ready_fd:  ext_fd
		ready_err: ready_err
		udata:     w.udata
		state:     state
		loop_fd:   kq
		reactor:   unsafe { voidptr(&reactor) }
		register:  kqueue_async_register
	}
	match w.cont(mut conn.out, mut ac) {
		.done {
			response.send_response(w.client_fd, conn.out.data, conn.out.len) or {
				kq_close(mut reactor, kq, w.client_fd)
			}
		}
		.suspend {
			conn.awaiting_fd = ac.last_watched // re-armed (multi-step); stay parked
		}
		.close {
			kq_close(mut reactor, kq, w.client_fd)
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
