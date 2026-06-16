module backend_epoll

// Opt-in async runtime for the epoll worker.
//
// This is an ISOLATED worker path: when ServerConfig.async_handler is set, the
// server spawns `process_events_async` instead of the synchronous
// `process_events_plain`, so the synchronous hot path is untouched.
//
// The model is a small single-threaded reactor. A handler that needs to wait on
// something (a DB socket, an upstream connection, a timerfd, the client becoming
// writable, ...) calls `ac.watch(ext_fd, events, continuation, udata)` and
// returns `.suspend`. The worker registers the external fd in its OWN epoll,
// PARKS the connection (its response is not produced yet), and goes on serving
// other connections. When `ext_fd` is ready the worker runs the continuation,
// which appends the response and returns `.done` (send + unpark) or re-arms a
// watch and returns `.suspend` (multi-step chains: connect → send → recv).
//
// The DB driver, reverse-proxy/upstream calls, timers, and SSE/WebSocket
// backpressure are all CONSUMERS of this one `watch` primitive — see the
// async-runtime umbrella issue. v1 scope: one in-flight watch per connection
// (no pipelining-while-suspended), request-owned watched fds (the continuation
// or close path owns ext_fd's lifetime). Pipelining-while-suspended, parked-conn
// timeouts, and pool-owned (non-closing) watched fds are follow-ups.
import http_server.core
import http_server.epoll
import http_server.socket
import http_server.http1_1.request_parser
import http_server.http1_1.response

#include <errno.h>
#include <sys/epoll.h>
#include <sys/socket.h>

// WatchEntry records one parked request: which client connection is waiting, the
// continuation to run when the watched fd is ready, and the consumer's opaque
// context handed back via AsyncCtx.udata.
struct WatchEntry {
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
}

// AsyncReactor is the per-worker watch registry: external fd -> parked request.
// One per worker thread (so it needs no lock).
struct AsyncReactor {
mut:
	watches map[int]WatchEntry
}

// async_register is installed into AsyncCtx.register; it is what `ac.watch(...)`
// ultimately calls. It records the watch and adds the external fd to this
// worker's epoll (level-triggered: simplest correct default for arbitrary
// consumer fds). Runs on the worker thread, so no synchronization is needed.
fn async_register(mut ac core.AsyncCtx, ext_fd int, events u32, cont core.WakeFn, udata voidptr) {
	mut r := unsafe { &AsyncReactor(ac.reactor) }
	r.watches[ext_fd] = WatchEntry{
		client_fd: ac.client_fd
		cont:      cont
		udata:     udata
	}
	epoll.add_fd_to_epoll(ac.epoll_fd, ext_fd, events)
	ac.last_watched = ext_fd
}

// process_events_async is the async worker loop. It owns its connection table
// (reusing ConnState + the flush/close helpers) and its watch registry. Client
// fds and watched external fds share this one epoll instance.
@[direct_array_access; manualfree]
fn process_events_async(worker_id int, epoll_fd int, async_handler core.AsyncHandler, make_state fn () voidptr, limits core.Limits, counter &core.Counter, active_conns &core.Counter) {
	maybe_pin_worker(worker_id)
	core.enable_sendfile()
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	mut reactor := AsyncReactor{
		watches: map[int]WatchEntry{}
	}
	mut events := [socket.max_connection_size]C.epoll_event{}
	mut st := new_plain_state()
	for {
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, -1)
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
			// Is this a watched external fd? Run its continuation.
			if entry := reactor.watches[fd] {
				async_on_ready(async_handler, mut reactor, epoll_fd, fd, entry, limits, counter,
					active_conns, mut st, state)
				continue
			}
			// Otherwise it is a client connection.
			if ev & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				async_close(mut reactor, epoll_fd, fd, active_conns, mut st)
				continue
			}
			if ev & u32(C.EPOLLOUT) != 0 {
				// A parked response batch finished draining: reuse the plain writer.
				if !handle_writable_plain(epoll_fd, fd, active_conns, mut st) {
					continue
				}
			}
			if ev & u32(C.EPOLLIN) != 0 {
				async_handle_readable(async_handler, mut reactor, epoll_fd, fd, limits, counter,
					active_conns, mut st, state)
			}
		}
	}
}

// async_handle_readable reads the request, calls the async handler ONCE, and
// reads the socket, answers every complete request, and parks only when a
// handler actually suspends.
@[direct_array_access; manualfree]
fn async_handle_readable(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	mut cs := state_for(mut st, fd)
	// Already parked on a watch: a readable edge here is either the client hanging
	// up or pipelining ahead. Peek to detect a close (tear the watch down); any
	// data stays in the socket buffer and is read once the in-flight watch resumes.
	if cs.awaiting_fd >= 0 {
		mut probe := [1]u8{}
		if C.recv(fd, &probe[0], 1, C.MSG_PEEK) == 0 {
			async_close(mut reactor, epoll_fd, fd, active_conns, mut st)
		}
		return
	}
	async_serve(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state)
}

// async_serve drains the socket into the read buffer (edge-triggered: to EAGAIN),
// then answers every complete request (pipelining), flushing the batch at the end.
@[direct_array_access; manualfree]
fn async_serve(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) {
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}
	for {
		if cs.read_buf.len == cs.read_buf.cap {
			unsafe { cs.read_buf.grow_cap(cs.read_buf.cap) }
		}
		spare := cs.read_buf.cap - cs.read_buf.len
		n := C.recv(fd, unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }, usize(spare), 0)
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break
			}
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		if n == 0 {
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		unsafe {
			cs.read_buf.len += n
		}
	}
	if cs.read_buf.len > req_cap {
		cs.write_buf << response.status_413_response
		if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			close_conn(epoll_fd, fd, active_conns, mut st)
		}
		return
	}
	if !async_drain(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state) {
		return // connection closed inside the drain
	}
	if cs.write_buf.len > cs.write_off || cs.file_remaining > 0 {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
}

// async_drain answers every complete request currently buffered, appending each
// response to write_buf, and STOPS at the first request that suspends (it parks;
// the rest stay buffered and are drained when the watch resumes). Mirrors the
// synchronous drain_requests but with the async step contract. Returns false if
// the connection was closed (the caller must not touch it).
@[direct_array_access; manualfree]
fn async_drain(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) bool {
	mut pos := 0
	for pos < cs.read_buf.len && cs.awaiting_fd < 0 {
		total := request_parser.frame_request_length_lim(cs.read_buf[pos..], limits.max_header_bytes,
			limits.max_body_bytes) or {
			match err.code() {
				413 { cs.write_buf << response.status_413_response }
				431 { cs.write_buf << response.status_431_response }
				else { cs.write_buf << response.tiny_bad_request_response }
			}
			async_compact(mut cs, pos)
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
		if total < 0 {
			break // incomplete — wait for more bytes
		}
		req := unsafe { cs.read_buf[pos..pos + total] }
		mut ac := core.AsyncCtx{
			client_fd: fd
			state:     state
			epoll_fd:  epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  async_register
		}
		step := h(req, mut cs.write_buf, mut ac)
		pos += total
		match step {
			.done {} // response appended; answer the next buffered request
			.suspend {
				cs.awaiting_fd = ac.last_watched // park; leftover stays buffered for resume
			}
			.close {
				async_compact(mut cs, pos)
				if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
					close_conn(epoll_fd, fd, active_conns, mut st)
				}
				return false
			}
		}
		// Peer pipelines without reading responses: bail before the batch is unbounded.
		if cs.write_buf.len - cs.write_off > sm_max_pending_write {
			async_compact(mut cs, pos)
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
	}
	async_compact(mut cs, pos)
	return true
}

// async_compact drops the first `pos` consumed bytes, keeping the leftover
// (partial / not-yet-answered) request at the buffer front.
@[direct_array_access; inline]
fn async_compact(mut cs ConnState, pos int) {
	if pos <= 0 {
		return
	}
	leftover := cs.read_buf.len - pos
	if leftover > 0 {
		unsafe { C.memmove(cs.read_buf.data, &u8(cs.read_buf.data) + pos, usize(leftover)) }
	}
	unsafe {
		cs.read_buf.len = leftover
	}
}

// async_on_ready runs a parked request's continuation when its watched fd fires.
@[direct_array_access; manualfree]
fn async_on_ready(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, ext_fd int, entry WatchEntry, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	reactor.watches.delete(ext_fd) // consumed; the continuation re-arms if it needs more
	client_fd := entry.client_fd
	if client_fd >= st.conns.len {
		return
	}
	mut cs := st.conns[client_fd]
	if unsafe { cs == nil } {
		return
	}
	cs.awaiting_fd = -1
	mut ac := core.AsyncCtx{
		client_fd: client_fd
		ready_fd:  ext_fd
		udata:     entry.udata
		state:     state
		epoll_fd:  epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  async_register
	}
	match entry.cont(mut cs.write_buf, mut ac) {
		.done {
			// Send this response and drain any requests that were pipelined behind it
			// (and read anything that arrived while parked) — one batched flush.
			async_serve(h, mut reactor, epoll_fd, client_fd, limits, active_conns, mut st, mut
				cs, state)
		}
		.suspend {
			cs.awaiting_fd = ac.last_watched // re-armed (multi-step); stay parked
		}
		.close {
			close_conn(epoll_fd, client_fd, active_conns, mut st)
		}
	}
}

// async_close tears down a connection, first removing any watch it is parked on
// (which closes that request-owned fd, e.g. a timerfd) so nothing leaks.
@[direct_array_access; manualfree]
fn async_close(mut reactor AsyncReactor, epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) {
	if fd < st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs != nil } && cs.awaiting_fd >= 0 {
			reactor.watches.delete(cs.awaiting_fd)
			epoll.remove_fd_from_epoll(epoll_fd, cs.awaiting_fd) // DEL + close the ext fd
		}
	}
	close_conn(epoll_fd, fd, active_conns, mut st)
}
