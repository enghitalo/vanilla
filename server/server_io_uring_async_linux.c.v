module server

// Request drain + watch/park/resume runtime for the io_uring worker (issue
// #83) — the io_uring twin of backend_epoll/async_linux.c.v. Each ring worker
// owns an IouEnv (watch registry + handler + per-worker state) and routes
// client reads through iou_drain_requests and watched-fd readiness through
// handle_io_uring_poll.
//
// The model is the same single-threaded reactor as epoll's: a handler that needs
// to wait on something (a DB socket, an upstream, a timerfd) calls
// `worker.watch(ext_fd, interest, continuation, udata)` and returns `.suspend`. The
// worker PARKS the connection and goes on serving others; readiness on ext_fd is
// delivered as a ONESHOT IORING_OP_POLL_ADD completion (op_poll) that resumes the
// continuation — all on the ring's own thread, so SINGLE_ISSUER is preserved by
// construction (every poll SQE is queued from a continuation running inside the
// CQE dispatch).
//
// Key differences from the epoll runtime, both simplifications:
//
//   * A PARKED connection has ZERO client-side ops in flight. No recv is armed
//     (so the pool slot cannot be freed under a stale CQE — the sync path's
//     slot-reuse-UAF hazard cannot arise here), and no send is armed: responses
//     produced before/at the park are HELD in response_buffer until resume,
//     because an in-flight send captures a raw data pointer that a resume
//     appending to (and thereby reallocating) the buffer would dangle. The
//     latency cost is bounded by the watch (one DB round-trip); the epoll-style
//     stream-as-you-go on .suspend (SSE over async) is deferred to a follow-up.
//
//   * Client hangup while parked is NOT detected eagerly (no op on the client fd
//     ⇒ no CQE). The in-flight query was already submitted; when it completes,
//     the resume renders and flushes, the send fails on the dead peer, and the
//     write-completion path releases the slot — the pooled DB reply is thereby
//     always drained IN ORDER, so none of epoll's disconnect tombstoning
//     (reactor_orphan_single / eager mark_dead) is needed for correctness. The
//     `dead` tombstone on queue slots is kept as a defensive guard (a released /
//     reused slot found at drain time is consumed against a scratch buffer).
//
// Parked-connection deadlines: read/write deadlines are cleared at park (no
// client op is armed, so neither timeout applies) and re-arm naturally at
// resume. A hung query on a vanished client therefore pins the slot until the
// query returns — the same known gap as the epoll runtime (async_linux.c.v:29);
// bound it DB-side with e.g. statement_timeout. A parked-deadline sweep is a
// follow-up shared with epoll.
import io_uring
import core
import http1.request_parser
import http1.response

// Initial size of the fd-indexed watch table (grows by doubling; same layout as
// the epoll reactor and the pool's fd-indexed structures).
const iou_watch_table_min = 1024

// IouParkSlot is one parked client on a pipelined (multi-client) watched fd: the
// same (conn, continuation, udata) triple a single IouWatchEntry holds, but queued
// so one readiness edge on a multiplexed pg connection can complete several
// requests in submission order. `client_fd` is the conn's fd CAPTURED at park time
// — the dead/ABA identity, never re-resolved. `dead` marks a slot whose conn was
// released/reused while parked: it stays in the queue (removing it would desync
// the queue from the DB connection's in-flight FIFO) and its result is consumed
// against a throwaway buffer in order, then discarded.
struct IouParkSlot {
mut:
	conn      &io_uring.Connection = unsafe { nil }
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
	dead      bool
}

// IouWatchEntry records one parked request on an external fd: which client
// connection is waiting, the continuation to run on readiness, and the consumer's
// opaque udata. `queue` is EMPTY for the common single-watch case; it is populated
// only when a SECOND distinct client parks on an already-active fd (a pipelined
// pg connection) — then the queue is the FIFO of parked clients and the head
// fields are unused. Mirrors backend_epoll.WatchEntry.
struct IouWatchEntry {
mut:
	active    bool
	conn      &io_uring.Connection = unsafe { nil }
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
	queue     []IouParkSlot
	// persistent: the fd is a long-lived, caller-owned resource (a pooled DB
	// connection), armed via watch_persistent — never closed by the runtime.
	// Sticky once set (re-stamped on every park of a pool fd).
	persistent bool
}

// IouEnv is one worker's async runtime: the watch registry, the async
// handler, this worker's make_state value, and the ring (for arming polls from
// continuations). One per worker thread, no lock. `cur_conn` is the transient
// bridge from the fixed RegisterFn signature (which only receives Worker, and
// Worker carries no connection pointer) to the connection whose handler or
// continuation is CURRENTLY running — every call site sets it immediately before
// invoking h()/cont(), and iou_register_watch reads it. Single-threaded and
// synchronous within the call, so this is safe.
@[heap]
struct IouEnv {
mut:
	h        core.Handler = unsafe { nil }
	state    voidptr
	worker   &io_uring.Worker = unsafe { nil }
	watches  []IouWatchEntry
	cur_conn &io_uring.Connection = unsafe { nil }
	// Polls that could not be queued because the SQ was momentarily full. The
	// watch entry stays active and the worker loop retries these right after its
	// submit (which frees SQ slots) — a park is never silently dropped (the
	// no-signal RegisterFn contract gives the handler no way to observe failure).
	// The requested mask is persisted so a writable watch is never degraded to a
	// readable retry (a healthy socket parked awaiting writability raises neither
	// POLLIN nor ERR/HUP — a readable re-arm would strand it).
	pending_polls []PendingIouPoll
	// Set around a tombstoned slot's continuation (drain_pipelined_iou dead
	// branch): its re-arm must ONLY re-queue the oneshot poll — the tombstone
	// queue slot stays exactly as it is (same continuation, same udata), and the
	// watch table must not be touched (a dedup/append there would either revive
	// the tombstone or duplicate it).
	rearming_dead bool
}

struct PendingIouPoll {
	fd   int
	mask u32
}

// iou_reactor_watch records (or re-arms) the watch for ext_fd, growing the flat
// fd-indexed table by doubling. Port of backend_epoll's reactor_watch with the
// client identity swapped from an fd (epoll re-resolves conns via st.conns[fd])
// to the stable &Connection slab pointer (the io_uring pool never reallocates
// w.conns, which is exactly what makes storing the pointer sound) plus the fd
// captured for dead/ABA identity.
@[direct_array_access]
fn (mut env IouEnv) iou_reactor_watch(ext_fd int, cont core.WakeFn, udata voidptr) {
	if ext_fd >= env.watches.len {
		mut new_len := if env.watches.len == 0 { iou_watch_table_min } else { env.watches.len }
		for new_len <= ext_fd {
			new_len *= 2
		}
		mut grown := []IouWatchEntry{len: new_len}
		for i in 0 .. env.watches.len {
			grown[i] = env.watches[i]
		}
		env.watches = grown
	}
	conn := env.cur_conn
	if !env.watches[ext_fd].active {
		// Fresh watch — the single-watch fast path. Reset fields in place and REUSE
		// the slot's (already-empty) queue rather than assigning an IouWatchEntry{}
		// literal, which would default-init a fresh empty queue array — one heap
		// allocation per park, a leak under -gc none.
		env.watches[ext_fd].active = true
		env.watches[ext_fd].conn = conn
		env.watches[ext_fd].client_fd = if unsafe { conn != nil } { conn.fd } else { -1 }
		env.watches[ext_fd].cont = cont
		env.watches[ext_fd].udata = udata
		env.watches[ext_fd].persistent = false
		unsafe {
			env.watches[ext_fd].queue.len = 0
		}
		return
	}
	// The fd already has a parked watch. A SECOND distinct client on the same fd
	// means it is multiplexing (a pipelined pg connection): promote to a queue and
	// fan readiness out in submission order. A re-arm by an ALREADY-parked client
	// (the front continuation asking for more bytes) updates in place — never a
	// duplicate append. Identity is the conn POINTER over LIVE slots only: a DEAD
	// slot is never matched, so a released-and-reacquired slot pointer parking
	// again can never be conflated with its predecessor's tombstone (the tombstone
	// still drains its own orphaned reply first; the new park queues behind it,
	// which is also FIFO-correct — its query was submitted later). Tombstone
	// re-arms never reach this function (see rearming_dead in iou_register_watch).
	if env.watches[ext_fd].queue.len == 0 {
		if env.watches[ext_fd].conn == conn {
			env.watches[ext_fd].cont = cont
			env.watches[ext_fd].udata = udata
			return
		}
		// Promote: move the existing head into the queue (len is 0 here). Push into
		// the slot's RETAINED buffer rather than assigning a literal — the buffer
		// grows once to the max pipeline depth and is reused thereafter.
		env.watches[ext_fd].queue << IouParkSlot{
			conn:      env.watches[ext_fd].conn
			client_fd: env.watches[ext_fd].client_fd
			cont:      env.watches[ext_fd].cont
			udata:     env.watches[ext_fd].udata
		}
	}
	for i in 0 .. env.watches[ext_fd].queue.len {
		if !env.watches[ext_fd].queue[i].dead && env.watches[ext_fd].queue[i].conn == conn {
			env.watches[ext_fd].queue[i].cont = cont
			env.watches[ext_fd].queue[i].udata = udata
			return
		}
	}
	env.watches[ext_fd].queue << IouParkSlot{
		conn:      conn
		client_fd: if unsafe { conn != nil } { conn.fd } else { -1 }
		cont:      cont
		udata:     udata
	}
}

// iou_detach_rejected_watch tears down a watch that a handler registered during a
// call whose OUTCOME rejected the park — a streamed-body head that suspended
// (unsupported: answered 400 and condemned), or .done/.close returned after
// w.watch. Without this, the entry stays active with an armed oneshot poll
// pointing at a connection that is about to be released: a reacquired slot with
// the same pointer AND same fd number would pass every resume guard and have a
// foreign continuation write into the new client's response stream.
//
// For a pool-owned fd the in-flight query's reply must still be consumed IN ORDER
// (protocol sync), so the park is TOMBSTONED — drain_pipelined_iou runs it against
// a scratch buffer and discards — never erased. A request-owned fd is cleared and
// closed (the app's continuation will never run to close it): epoll async_close
// parity. The armed oneshot poll for a cleared entry dies on the active==false
// guard.
fn (mut env IouEnv) iou_detach_rejected_watch(ext_fd int, conn &io_uring.Connection) {
	if ext_fd < 0 || ext_fd >= env.watches.len || !env.watches[ext_fd].active {
		return
	}
	if env.watches[ext_fd].queue.len > 0 {
		// Pipelined fd: tombstone THIS conn's slot (keeps the FIFO aligned).
		for i in 0 .. env.watches[ext_fd].queue.len {
			if !env.watches[ext_fd].queue[i].dead && env.watches[ext_fd].queue[i].conn == conn {
				env.watches[ext_fd].queue[i].dead = true
				return
			}
		}
		return
	}
	if env.watches[ext_fd].conn != conn {
		return
	}
	if env.watches[ext_fd].persistent {
		// Pool-owned single watch: convert to a one-slot dead tombstone (the epoll
		// reactor_orphan_single shape) so the orphaned reply is drained in order
		// and the pooled fd stays open for reuse.
		env.watches[ext_fd].queue << IouParkSlot{
			conn:      env.watches[ext_fd].conn
			client_fd: env.watches[ext_fd].client_fd
			cont:      env.watches[ext_fd].cont
			udata:     env.watches[ext_fd].udata
			dead:      true
		}
		return
	}
	env.iou_reactor_clear(ext_fd)
	C.close(ext_fd)
}

// iou_reactor_clear marks ext_fd's slot free. Only the parked-request record is
// dropped (a pool-owned fd is re-armed by the next watch); a stale poll CQE then
// finds `active == false` and is ignored.
@[direct_array_access; inline]
fn (mut env IouEnv) iou_reactor_clear(ext_fd int) {
	if ext_fd >= 0 && ext_fd < env.watches.len {
		env.watches[ext_fd].active = false
	}
}

// iou_register_watch is installed into Worker.register; it is what worker.watch()
// ultimately calls. It records the watch and queues a oneshot POLL_ADD on the
// external fd — the SQE is flushed by the worker loop's next submit_and_wait.
// Runs on the ring's own worker thread (continuations execute inside the CQE
// dispatch), so SINGLE_ISSUER holds and no synchronization is needed.
fn iou_register_watch(mut w core.EventLoop, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	if ext_fd < 0 {
		// A consumer handed us a failed fd (e.g. timerfd_create returned -1); never
		// index the flat table at a negative slot. Arm nothing.
		w.last_watched = -1
		return
	}
	mut env := unsafe { &IouEnv(w.reactor) }
	mask := (if interest == .writable { io_uring.pollout } else { io_uring.pollin }) | io_uring.pollerr | io_uring.pollhup
	if env.rearming_dead {
		// Tombstone re-arm (drain_pipelined_iou dead branch): the queue slot stays
		// exactly as it is — only the consumed oneshot poll needs re-queueing. The
		// watch table is NOT touched: a dedup/append here would revive or duplicate
		// the tombstone.
		env.iou_queue_poll(ext_fd, mask)
		w.last_watched = ext_fd
		return
	}
	env.iou_reactor_watch(ext_fd, cont, udata)
	if w.persistent {
		// Pool-owned fd (watch_persistent): never closed by the runtime. Sticky —
		// re-stamped every park (a fresh single watch resets the entry).
		env.watches[ext_fd].persistent = true
	}
	env.iou_queue_poll(ext_fd, mask)
	w.last_watched = ext_fd
}

// iou_queue_poll queues the oneshot poll SQE, falling back to the pending list on
// a momentarily-full SQ. The handler has ALREADY committed by the time this runs
// (query submitted) and cannot observe a failure, so the park must not be
// dropped: the worker loop re-queues pending polls right after its next submit
// frees SQ slots. POLL_ADD reports current readiness at submit, so a late arm
// cannot lose the wakeup.
fn (mut env IouEnv) iou_queue_poll(ext_fd int, mask u32) {
	if io_uring.prepare_poll(&env.worker.ring, ext_fd, mask) {
		return
	}
	for p in env.pending_polls {
		if p.fd == ext_fd {
			return
		}
	}
	env.pending_polls << PendingIouPoll{
		fd:   ext_fd
		mask: mask
	}
}

// iou_retry_pending_polls re-queues polls that hit a full SQ (with their original
// interest mask), keeping the ones that still don't fit. Called by the worker
// loop right after its submit (which frees SQ slots).
@[direct_array_access]
fn iou_retry_pending_polls(mut env IouEnv) {
	mut kept := 0
	for i in 0 .. env.pending_polls.len {
		p := env.pending_polls[i]
		if p.fd < env.watches.len && env.watches[p.fd].active {
			if !io_uring.prepare_poll(&env.worker.ring, p.fd, p.mask) {
				env.pending_polls[kept] = p
				kept++
			}
		}
	}
	unsafe {
		env.pending_polls.len = kept
	}
}

// iou_event_loop builds the per-invocation EventLoop handle for a handler /
// continuation call. loop_fd is -1 — io_uring has no event-loop fd; the ring
// is reached via env.worker inside register.
@[inline]
fn iou_event_loop(mut env IouEnv, client_fd int) core.EventLoop {
	return core.EventLoop{
		client_fd: client_fd
		loop_fd:   -1
		reactor:   unsafe { voidptr(env) }
		register:  iou_register_watch
	}
}

// iou_drain_requests answers every complete request currently buffered, appending
// each response to response_buffer, and STOPS at the first request that suspends
// (the connection parks; the rest stay buffered and are drained when the watch
// resumes). The async twin of drain_iou_requests with the epoll async_drain step
// contract. CALLER CONTRACT: env.cur_conn must be the connection being drained
// (register reads it to identify the parker).
//
// Responses produced before a park are HELD (not flushed) — see the module
// comment: a parked connection must have no in-flight send, because a later
// resume appends to response_buffer and an append can reallocate it under a
// send's captured pointer. The caller flushes iff the burst ends unparked.
@[direct_array_access; manualfree]
fn iou_drain_requests(mut env IouEnv, mut conn io_uring.Connection, limits Limits) {
	mut pos := 0
	// A borrowed static-asset buffer a handler queued via queue_buf, deferred so it
	// can either be sent DIRECTLY (sole response of an unparked burst) or copied
	// into response_buffer IN ORDER before whatever follows.
	mut pend := voidptr(unsafe { nil })
	mut pend_len := i64(0)
	// ONE Worker per burst, not per request: the loop-invariant fields are set once;
	// the per-request fields are reset before each handler call below.
	mut event_loop := iou_event_loop(mut env, conn.fd)
	for pos < conn.read_buf.len && conn.awaiting_fd < 0 && !conn.close_after_send {
		if pend != unsafe { nil } {
			unsafe { conn.response_buffer.push_many(pend, int(pend_len)) }
			pend = unsafe { nil }
		}
		total := request_parser.frame_request_length_lim_idx(buf_view(conn.read_buf, pos,
			conn.read_buf.len - pos), limits.max_header_bytes, limits.max_body_bytes)
		if total == -1 {
			break // incomplete — wait for more bytes
		}
		if total < -1 {
			match -total {
				413 { conn.response_buffer << response.status_413_response }
				431 { conn.response_buffer << response.status_431_response }
				else { conn.response_buffer << response.tiny_bad_request_response }
			}

			conn.close_after_send = true
			core.set_queue_buf_allowed(false)
			return
		}
		req := buf_view(conn.read_buf, pos, total)
		// Borrowing is allowed only when the write buffer is empty, so a borrowed
		// send can be the WHOLE response (see post-loop; a park downgrades it to a
		// copy so ordering survives the deferred flush).
		core.set_queue_buf_allowed(conn.response_buffer.len == 0)
		// Only last_watched can be dirtied between iterations (iou_register_watch
		// is the sole runtime writer during an initial call).
		event_loop.last_watched = -1
		step := env.h(req, mut conn.response_buffer, conn.fd, env.state, mut event_loop)
		if qb := core.take_queued_buf() {
			pend = qb.ptr
			pend_len = qb.len
		}
		pos += total
		match step {
			.done {}
			.suspend {
				// Park: no client op will be armed until the watch resumes. Clear the
				// read deadline — nothing is mid-read, and the sweep must not shut a
				// parked connection down as a slow reader.
				conn.awaiting_fd = event_loop.last_watched
				conn.read_deadline = 0
			}
			.close {
				conn.close_after_send = true
			}
		}

		if step != .suspend && event_loop.last_watched >= 0 {
			// The handler registered a watch but did NOT park (.done/.close after
			// w.watch — a contract violation): tear it down so no armed poll can
			// later resume against this (soon-recycled) connection.
			env.iou_detach_rejected_watch(event_loop.last_watched, env.cur_conn)
		}
		// Peer pipelines requests but never reads responses: bail before the pending
		// batch grows without bound.
		if conn.response_buffer.len - conn.bytes_sent > iou_max_pending_write {
			conn.close_after_send = true
		}
	}
	core.set_queue_buf_allowed(false)
	if pend != unsafe { nil } {
		// A sole borrowed response of an UNPARKED, still-open burst is sent DIRECTLY
		// from the borrowed buffer. If the burst parked (flush deferred to resume) or
		// anything else is pending, copy it in order instead — the write-completion
		// path handles send_buf and response_buffer as alternatives, never both.
		if conn.response_buffer.len == 0 && conn.awaiting_fd < 0 && !conn.close_after_send {
			conn.send_buf = pend
			conn.send_total = int(pend_len)
		} else {
			unsafe { conn.response_buffer.push_many(pend, int(pend_len)) }
		}
	}
	// Compact the consumed prefix, keeping any leftover (partial or parked-behind)
	// request at the buffer front for the resume to drain.
	if pos > 0 {
		leftover := conn.read_buf.len - pos
		if leftover > 0 {
			unsafe {
				C.memmove(conn.read_buf.data, &u8(conn.read_buf.data) + pos, usize(leftover))
			}
		}
		unsafe {
			conn.read_buf.len = leftover
		}
	}
}

// iou_start_body_drain is the async twin of start_iou_body_drain: a
// large-body request is answered from its HEAD alone (the handler must complete
// synchronously — a head handler that suspends mid-large-body is unsupported, as
// on epoll, and drops the connection with a 400), then the body is drained and
// discarded by the body_drain machinery. Returns the same tri-state contract as
// the sync twin via `true` = handled / `false` = head incomplete.
@[direct_array_access]
fn iou_start_body_drain(mut env IouEnv, mut conn io_uring.Connection, total int, limits Limits) bool {
	head_len := request_parser.frame_head_len(conn.read_buf)
	if head_len <= 0 || head_len > conn.read_buf.len {
		return false // head not complete in the buffer yet — keep buffering
	}
	// max_body_bytes must hold on the STREAMED path too (mirrors the epoll
	// backend's start_body_drain): the framed path 413s an oversized declared
	// body, and a body large enough to stream must not bypass that limit just
	// because it skips buffering. Close: the unread body makes the stream
	// unrecoverable.
	if limits.max_body_bytes > 0 && total - head_len > limits.max_body_bytes {
		conn.response_buffer << response.status_413_response
		conn.close_after_send = true
		unsafe {
			conn.read_buf.len = 0
		}
		return true
	}
	head := buf_view(conn.read_buf, 0, head_len)
	core.set_queue_buf_allowed(false)
	mut event_loop := iou_event_loop(mut env, conn.fd)
	if env.h(head, mut conn.response_buffer, conn.fd, env.state, mut event_loop) != .done {
		// suspend/close on a streamed-body head is unsupported (as on epoll):
		// answer 400 and condemn. The handler may ALREADY have registered a watch
		// (armed poll + submitted query) before suspending — tear it down, or the
		// armed poll would later resume against this recycled connection (and a
		// pooled fd's orphaned reply must still be drained in order: tombstoned).
		if event_loop.last_watched >= 0 {
			env.iou_detach_rejected_watch(event_loop.last_watched, env.cur_conn)
		}
		conn.response_buffer << response.tiny_bad_request_response
		conn.close_after_send = true
		unsafe {
			conn.read_buf.len = 0
		}
		return true
	}
	body_in_buf := conn.read_buf.len - head_len
	conn.body_drain = i64(total - head_len) - i64(body_in_buf)
	if conn.body_drain < 0 {
		conn.body_drain = 0
	}
	unsafe {
		conn.read_buf.len = 0 // head + buffered body consumed; reuse buffer to drain
	}
	return true
}

// iou_finish_resume completes a connection's `.done` resume: drain any requests
// that were pipelined behind the parked one (they may re-park), then flush the
// held batch — or release / re-arm recv as the state demands. The io_uring
// analogue of epoll's `.done → async_serve` re-drain, split from the poll handler
// so the single-watch and pipelined paths share it.
fn iou_finish_resume(mut env IouEnv, mut conn io_uring.Connection, limits Limits, active_conns &core.Counter) {
	worker := env.worker
	if conn.read_buf.len > 0 && !conn.close_after_send {
		env.cur_conn = unsafe { &conn }
		iou_drain_requests(mut env, mut conn, limits)
	}
	if conn.awaiting_fd >= 0 {
		return
	}
	if conn.send_buf != unsafe { nil } || conn.response_buffer.len > conn.bytes_sent {
		iou_flush_response(worker, mut conn, limits)
		return
	}
	if conn.close_after_send {
		// .close resume (or an error) with nothing pending to send — drop directly;
		// a parked connection has no in-flight op, so releasing here is safe.
		iou_release(worker, mut conn, active_conns, limits.max_connections > 0)
		return
	}
	iou_arm_recv(worker, mut conn, limits)
}

// handle_io_uring_poll runs a parked request's continuation when its watched fd
// fires (the op_poll CQE). The io_uring twin of epoll's async_on_ready. For
// POLL_ADD the CQE res carries the returned event mask (or a negative errno);
// POLLERR/POLLHUP (or an errno) surface as the portable Worker.ready_err.
@[direct_array_access; manualfree]
fn handle_io_uring_poll(cqe &C.io_uring_cqe, mut env IouEnv, limits Limits, active_conns &core.Counter) {
	ext_fd := io_uring.decode_ext_fd(C.io_uring_cqe_get_data64(cqe))
	if ext_fd < 0 || ext_fd >= env.watches.len || !env.watches[ext_fd].active {
		return
	}
	res := cqe.res
	ready_err := res < 0 || (u32(res) & (io_uring.pollerr | io_uring.pollhup)) != 0
	// A pipelined fd (multiple parked clients on one multiplexed pg connection):
	// fan this readiness edge out to the queued continuations in submission order.
	if env.watches[ext_fd].queue.len > 0 {
		drain_pipelined_iou(mut env, ext_fd, ready_err, limits, active_conns)
		return
	}
	cont := env.watches[ext_fd].cont
	udata := env.watches[ext_fd].udata
	mut conn := env.watches[ext_fd].conn
	parked_fd := env.watches[ext_fd].client_fd
	env.iou_reactor_clear(ext_fd) // consumed; the continuation re-arms if it needs more
	if unsafe { conn == nil } || unsafe { conn.owner == nil } || conn.fd != parked_fd {
		return
	}
	conn.awaiting_fd = -1
	env.cur_conn = conn
	mut event_loop := iou_event_loop(mut env, conn.fd)
	step := cont(mut conn.response_buffer, ext_fd, ready_err, udata, env.state, mut event_loop)
	if step != .suspend && event_loop.last_watched >= 0 {
		// Continuation re-watched but did not park (.done/.close after w.watch):
		// tear the stray watch down before the connection moves on / is released.
		env.iou_detach_rejected_watch(event_loop.last_watched, conn)
	}
	match step {
		.done {
			iou_finish_resume(mut env, mut *conn, limits, active_conns)
		}
		.suspend {
			// Multi-step chain: register already queued a fresh oneshot poll. Stay
			// parked; bytes (if any) stay HELD — no send while parked (see module
			// comment; epoll's stream-as-you-go on .suspend is a follow-up here).
			conn.awaiting_fd = event_loop.last_watched
		}
		.close {
			// A parked connection has no in-flight op, so releasing here is safe.
			iou_release(env.worker, mut *conn, active_conns, limits.max_connections > 0)
		}
	}
}

// drain_pipelined_iou fans one readiness edge on a multiplexed pg connection out
// to the clients queued on it, in submission order — the io_uring twin of epoll's
// drain_pipelined. The queue head aligns with the connection's front in-flight
// query, so heads are run until one cannot complete yet (.suspend): by FIFO, if
// the front query is not ready no later one is either. Each .done is finished
// (leftover drained + batch flushed) before the next head runs.
@[direct_array_access; manualfree]
fn drain_pipelined_iou(mut env IouEnv, ext_fd int, ready_err bool, limits Limits, active_conns &core.Counter) {
	for env.watches[ext_fd].queue.len > 0 {
		slot := env.watches[ext_fd].queue[0]
		mut conn := slot.conn
		// A tombstoned or released/reused slot: run its continuation against a
		// throwaway buffer purely to CONSUME its in-flight query result in order
		// (keeping the queue aligned with the DB connection's FIFO), then discard.
		// Never dereference conn state for a dead slot — identity is the captured fd.
		if slot.dead || unsafe { conn == nil } || unsafe { conn.owner == nil }
			|| conn.fd != slot.client_fd {
			mut scratch := []u8{}
			mut dead_loop := iou_event_loop(mut env, slot.client_fd)
			// rearming_dead: a re-arm from this tombstone's continuation must ONLY
			// re-queue the oneshot poll — the queue slot stays as-is and the watch
			// table is untouched (see iou_register_watch).
			env.rearming_dead = true
			dead_step := slot.cont(mut scratch, ext_fd, ready_err, slot.udata, env.state, mut
				dead_loop)
			env.rearming_dead = false
			if dead_step == .suspend {
				break // result not ready yet — the tombstone stays at the head
			}
			env.watches[ext_fd].queue.delete(0)
			env.iou_reactor_clear_if_drained(ext_fd)
			continue
		}
		conn.awaiting_fd = -1
		env.cur_conn = conn
		mut event_loop := iou_event_loop(mut env, conn.fd)
		step := slot.cont(mut conn.response_buffer, ext_fd, ready_err, slot.udata, env.state, mut
			event_loop)
		if step != .suspend && event_loop.last_watched >= 0 && event_loop.last_watched != ext_fd {
			// Continuation watched a DIFFERENT fd but did not park: stray watch —
			// tear it down. (last_watched == ext_fd can't happen on a non-suspend:
			// a re-watch of ext_fd updates this same queue slot, which the .done/
			// .close arms below then pop.)
			env.iou_detach_rejected_watch(event_loop.last_watched, conn)
		}
		match step {
			.done {
				// Pop BEFORE finishing: the finish re-drain may read a request
				// pipelined behind this one and re-park the client on ext_fd
				// (appended at the tail). And if this pop DRAINED the queue, clear
				// the slot BEFORE finishing: a re-park inside iou_finish_resume must
				// become a FRESH, live single watch — a trailing "queue empty ⇒
				// active=false" epilogue would deactivate that re-park's watch and
				// strand its request forever (its poll CQE would find active=false
				// and be dropped as stale).
				env.watches[ext_fd].queue.delete(0)
				env.iou_reactor_clear_if_drained(ext_fd)
				iou_finish_resume(mut env, mut *conn, limits, active_conns)
			}
			.suspend {
				// Front query not ready yet. The continuation re-armed ext_fd in place
				// (iou_reactor_watch found it already queued — no duplicate) and
				// register queued a fresh oneshot poll. Keep it at the head and stop:
				// nothing behind it is ready.
				conn.awaiting_fd = ext_fd
				break
			}
			.close {
				env.watches[ext_fd].queue.delete(0)
				env.iou_reactor_clear_if_drained(ext_fd)
				iou_release(env.worker, mut *conn, active_conns, limits.max_connections > 0)
			}
		}
	}
	// No trailing epilogue on purpose: deactivation happens INLINE at each pop that
	// drains the queue (iou_reactor_clear_if_drained above), always BEFORE a
	// continuation/finish that could re-park on this same fd. The drained queue's
	// buffer is retained either way (len 0 from the delete(0)s; the next pipeline
	// cycle on this pool-owned fd refills it without reallocating).
}

// iou_reactor_clear_if_drained deactivates ext_fd's watch when its pipelined
// queue has just been fully consumed. MUST run before any continuation or finish
// that could re-park on ext_fd (see the .done arm of drain_pipelined_iou).
@[direct_array_access; inline]
fn (mut env IouEnv) iou_reactor_clear_if_drained(ext_fd int) {
	if env.watches[ext_fd].queue.len == 0 {
		env.watches[ext_fd].active = false
	}
}
