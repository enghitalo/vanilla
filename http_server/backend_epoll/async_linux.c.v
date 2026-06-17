module backend_epoll

// Opt-in async runtime for the epoll worker.
//
// There is ONE worker (process_events_plain in worker_linux.c.v). When
// ServerConfig.async_handler is set it additionally owns an AsyncReactor and
// routes watched-fd readiness + client reads through the helpers in this file;
// when it is not set, a single per-worker `has_async` bool skips all of this, so
// the synchronous hot path (and all its optimizations: pipelining, the busy-poll
// hybrid, large-body streaming-drain, sendfile, EPOLLOUT backpressure) is shared
// by the async path for free and is byte-for-byte unchanged when async is off.
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
import http_server.http1_1.request_parser
import http_server.http1_1.response

#include <errno.h>
#include <sys/epoll.h>
#include <sys/socket.h>

// WatchEntry records one parked request: which client connection is waiting, the
// continuation to run when the watched fd is ready, and the consumer's opaque
// context handed back via AsyncCtx.udata. `active` is the slot's occupancy flag:
// the table is indexed by fd (a flat array, not a hashmap), so a cleared slot is
// just `active = false` rather than an erased key.
struct WatchEntry {
mut:
	active    bool
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
}

// AsyncReactor is the per-worker watch registry: a flat array indexed by the
// external fd (NOT a hashmap) — the same fd-indexed, doubling-grown layout the
// synchronous path already uses for `PlainState.conns`. Watch/resume/clear are
// then plain array writes with no hashing or per-request allocation (the event
// loop's hot lookup is `watches[fd].active`). One per worker thread, no lock.
struct AsyncReactor {
mut:
	watches []WatchEntry
}

// reactor_watch records (or rearms) the watch for ext_fd, growing the flat table
// by doubling if the fd is past the current bound — mirroring state_for's growth
// so high fd numbers stay O(1)-indexed with no hashing.
@[direct_array_access]
fn (mut r AsyncReactor) reactor_watch(ext_fd int, client_fd int, cont core.WakeFn, udata voidptr) {
	if ext_fd >= r.watches.len {
		mut new_len := if r.watches.len == 0 { conn_table_min } else { r.watches.len }
		for new_len <= ext_fd {
			new_len *= 2
		}
		mut grown := []WatchEntry{len: new_len}
		for i in 0 .. r.watches.len {
			grown[i] = r.watches[i]
		}
		r.watches = grown
	}
	r.watches[ext_fd] = WatchEntry{
		active:    true
		client_fd: client_fd
		cont:      cont
		udata:     udata
	}
}

// reactor_clear marks ext_fd's slot free. The fd itself stays in epoll (a
// pool-owned connection is re-armed by the next watch); only the parked-request
// record is dropped, so a stale readiness edge finds `active == false` and is
// ignored.
@[direct_array_access; inline]
fn (mut r AsyncReactor) reactor_clear(ext_fd int) {
	if ext_fd >= 0 && ext_fd < r.watches.len {
		r.watches[ext_fd].active = false
	}
}

// async_register is installed into AsyncCtx.register; it is what `ac.watch(...)`
// ultimately calls. It records the watch and arms the external fd in this
// worker's epoll (level-triggered: simplest correct default for arbitrary
// consumer fds). Runs on the worker thread, so no synchronization is needed.
fn async_register(mut ac core.AsyncCtx, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	if ext_fd < 0 {
		// A consumer handed us a failed fd (e.g. timerfd_create returned -1); never
		// index the flat table at a negative slot. Arm nothing.
		ac.last_watched = -1
		return
	}
	mut r := unsafe { &AsyncReactor(ac.reactor) }
	r.reactor_watch(ext_fd, ac.client_fd, cont, udata)
	events := if interest == .writable { u32(C.EPOLLOUT) } else { u32(C.EPOLLIN) }
	// Re-arm if the fd is already in this worker's epoll (a pool-owned connection
	// re-watched across queries), otherwise add it (a fresh request-owned fd).
	// Trying MOD first avoids an EEXIST perror on every pool-fd reuse and needs no
	// extra bookkeeping: a fresh fd's MOD fails with ENOENT and falls through to ADD.
	if epoll.mod_fd_in_epoll(ac.loop_fd, ext_fd, events) != 0 {
		if epoll.add_fd_to_epoll(ac.loop_fd, ext_fd, events) < 0 {
			// The fd could not be armed (bad fd, epoll limits): don't leave a slot
			// marked active that the loop would never actually fire — clear it so the
			// watch is genuinely absent rather than silently dead.
			r.reactor_clear(ext_fd)
			ac.last_watched = -1
			return
		}
	}
	ac.last_watched = ext_fd
}

// The async runtime is driven by the ONE plain worker (process_events_plain in
// worker_linux.c.v): when async_handler is set it owns an AsyncReactor and routes
// watched-fd readiness to async_on_ready and client reads to async_handle_readable
// (below). This file holds only those async helpers — the event loop, accept, the
// busy-poll hybrid and the timeout sweep are all shared with the synchronous path.

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

// async_serve drains the socket into the read buffer (edge-triggered), answers
// every complete request as it arrives (pipelining), and flushes the batch at
// the end. It carries the same large-body handling as the synchronous path: a
// body past sm_stream_body_above is STREAMED (head answered, body drained +
// discarded) instead of buffered, and a handler that hands a file off for
// sendfile(2) has it streamed by flush_batch. Stops reading when a request parks.
@[direct_array_access; manualfree]
fn async_serve(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) {
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}
	for {
		// Streaming-drain: a large body detected below is consumed off the socket
		// and DISCARDED (the head was already answered) — keeps a big upload at
		// O(buffer) memory instead of growing read_buf into a scanned GC block.
		if cs.body_drain > 0 {
			want := if cs.body_drain < i64(cs.read_buf.cap) {
				int(cs.body_drain)
			} else {
				cs.read_buf.cap
			}
			dn := C.recv(fd, cs.read_buf.data, usize(want), 0)
			if dn < 0 {
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
					break
				}
				close_conn(epoll_fd, fd, active_conns, mut st)
				return
			}
			if dn == 0 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return
			}
			cs.body_drain -= dn
			continue
		}
		if cs.read_buf.len == cs.read_buf.cap {
			target := request_parser.frame_expected_total(cs.read_buf)
			// A body too large to buffer is STREAMED: answer from the head, then drain.
			if target > sm_stream_body_above && target <= req_cap {
				match async_start_body_drain(h, mut reactor, epoll_fd, fd, limits, active_conns, mut
					st, mut cs, state, target) {
					1 { continue } // draining started; keep reading the body
					2 { return } // connection closed
					else {} // head not complete yet → fall through to grow
				}
			}
			if target > cs.read_buf.cap && target <= req_cap {
				unsafe { cs.read_buf.grow_cap(target - cs.read_buf.cap) }
			} else {
				unsafe { cs.read_buf.grow_cap(cs.read_buf.cap) }
			}
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
		if !async_drain(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state) {
			return
		}
		if cs.awaiting_fd >= 0 {
			break // a request parked on a watch — stop reading until it resumes
		}
		if cs.read_buf.len > req_cap {
			cs.write_buf << response.status_413_response
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return
		}
	}
	if cs.write_buf.len > cs.write_off || cs.file_remaining > 0 {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
}

// async_start_body_drain answers a large-body request from its HEAD alone, then
// puts the connection into streaming-drain mode for the body (the cs.body_drain
// branch above). The async counterpart of start_body_drain — such handlers must
// answer by Content-Length and complete synchronously (.done); a head handler
// that suspends mid-large-body is not supported in v1 and drops the connection.
// Returns 1 = draining started, 2 = connection closed, 0 = head not complete yet.
@[direct_array_access]
fn async_start_body_drain(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr, total int) int {
	head_len := request_parser.frame_head_len(cs.read_buf)
	if head_len <= 0 || head_len > cs.read_buf.len {
		return 0 // head not complete in the buffer yet — grow/recv more
	}
	content_length := total - head_len
	head := unsafe { cs.read_buf[0..head_len] }
	mut ac := core.AsyncCtx{
		client_fd: fd
		state:     state
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  async_register
	}
	if h(head, mut cs.write_buf, mut ac) != .done {
		// suspend/close on a streamed-body request is unsupported in v1 — answer
		// 400 and drop, rather than leave a half-drained connection parked.
		cs.write_buf << response.tiny_bad_request_response
		if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			close_conn(epoll_fd, fd, active_conns, mut st)
		}
		return 2
	}
	if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
		close_conn(epoll_fd, fd, active_conns, mut st)
		return 2
	}
	body_in_buf := cs.read_buf.len - head_len
	cs.body_drain = i64(content_length) - i64(body_in_buf)
	if cs.body_drain < 0 {
		cs.body_drain = 0
	}
	unsafe {
		cs.read_buf.len = 0 // head (and any buffered body bytes) consumed
	}
	return 1
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
		total := request_parser.frame_request_length_lim(cs.read_buf[pos..],
			limits.max_header_bytes, limits.max_body_bytes) or {
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
		// A file deferred by an earlier request in this batch must be emitted (as
		// bytes, in order) BEFORE this next response is appended — same ordering
		// rule as the synchronous drain_requests.
		if cs.file_remaining > 0 {
			append_file_region(mut cs.write_buf, cs.file_fd, cs.file_off, cs.file_remaining)
			cs.file_fd = -1
			cs.file_remaining = 0
		}
		req := unsafe { cs.read_buf[pos..pos + total] }
		mut ac := core.AsyncCtx{
			client_fd: fd
			state:     state
			loop_fd:   epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  async_register
		}
		step := h(req, mut cs.write_buf, mut ac)
		pos += total
		match step {
			.done {
				// Handler may have appended headers + handed its body off for
				// sendfile(2); it streams after write_buf drains (flush_batch).
				if qf := core.take_queued_file() {
					cs.file_fd = qf.file_fd
					cs.file_off = qf.off
					cs.file_remaining = qf.len
				}
			}
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
// `ev` is the raw epoll event mask for this edge; an error/hangup (EPOLLERR|
// EPOLLHUP) is surfaced to the continuation as the portable AsyncCtx.ready_err so
// it can release a dead fd instead of re-arming it into a busy-spin.
@[direct_array_access; manualfree]
fn async_on_ready(h core.AsyncHandler, mut reactor AsyncReactor, epoll_fd int, ext_fd int, entry WatchEntry, ev u32, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	reactor.reactor_clear(ext_fd) // consumed; the continuation re-arms if it needs more
	ready_err := ev & (u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0
	// Clientless background watch (armed by on_worker_start, e.g. a per-worker
	// refresh timerfd): there is no parked connection. Run the continuation with a
	// throwaway buffer and a -1 client_fd; ac.state is the worker state and it
	// re-arms via ac.watch. The slot was already cleared above, so the ONLY way the
	// watch stays alive is the continuation re-arming THIS SAME fd and suspending
	// (the periodic-refresh case). Any other outcome means the continuation stopped
	// watching ext_fd; we must then ensure ext_fd is neither active nor left in
	// this worker's epoll, otherwise a later readiness edge on it falls through to
	// the client read path and is mistaken for a connection (fabricating a phantom
	// conn and skewing active_conns). The fd OBJECT is the app's: it created it and
	// closes it — except on a clean .done/.close, where the runtime owns teardown.
	if entry.client_fd < 0 {
		mut scratch := []u8{}
		mut bac := core.AsyncCtx{
			client_fd: -1
			ready_fd:  ext_fd
			ready_err: ready_err
			udata:     entry.udata
			state:     state
			loop_fd:   epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  async_register
		}
		step := entry.cont(mut scratch, mut bac)
		if step == .suspend && bac.last_watched == ext_fd {
			return
		}
		reactor.reactor_clear(ext_fd) // re-arm-then-.done could have re-set active
		if step == .suspend {
			// Stepped to a DIFFERENT fd (now armed): detach ext_fd from epoll but do
			// NOT close it — the app still owns it and may reuse it later.
			epoll.detach_fd_from_epoll(epoll_fd, ext_fd)
		} else {
			epoll.remove_fd_from_epoll(epoll_fd, ext_fd) // done (.done/.close): DEL + close
		}
		return
	}
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
		ready_err: ready_err
		udata:     entry.udata
		state:     state
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  async_register
	}
	match entry.cont(mut cs.write_buf, mut ac) {
		.done {
			// Send this response and drain any requests that were pipelined behind it
			// (and read anything that arrived while parked) — one batched flush.
			async_serve(h, mut reactor, epoll_fd, client_fd, limits, active_conns, mut st, mut cs,
				state)
		}
		.suspend {
			// Stream-as-you-go: a continuation that appended bytes before re-arming
			// (e.g. one SSE event) has them sent NOW, not buffered until .done — that
			// is what makes incremental streaming work. We only flush when something
			// is pending (the DB-style "park, write later" case appends nothing here).
			// flush_batch returns false only if it already closed the conn (peer gone /
			// write error) — then we must NOT re-park it.
			if cs.write_buf.len > cs.write_off {
				if !flush_batch(epoll_fd, client_fd, limits, active_conns, mut st, mut cs) {
					return
				}
			}
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
			reactor.reactor_clear(cs.awaiting_fd)
			epoll.remove_fd_from_epoll(epoll_fd, cs.awaiting_fd) // DEL + close the ext fd
		}
	}
	close_conn(epoll_fd, fd, active_conns, mut st)
}
