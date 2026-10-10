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
//     (reactor_orphan_single / eager mark_dead) is needed for that. The `dead`
//     tombstone on queue slots IS load-bearing for the lost-resume close: a
//     pipelined head released because it suspended without re-arming stays
//     queued as dead, so its in-flight reply is still consumed in order
//     against a scratch buffer — and a new client that reuses the released
//     slot and fd number is never resumed with the stale continuation.
//
// Parked-connection deadlines: read/write deadlines are cleared at park (no
// client op is armed, so neither timeout applies — nor the idle one: a parked
// request is never idle-reaped) and re-arm naturally at resume (a read deadline
// for a buffered partial, else the idle deadline, via iou_arm_recv). Park
// deadlines (Limits.park_timeout_ms, watch_fd_deadline, vanilla#200) are
// enforced by the epoll plain worker only: here a deadline watch is a plain
// watch and event_loop.timed_out() stays false, so a hung query pins its slot
// until the query returns; bound it DB-side with e.g. statement_timeout. A
// deadline here would also have to retire the oneshot poll still armed on the
// fd (IORING_OP_POLL_REMOVE), not only the watch entry.
import io_uring
import core
import http1_1.request_parser
import http1_1.response
import sync.stdatomic

#include <fcntl.h>
#include <sys/syscall.h>

fn C.fcntl(fd int, cmd int, arg int) int
fn C.getpid() int

// iou_kcmp_file is KCMP_FILE (see backend_epoll's kcmp_file).
const iou_kcmp_file = 0

// Initial size of the fd-indexed watch table (grows by doubling; same layout as
// the epoll reactor and the pool's fd-indexed structures).
const iou_watch_table_min = 1024

// iou_park parks conn on the watched ext_fd (awaiting_fd), and iou_unpark
// takes it off: the io_uring twin of the epoll park_conn / unpark_conn. A
// parked connection has no send posted, which is what this worker's
// in-flight counter otherwise counts, so the park itself holds one count
// until the connection resumes (or is released: iou_release). Then
// Server.shutdown() waits for parked requests too. Only the transition
// counts, so a continuation that re-parks is not counted twice.
@[inline]
fn iou_park(worker &io_uring.Worker, mut conn io_uring.Connection, ext_fd int) {
	if conn.awaiting_fd < 0 && unsafe { worker.inflight != nil } {
		stdatomic.add_i64(&worker.inflight.n, 1)
	}
	conn.awaiting_fd = ext_fd
}

@[inline]
fn iou_unpark(worker &io_uring.Worker, mut conn io_uring.Connection) {
	if conn.awaiting_fd >= 0 {
		conn.awaiting_fd = -1
		if unsafe { worker.inflight != nil } {
			stdatomic.add_i64(&worker.inflight.n, -1)
		}
	}
}

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
	// Set around a tombstoned slot's continuation (iou_run_tombstone): a
	// re-arm of the tombstone's own fd re-queues the oneshot poll and
	// updates only the head slot's continuation and udata, never dedups or
	// appends (that would revive the tombstone or duplicate it). A watch on any
	// other fd is a step away: see dead_fd.
	rearming_dead bool
	// dead_refused, dead_held and dead_step_fd: the epoll Reactor twins
	// (#257), in the padding before dead_fd likewise. Whether one of the
	// running tombstone's watches was refused, whether iou_run_tombstone holds
	// its client's number, and the persistent fd it last stepped to (its dead
	// slot is the tail there).
	dead_refused bool
	dead_held    bool
	dead_step_fd i32 = -1
	// dead_fd: the fd whose tombstone is running while rearming_dead is set; a
	// watch on any other fd is the continuation stepping away (#231, the epoll
	// Reactor.dead_fd twin).
	dead_fd int = -1
	// The reused `response` of a tombstone's continuation, whose output is
	// discarded (the epoll Reactor.scratch twin: a fresh array per tombstone
	// grew per disconnect, a leak under -gc none).
	scratch []u8
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
		env.iou_grow_watches(ext_fd)
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

// iou_grow_watches doubles the table until ext_fd fits (out of line: it runs a
// handful of times per worker lifetime).
@[direct_array_access]
fn (mut env IouEnv) iou_grow_watches(ext_fd int) {
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

// iou_reactor_tombstone records a DEAD slot for client_fd at the tail of
// ext_fd's queue: the watch a tombstone's continuation armed on a persistent fd
// other than the one it is draining (#231; the epoll reactor_tombstone twin).
// Never a live watch and never a dedup: the client is gone. A live single
// watch already on ext_fd is promoted to the queue head first.
@[direct_array_access]
fn (mut env IouEnv) iou_reactor_tombstone(ext_fd int, client_fd int, cont core.WakeFn, udata voidptr) {
	if ext_fd >= env.watches.len {
		env.iou_grow_watches(ext_fd)
	}
	if !env.watches[ext_fd].active {
		env.watches[ext_fd].active = true
		env.watches[ext_fd].conn = unsafe { nil }
		env.watches[ext_fd].client_fd = client_fd
		env.watches[ext_fd].cont = cont
		env.watches[ext_fd].udata = udata
		unsafe {
			env.watches[ext_fd].queue.len = 0
		}
	} else if env.watches[ext_fd].queue.len == 0 {
		env.watches[ext_fd].queue << IouParkSlot{
			conn:      env.watches[ext_fd].conn
			client_fd: env.watches[ext_fd].client_fd
			cont:      env.watches[ext_fd].cont
			udata:     env.watches[ext_fd].udata
		}
	}
	env.watches[ext_fd].persistent = true
	env.watches[ext_fd].queue << IouParkSlot{
		client_fd: client_fd
		cont:      cont
		udata:     udata
		dead:      true
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
	mut env := unsafe { &IouEnv(w.reactor) }
	// A clientless watch armed during a tombstone run (watch_fd_background)
	// takes the live path, which refuses it below.
	if env.rearming_dead && w.client_fd >= 0 {
		// A tombstone's continuation is running (iou_run_tombstone): its
		// watches follow the dead-mode rules, out of line.
		iou_register_dead_watch(mut w, mut env, ext_fd, interest, cont, udata)
		return
	}
	if ext_fd < 0 || w.client_fd < 0 {
		// A consumer handed us a failed fd (e.g. timerfd_create returned -1); never
		// index the flat table at a negative slot. Arm nothing. Nor for a
		// clientless watch (watch_fd_background): this runtime resumes
		// connections only, and would pin it to whichever one is running.
		w.last_watched = -1
		return
	}
	mask := (if interest == .writable { io_uring.pollout } else { io_uring.pollin }) | io_uring.pollerr | io_uring.pollhup
	env.iou_reactor_watch(ext_fd, cont, udata)
	if w.persistent {
		// Pool-owned fd (watch_persistent): never closed by the runtime. Sticky —
		// re-stamped every park (a fresh single watch resets the entry).
		env.watches[ext_fd].persistent = true
	}
	env.iou_queue_poll(ext_fd, mask)
	w.last_watched = ext_fd
}

// iou_register_dead_watch is iou_register_watch while a tombstone's
// continuation runs (rearming_dead, set by iou_run_tombstone): epoll's
// register_dead_watch twin, out of line likewise.
@[noinline]
fn iou_register_dead_watch(mut w core.EventLoop, mut env IouEnv, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	if ext_fd < 0 {
		// A failed fd (see iou_register_watch): a step away, refused (#257).
		w.last_watched = -1
		env.dead_refused = true
		return
	}
	mask := (if interest == .writable { io_uring.pollout } else { io_uring.pollin }) | io_uring.pollerr | io_uring.pollhup
	if ext_fd == env.dead_fd {
		// Tombstone re-arm (iou_run_tombstone): the running tombstone, the
		// head of ext_fd's queue, takes the new continuation and payload (a
		// multi-step chain) and stays dead; the consumed oneshot poll is
		// re-queued. Nothing else in the table changes: a dedup/append here
		// would revive or duplicate the tombstone.
		if env.watches[ext_fd].queue.len > 0 {
			env.watches[ext_fd].queue[0].cont = cont
			env.watches[ext_fd].queue[0].udata = udata
		}
		env.iou_queue_poll(ext_fd, mask)
		w.last_watched = ext_fd
		return
	}
	if ext_fd == w.client_fd && (!w.persistent || env.dead_held
		|| env.iou_is_live_conn_fd(ext_fd)) {
		// A watch on the tombstone's client's own number (#257), refused as in
		// epoll's register_dead_watch: request-owned, it can only be the
		// client's socket; persistent, while iou_run_tombstone holds the
		// number or it is a connection of this worker. Otherwise a pooled fd
		// of this worker took the number before the run: a pooled step.
		w.last_watched = -1
		env.dead_refused = true
		return
	}
	// The tombstone's continuation steps to ANOTHER fd (#231): a persistent
	// one gets a tombstone of its own (its continuation runs in dead mode
	// when it is ready); a request-owned one is left unrecorded and is
	// closed by iou_run_tombstone once the continuation returns.
	w.last_watched = ext_fd
	if w.persistent {
		if ext_fd == int(env.dead_step_fd) {
			// A repeat on the fd this run already stepped to (#257): its dead
			// slot, the tail there, takes the new continuation and payload; a
			// second slot would take the next reply on ext_fd. The poll is
			// queued again, for the interest now asked for.
			last := env.watches[ext_fd].queue.len - 1
			env.watches[ext_fd].queue[last].cont = cont
			env.watches[ext_fd].queue[last].udata = udata
		} else {
			env.iou_reactor_tombstone(ext_fd, w.client_fd, cont, udata)
			env.dead_step_fd = i32(ext_fd)
		}
		env.iou_queue_poll(ext_fd, mask)
	}
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
				if event_loop.last_watched < 0 {
					// Suspended without a live watch (watch_fd refused its fd, or was
					// never called): nothing would ever resume this request. Flush
					// what was appended, then close (the epoll rule), instead of
					// answering the next pipelined request in its place (the loop
					// condition stops the drain).
					conn.close_after_send = true
				} else {
					// Park: no client op will be armed until the watch resumes. Clear
					// the read deadline — nothing is mid-read, and the sweep must not
					// shut a parked connection down as a slow reader (a shutdown with
					// no op in flight would produce no CQE either). `idle` is already
					// false: this request's first byte cleared it.
					iou_park(env.worker, mut conn, event_loop.last_watched)
					conn.read_deadline = 0
				}
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
// so the single-watch and pipelined paths share it. With close_after_send set
// (a resume that suspended without a live watch) it only flushes, then releases.
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
	// Back to reading: a read deadline for a buffered partial, else the idle
	// deadline. A recv that cannot be queued leaves no op in flight — drop the
	// connection (safe: nothing is in flight) instead of stranding it.
	if !iou_arm_recv(worker, mut conn, limits) {
		iou_release(worker, mut conn, active_conns, limits.max_connections > 0)
	}
}

// handle_io_uring_poll runs a parked request's continuation when its watched fd
// fires (the op_poll CQE). The io_uring twin of epoll's async_on_ready. For
// POLL_ADD the CQE res carries the returned event mask (or a negative errno);
// POLLERR/POLLHUP (or an errno) surface as the portable Worker.ready_err.
@[direct_array_access; manualfree]
fn handle_io_uring_poll(cqe &io_uring.Cqe, mut env IouEnv, limits Limits, active_conns &core.Counter) {
	ext_fd := io_uring.decode_ext_fd(cqe.user_data)
	if ext_fd < 0 || ext_fd >= env.watches.len || !env.watches[ext_fd].active {
		return
	}
	// Hold an in-flight count across the resume, as the epoll on_watch_ready
	// does: the resumed connection's park count is dropped before its
	// continuation runs, and a .done response is counted only once its send
	// is posted, so without this a shutdown() could see zero in between.
	inflight := env.worker.inflight
	if unsafe { inflight != nil } {
		stdatomic.add_i64(&inflight.n, 1)
	}
	defer {
		if unsafe { inflight != nil } {
			stdatomic.add_i64(&inflight.n, -1)
		}
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
	iou_unpark(env.worker, mut *conn)
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
			if event_loop.last_watched < 0 {
				// Suspended without re-arming a watch (watch_fd got a failed fd, or
				// was never called): nothing would ever resume this connection — no
				// op in flight, no poll, and a parked connection holds no deadline.
				// Flush what was appended, then release (the epoll rule).
				conn.close_after_send = true
				iou_finish_resume(mut env, mut *conn, limits, active_conns)
			} else {
				// Multi-step chain: register already queued a fresh oneshot poll.
				// Stay parked; bytes (if any) stay HELD — no send while parked (see
				// module comment; epoll's stream-as-you-go on .suspend is a
				// follow-up here).
				iou_park(env.worker, mut *conn, event_loop.last_watched)
			}
		}
		.close {
			// A parked connection has no in-flight op, so releasing here is safe.
			iou_release(env.worker, mut *conn, active_conns, limits.max_connections > 0)
		}
	}
}

// iou_hold_free_number is backend_epoll's hold_free_number (#257): it holds fd
// number n, a dead client's, for its tombstone's run, so that no fd the run
// creates (nor another thread) gets it. The duplicate is of this worker's
// listener, which the run never sees: a watch on n is refused before any
// poll. Returns n, held, or -1 when n is taken. iou_release_hold undoes it.
fn iou_hold_free_number(src int, n int) int {
	held := C.fcntl(src, C.F_DUPFD_CLOEXEC, n)
	if held == n {
		return held
	}
	if held >= 0 {
		C.close(held)
	}
	return -1
}

// iou_release_hold is backend_epoll's release_hold: it closes the hold unless
// the continuation closed it itself and the number may be another's by now.
fn iou_release_hold(src int, held int) {
	pid := C.getpid()
	same := unsafe { C.syscall(C.SYS_kcmp, pid, pid, iou_kcmp_file, src, held) }
	if same == 0 || (same < 0 && C.errno != C.EBADF) {
		C.close(held)
	}
}

// iou_is_live_conn_fd reports whether `fd` is one of this worker's live
// connections (epoll's st.conns[fd] != nil). A scan of the pool: only the cold
// path of a tombstone stepping to a request-owned fd asks.
@[direct_array_access]
fn (env &IouEnv) iou_is_live_conn_fd(fd int) bool {
	w := env.worker
	for i in w.used_lo .. w.conns.len {
		if unsafe { w.conns[i].owner != nil } && w.conns[i].fd == fd {
			return true
		}
	}
	return false
}

// iou_run_tombstone runs the continuation of the tombstone (or released or
// reused slot) at the head of ext_fd's queue, against a throwaway buffer,
// purely to CONSUME its in-flight query result in order (keeping the queue
// aligned with the DB connection's FIFO), then discards it. Returns false
// when the tombstone stays at the head (its result is not ready yet), true
// when it was popped. Out of line, like epoll's run_tombstone: the worker
// loop, into which drain_pipelined_iou is inlined, carries none of this cold
// code (#257).
@[direct_array_access; noinline]
fn iou_run_tombstone(mut env IouEnv, ext_fd int, slot IouParkSlot, ready_err bool) bool {
	conn := slot.conn
	unsafe {
		env.scratch.len = 0
	}
	mut dead_loop := iou_event_loop(mut env, slot.client_fd)
	// rearming_dead: a re-arm from this tombstone's continuation updates
	// only this head slot (continuation, udata) and re-queues the oneshot
	// poll; a watch on another fd is a step away (dead_fd). See
	// iou_register_watch.
	env.rearming_dead = true
	env.dead_fd = ext_fd
	env.dead_step_fd = -1
	env.dead_refused = false
	// The dead client's number, unless its connection still holds it, is
	// held for the run (#257): see iou_hold_free_number.
	hold := if slot.client_fd >= 0 && (unsafe { conn == nil } || unsafe { conn.owner == nil }
		|| conn.fd != slot.client_fd) {
		iou_hold_free_number(env.worker.socket_fd, slot.client_fd)
	} else {
		-1
	}
	env.dead_held = hold >= 0
	dead_step := slot.cont(mut env.scratch, ext_fd, ready_err, slot.udata, env.state, mut
		dead_loop)
	if hold >= 0 {
		iou_release_hold(env.worker.socket_fd, hold)
	}
	env.rearming_dead = false
	env.dead_held = false
	env.dead_fd = -1
	stepped := dead_loop.last_watched
	if stepped >= 0 && stepped != ext_fd && stepped != slot.client_fd
		&& !(stepped < env.watches.len && env.watches[stepped].active)
		&& !env.iou_is_live_conn_fd(stepped) {
		// A request-owned fd, left unrecorded by iou_register_watch (#231):
		// its client is gone, so close it (iou_detach_rejected_watch's rule).
		// The dead client's own number, or a connection's, is never closed
		// (a watch on the former is refused, and the run held it, so no fd
		// the run created has it: #257).
		C.close(stepped)
	}
	// A step that was refused (its last watch armed nothing) moved away
	// from ext_fd too: it read its reply there (#257).
	if dead_step == .suspend
		&& (stepped == ext_fd || (stepped < 0 && !env.dead_refused)) {
		return false // result not ready yet — the tombstone stays at the head
	}
	// Done with ext_fd, or stepped to another fd (or tried to): pop the
	// tombstone, which would otherwise run against the next client's
	// reply (#231).
	env.watches[ext_fd].queue.delete(0)
	env.iou_reactor_clear_if_drained(ext_fd)
	return true
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
		// A tombstoned or released/reused slot: its continuation runs to consume
		// its in-flight result, which is discarded (iou_run_tombstone). Never
		// dereference conn state for a dead slot — identity is the captured fd.
		if slot.dead || unsafe { conn == nil } || unsafe { conn.owner == nil }
			|| conn.fd != slot.client_fd {
			if !iou_run_tombstone(mut env, ext_fd, slot, ready_err) {
				break // its result is not ready yet, so no later one is either
			}
			continue
		}
		iou_unpark(env.worker, mut *conn)
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
				if event_loop.last_watched < 0 {
					// Suspended without re-arming: this edge's poll is consumed and
					// none was queued, so nothing is sure to ever re-run it (only a
					// sibling's leftover poll or a later park on ext_fd might). Close
					// it as on the single-watch path, but keep its slot as a
					// TOMBSTONE: its query's reply must still be consumed in order,
					// and the released pool slot can be reacquired with the same fd
					// number — only `dead` keeps this continuation off that client.
					env.watches[ext_fd].queue[0].dead = true
					conn.close_after_send = true
					iou_finish_resume(mut env, mut *conn, limits, active_conns)
					break
				}
				if event_loop.last_watched != ext_fd {
					// The head stepped to another fd (a backoff timer, a second
					// upstream): it no longer waits on ext_fd. Pop it, or its old
					// continuation would run against the next client's reply here
					// (#231), park the connection on the fd it now waits on, and go
					// on with the new head: the edge may carry its reply too.
					env.watches[ext_fd].queue.delete(0)
					env.iou_reactor_clear_if_drained(ext_fd)
					iou_park(env.worker, mut *conn, event_loop.last_watched)
					continue
				}
				// Front query not ready yet. The continuation re-armed ext_fd in place
				// (iou_reactor_watch found it already queued — no duplicate) and
				// register queued a fresh oneshot poll. Keep it at the head and stop:
				// nothing behind it is ready.
				iou_park(env.worker, mut *conn, ext_fd)
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
