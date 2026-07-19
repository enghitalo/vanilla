module backend_epoll

// The epoll worker's request-serving path: client reads, per-request handler
// dispatch (pipelining, large-body streaming-drain, sendfile hand-off,
// batched flushes) and the watch/park/resume runtime, all driven by the ONE
// worker loop in worker_linux.c.v (process_events_plain).
//
// There is ONE handler contract (core.Handler). A handler that never waits
// just appends its response and returns `.done` — that is the whole hot path.
// A handler that needs to wait on something (a DB socket, an upstream
// connection, a timerfd, the client becoming writable, ...) calls
// `event_loop.watch_fd(fd, interest, continuation, payload)` and returns `.suspend`.
// The worker registers the external fd in its OWN epoll, PARKS the connection
// (its response is not produced yet), and goes on serving other connections.
// When `ext_fd` is ready the worker runs the continuation, which appends the
// response and returns `.done` (send + unpark) or re-arms a watch and returns
// `.suspend` (multi-step chains: connect → send → recv).
//
// The DB driver, reverse-proxy/upstream calls, timers, and SSE/WebSocket
// backpressure are all CONSUMERS of that one `watch` primitive — see the
// async-runtime umbrella issue. Cross-request pipelining (a per-fd FIFO) and
// pool-owned, non-closing watched fds (watch_persistent — a client disconnect
// tombstones the parked request and leaves the fd open for reuse) have
// landed. Parked-connection timeouts remain a follow-up.
import core
import epoll
import http1_1.request_parser
import http1_1.response
import sync.stdatomic
import time

#include <errno.h>
#include <sys/epoll.h>
#include <sys/socket.h>

// WatchEntry records one parked request: which client connection is waiting, the
// continuation to run when the watched fd is ready, and the consumer's opaque
// context handed back via Worker.udata. `active` is the slot's occupancy flag:
// the table is indexed by fd (a flat array, not a hashmap), so a cleared slot is
// just `active = false` rather than an erased key.
//
// `queue` is EMPTY for the overwhelming common case of one watch per fd (a
// timerfd, an SSE stream, a single in-flight query): the active/client_fd/cont/
// udata fields drive everything and there is no extra allocation. It is populated
// only when a SECOND distinct client parks on an already-active fd — i.e. a
// pg_async connection carrying pipelined queries (see async_db cross-request
// pipelining). Then `queue` is the FIFO of parked clients, `client_fd/cont/udata`
// are unused, and on_watch_ready drains it in submission order.
struct WatchEntry {
mut:
	active    bool
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
	queue     []ParkSlot // empty = single watch; non-empty = pipelined (multi-client) fd
	// persistent: the fd is a long-lived, caller-owned resource (a pooled DB
	// connection), armed via watch_persistent. When the client parked on it
	// disconnects mid-query the runtime must NOT close it — it tombstones the parked
	// request (drains + discards the orphaned reply in order) and leaves the fd open
	// for reuse, instead of forcing a reconnect + re-handshake. Sticky once set, so a
	// re-arm cycle that momentarily reverts the slot to single-watch keeps it.
	persistent bool
}

// ParkSlot is one parked client on a pipelined fd: the same (client, continuation,
// udata) triple a single WatchEntry holds, but queued so that one readable edge on
// a multiplexed pg connection can complete several requests in submission order.
// `dead` marks a client that disconnected while still parked: its slot STAYS in the
// queue (removing it would desync the queue from the connection's in-flight FIFO,
// and the freed client_fd could be reused by a new connection — ABA), but its
// continuation is run against a throwaway buffer so its query result is still
// consumed in order and the response discarded.
struct ParkSlot {
mut:
	client_fd int
	cont      core.WakeFn = unsafe { nil }
	udata     voidptr
	dead      bool
}

// Reactor is the per-worker watch registry: a flat array indexed by the
// external fd (NOT a hashmap) — the same fd-indexed, doubling-grown layout the
// synchronous path already uses for `PlainState.conns`. Watch/resume/clear are
// then plain array writes with no hashing or per-request allocation (the event
// loop's hot lookup is `watches[fd].active`). One per worker thread, no lock.
struct Reactor {
mut:
	watches []WatchEntry
	// Sticky "any watch was ever armed on this worker" flag. The event loop
	// checks it before probing the watch table, so a server whose handlers never
	// suspend (and with no on_worker_start watch) pays ONE predictable bool test
	// per event instead of an fd-indexed table load — the pure-sync fast path.
	armed bool
	// Set around a tombstoned slot's continuation (drain_pipelined dead branch):
	// its re-arm must ONLY re-arm the fd in epoll — the tombstone queue slot stays
	// exactly as it is (same continuation, same udata), and the watch table must
	// not be touched (a dedup match would refresh the tombstone; a dedup that
	// skips dead slots would append a duplicate).
	rearming_dead bool
}

// reactor_clear_if_drained deactivates ext_fd's watch when its pipelined queue
// has just been fully consumed. MUST run at the pop that drains the queue,
// BEFORE any continuation/serve that could re-park on ext_fd: a trailing
// "queue empty ⇒ active=false" epilogue would run AFTER such a re-park updated
// the (stale) head fields in place, deactivating the re-park's live watch and
// stranding its request forever (vanilla#100 hazard 1).
@[direct_array_access; inline]
fn (mut r Reactor) reactor_clear_if_drained(ext_fd int) {
	if ext_fd >= 0 && ext_fd < r.watches.len && r.watches[ext_fd].queue.len == 0 {
		r.watches[ext_fd].active = false
	}
}

// reactor_watch records (or rearms) the watch for ext_fd, growing the flat table
// by doubling if the fd is past the current bound — mirroring state_for's growth
// so high fd numbers stay O(1)-indexed with no hashing.
@[direct_array_access]
fn (mut r Reactor) reactor_watch(ext_fd int, client_fd int, cont core.WakeFn, udata voidptr) {
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
	if !r.watches[ext_fd].active {
		// Fresh watch — the single-watch fast path (timerfd / SSE / one query).
		// Reset the fields in place and REUSE the slot's (already-empty) queue
		// rather than assigning a `WatchEntry{}` literal: the literal default-inits
		// the omitted `queue []ParkSlot` to a fresh empty array — one heap
		// allocation per park, which leaks under `-gc none`. Semantics are
		// identical to the literal (persistent reset to false; register_watch
		// re-stamps it right after when the fd is pool-owned).
		r.watches[ext_fd].active = true
		r.watches[ext_fd].client_fd = client_fd
		r.watches[ext_fd].cont = cont
		r.watches[ext_fd].udata = udata
		r.watches[ext_fd].persistent = false
		unsafe {
			r.watches[ext_fd].queue.len = 0
		}
		return
	}
	// The fd already has a parked watch. A SECOND distinct client on the same fd
	// means it is multiplexing (a pipelined pg connection): promote to a queue and
	// fan the readiness out in submission order. A re-arm by an ALREADY-parked
	// client (the front continuation asking for more bytes) updates in place — never
	// a duplicate append.
	if r.watches[ext_fd].queue.len == 0 {
		if r.watches[ext_fd].client_fd == client_fd {
			r.watches[ext_fd].cont = cont
			r.watches[ext_fd].udata = udata
			return
		}
		// Promote: move the existing head into the queue (len is 0 here), then the
		// dedup loop below appends the newcomer. Push into the slot's RETAINED
		// buffer rather than assigning a `[ParkSlot{...}]` literal: the literal
		// reallocates the queue every promote cycle, which leaks under -gc none.
		// The buffer grows once to the max pipeline depth and is reused thereafter
		// (drain resets len to 0 without freeing).
		r.watches[ext_fd].queue << ParkSlot{
			client_fd: r.watches[ext_fd].client_fd
			cont:      r.watches[ext_fd].cont
			udata:     r.watches[ext_fd].udata
		}
	}
	for i in 0 .. r.watches[ext_fd].queue.len {
		// Match LIVE slots only: a tombstone must never be revived by a new park
		// whose client_fd happens to match (a reused fd) — the tombstone still
		// drains its own orphaned reply first; the new park queues behind it,
		// which is also FIFO-correct (its query was submitted later). Tombstone
		// re-arms never reach this function (see rearming_dead in register_watch).
		if !r.watches[ext_fd].queue[i].dead && r.watches[ext_fd].queue[i].client_fd == client_fd {
			r.watches[ext_fd].queue[i].cont = cont
			r.watches[ext_fd].queue[i].udata = udata
			return
		}
	}
	r.watches[ext_fd].queue << ParkSlot{
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
fn (mut r Reactor) reactor_clear(ext_fd int) {
	if ext_fd >= 0 && ext_fd < r.watches.len {
		r.watches[ext_fd].active = false
	}
}

// reactor_mark_dead tombstones the queued slot for client_fd on a pipelined ext_fd
// (the client disconnected mid-pipeline). The slot is kept so the queue stays
// aligned with the connection's in-flight FIFO; drain_pipelined consumes its
// result in order and discards it. Identified by client_fd, never re-looked-up
// against st.conns, so a reused fd cannot be mistaken for the dead client.
@[direct_array_access]
fn (mut r Reactor) reactor_mark_dead(ext_fd int, client_fd int) {
	if ext_fd < 0 || ext_fd >= r.watches.len {
		return
	}
	for i in 0 .. r.watches[ext_fd].queue.len {
		// Skip already-dead slots: with fd reuse a dead slot can share client_fd
		// with a LIVE later park — the live one is the tombstoning target.
		if !r.watches[ext_fd].queue[i].dead && r.watches[ext_fd].queue[i].client_fd == client_fd {
			r.watches[ext_fd].queue[i].dead = true
			return
		}
	}
}

// detach_rejected_watch tears down a watch that a handler/continuation registered
// during a call whose OUTCOME rejected the park — a streamed large-body head that
// suspended (unsupported: answered 400 and dropped), or .done/.close returned
// after watch_fd. Without this the entry stays active, keyed by a client_fd that
// is about to be closed and REUSED: a later readiness edge would run the stale
// continuation against whatever connection now owns that fd (vanilla#100 hazard
// 2). Same teardown close_client applies on a mid-park disconnect: tombstone a
// pipelined slot / a persistent single watch (the in-flight reply must still be
// consumed IN ORDER, then discarded), and clear+close a request-owned fd.
fn detach_rejected_watch(mut reactor Reactor, epoll_fd int, ext_fd int, client_fd int) {
	if ext_fd < 0 || ext_fd >= reactor.watches.len || !reactor.watches[ext_fd].active {
		return
	}
	if reactor.watches[ext_fd].queue.len > 0 {
		reactor.reactor_mark_dead(ext_fd, client_fd)
	} else if !reactor.reactor_orphan_single(ext_fd, client_fd) {
		reactor.reactor_clear(ext_fd)
		epoll.remove_fd_from_epoll(epoll_fd, ext_fd) // DEL + close the request-owned fd
	}
}

// reactor_orphan_single handles a client disconnecting while parked ALONE (single
// watch, no queue) on a fd. For a PERSISTENT, pool-owned connection (a DB conn
// armed via watch_persistent) the fd must NOT be closed — closing it would force a
// reconnect and a fresh auth handshake on the next borrow. Instead the single watch
// is converted into a one-slot DEAD tombstone, reusing the pipelined drain: the
// orphaned in-flight reply is consumed (and discarded) in order when it arrives,
// keeping the connection in sync, and the fd is left armed + open for reuse. Returns
// true when it tombstoned (the caller leaves the fd alone). Returns false for a
// request-owned fd (not persistent), an inactive watch, an out-of-range fd, or one
// that already has a queue — the caller then clears the watch and closes the fd.
fn (mut r Reactor) reactor_orphan_single(ext_fd int, client_fd int) bool {
	if ext_fd < 0 || ext_fd >= r.watches.len {
		return false
	}
	e := r.watches[ext_fd]
	if e.queue.len != 0 || !e.persistent || !e.active {
		return false
	}
	// Tombstone the orphaned single watch as a one-slot queue. Push into the
	// slot's retained buffer (len is 0 here) rather than assigning a literal, so
	// the pool-owned fd's queue is never reallocated — a per-disconnect leak under
	// -gc none.
	r.watches[ext_fd].queue << ParkSlot{
		client_fd: client_fd
		cont:      e.cont
		udata:     e.udata
		dead:      true
	}
	return true
}

// register_watch is installed into EventLoop.register; it is what `event_loop.watch_fd(...)`
// ultimately calls. It records the watch and arms the external fd in this
// worker's epoll (level-triggered: simplest correct default for arbitrary
// consumer fds). Runs on the worker thread, so no synchronization is needed.
fn register_watch(mut w core.EventLoop, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	if ext_fd < 0 {
		// A consumer handed us a failed fd (e.g. timerfd_create returned -1); never
		// index the flat table at a negative slot. Arm nothing.
		w.last_watched = -1
		return
	}
	mut r := unsafe { &Reactor(w.reactor) }
	r.armed = true // sticky: the event loop starts probing the watch table
	if r.rearming_dead {
		// Tombstone re-arm (drain_pipelined dead branch): the queue slot stays
		// exactly as it is — only the (already-armed, level-triggered) fd needs to
		// remain in epoll. Do NOT touch the watch table: a dedup match would
		// refresh the tombstone, and a dedup that skips dead slots would append a
		// duplicate live entry for a dead client.
		if epoll.mod_fd_in_epoll(w.loop_fd, ext_fd, u32(C.EPOLLIN)) != 0 {
			epoll.add_fd_to_epoll(w.loop_fd, ext_fd, u32(C.EPOLLIN))
		}
		w.last_watched = ext_fd
		return
	}
	r.reactor_watch(ext_fd, w.client_fd, cont, udata)
	if w.persistent {
		// Pool-owned fd (watch_persistent): mark the slot so a client disconnect won't
		// close it. Sticky — reactor_watch zeroes the entry on a fresh single watch, so
		// this re-stamps it every park; promotion to a queue preserves it.
		r.watches[ext_fd].persistent = true
	}
	events := if interest == .writable { u32(C.EPOLLOUT) } else { u32(C.EPOLLIN) }
	// Re-arm if the fd is already in this worker's epoll (a pool-owned connection
	// re-watched across queries), otherwise add it (a fresh request-owned fd).
	// Trying MOD first avoids an EEXIST perror on every pool-fd reuse and needs no
	// extra bookkeeping: a fresh fd's MOD fails with ENOENT and falls through to ADD.
	if epoll.mod_fd_in_epoll(w.loop_fd, ext_fd, events) != 0 {
		if epoll.add_fd_to_epoll(w.loop_fd, ext_fd, events) < 0 {
			// The fd could not be armed (bad fd, epoll limits): don't leave a slot
			// marked active that the loop would never actually fire — clear it so the
			// watch is genuinely absent rather than silently dead.
			r.reactor_clear(ext_fd)
			w.last_watched = -1
			return
		}
	}
	w.last_watched = ext_fd
}

// handle_readable is the EPOLLIN entry point for a client connection: it
// drains the socket, answers every complete request, and parks only when a
// handler actually suspends. The worker loop in worker_linux.c.v routes
// watched-fd readiness to on_watch_ready and client reads here; the event
// loop, accept, the busy-poll hybrid and the timeout sweep live there.
@[direct_array_access; manualfree]
fn handle_readable(h core.Handler, mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	// In-flight window for the graceful-shutdown drain (per-worker counter, own
	// cache line — uncontended, measured free on the hot path).
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	mut cs := state_for(mut st, fd)
	// Already parked on a watch: a readable edge here is either the client hanging
	// up or pipelining ahead. Peek to detect a close (tear the watch down); any
	// data stays in the socket buffer and is read once the in-flight watch resumes.
	if cs.awaiting_fd >= 0 {
		mut probe := [1]u8{}
		if C.recv(fd, &probe[0], 1, C.MSG_PEEK) == 0 {
			close_client(mut reactor, epoll_fd, fd, active_conns, mut st)
		}
		return
	}
	// The conn-mode seam (issue #136): a taken-over connection's bytes belong to
	// its ConnHandler, not the HTTP/1.1 state machine. nil for every connection
	// that never upgraded — one predictable branch on the hot path.
	if cs.takeover != unsafe { nil } {
		serve_takeover_conn(mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state)
		return
	}
	serve_conn(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state)
}

// serve_conn drains the socket into the read buffer (edge-triggered), answers
// every complete request as it arrives (pipelining), and flushes the batch at
// the end. It carries the same large-body handling as the synchronous path: a
// body past sm_stream_body_above is STREAMED (head answered, body drained +
// discarded) instead of buffered, and a handler that hands a file off for
// sendfile(2) has it streamed by flush_batch. Stops reading when a request parks.
@[direct_array_access; manualfree]
fn serve_conn(h core.Handler, mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) {
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}
	// Drain requests ALREADY buffered before reading more. A `.done` resume hands
	// this function a read_buf holding the requests that were pipelined BEHIND the
	// parked one — they arrived long ago, so no further readable edge is coming on
	// the (edge-triggered) client fd, and the recv-first loop below would EAGAIN
	// out and strand them forever (vanilla#100: the pipelined-behind-a-park drain).
	// On the plain readable-edge path this is a no-op: a leftover partial frames
	// to -1 and nothing is consumed.
	if cs.body_drain == 0 && cs.read_buf.len > 0 {
		if !drain_requests(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs,
			state) {
			return
		}
		if cs.awaiting_fd >= 0 {
			// A buffered request parked: stop reading (mirrors the in-loop park
			// break) and flush what was produced before the park.
			update_read_deadline(limits, mut st, mut cs) // parked ⇒ clears any armed deadline
			if cs.write_buf.len > cs.write_off || cs.file_remaining > 0 {
				flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
			}
			return
		}
		if cs.takeover != unsafe { nil } {
			// A buffered request upgraded the connection (issue #136): flush the
			// switching response, then the takeover drain owns the leftover bytes
			// and the socket.
			if cs.write_buf.len > cs.write_off || cs.file_remaining > 0 {
				if !flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
					return
				}
			}
			serve_takeover_conn(mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs,
				state)
			return
		}
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
				match start_body_drain(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut
					cs, state, target) {
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
			// Client half-closed its write side (EOF). If a response is already
			// pending, we still owe it on the open write half (RFC 9112 §9.6, issue
			// #103): mark the connection to close once the buffer drains and break to
			// the end-of-burst flush below, instead of dropping the reply. With no
			// pending response there is nothing to send — close now.
			if cs.body_drain == 0 && (cs.write_buf.len > cs.write_off || cs.file_remaining > 0) {
				cs.close_after_flush = true
				break
			}
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		unsafe {
			cs.read_buf.len += n
		}
		if !drain_requests(h, mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs,
			state) {
			return
		}
		if cs.awaiting_fd >= 0 {
			break // a request parked on a watch — stop reading until it resumes
		}
		if cs.takeover != unsafe { nil } {
			break // upgraded mid-burst — flush the 101 below, then hand the socket off
		}
		if cs.read_buf.len > req_cap {
			cs.write_buf << response.status_413_response
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return
		}
		// Expect: 100-continue (RFC 9110 §10.1.1). drain_requests left a partial
		// request in read_buf (its body has not fully arrived); if its head is
		// complete and asks for 100-continue, prompt the client ONCE by queueing an
		// interim 100 for the end-of-burst flush. Gated so the hot path pays nothing:
		// only reached when bytes remain buffered (drain consumed a complete request
		// otherwise) and never re-scanned once sent_100 is set.
		if cs.read_buf.len == 0 {
			if cs.sent_100 {
				cs.sent_100 = false // request fully consumed — re-arm for the next one
			}
		} else if !cs.sent_100 && cs.body_drain == 0 {
			head_len := request_parser.frame_head_len(cs.read_buf)
			if head_len > 0 && request_parser.head_expects_100_continue(cs.read_buf, head_len) {
				cs.write_buf << response.status_100_continue_response
				cs.sent_100 = true
			}
		}
	}
	// Read-timeout bookkeeping — BEFORE the flush below, which may close the
	// connection (close_conn resets the state; arming after it would leak a
	// st.parked count into the pooled ConnState).
	update_read_deadline(limits, mut st, mut cs)
	// Hold a streamed upload's response until its body is fully drained (body_drain
	// == 0), so the client never sees the response mid-body (see start_body_drain).
	if cs.body_drain == 0 && (cs.write_buf.len > cs.write_off || cs.file_remaining > 0) {
		if !flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			return
		}
		// Half-closed peer (issue #103): the reply is out (or, if the socket
		// buffer was full, flush_batch parked it on EPOLLOUT and handle_writable_plain
		// will finish + close via close_after_flush). If it drained synchronously
		// here — write_off caught up and nothing parked — close now; the peer can
		// send nothing more.
		if cs.close_after_flush && cs.write_off >= cs.write_buf.len && cs.file_remaining <= 0 {
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
	} else if cs.close_after_flush {
		// EOF with nothing left to flush (already sent) — close.
		close_conn(epoll_fd, fd, active_conns, mut st)
		return
	}
	// Upgraded mid-burst (the takeover break above): the switching response just
	// flushed; the takeover drain now consumes any bytes pipelined behind the
	// upgrade request and reads the socket to EAGAIN (edge-triggered contract).
	if cs.takeover != unsafe { nil } {
		serve_takeover_conn(mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state)
	}
}

// update_read_deadline arms the read deadline ONCE while a request is mid-read
// (partial bytes buffered, or a large body mid-drain — a peer that stalls
// mid-upload is still reaped) and clears it when the buffer is idle OR the
// connection just parked on a watch — a parked request waits on its watched
// fd, not on the client, and leftover bytes in read_buf are pipelined-behind
// requests, not a stalled read. Like every other read path (TLS, io_uring),
// the deadline is armed once and not refreshed on progress, so read_timeout_ms
// — when set (default 0 = off) — bounds the TOTAL time to receive a request,
// including a streamed body. Size it for the largest upload you accept.
@[inline]
fn update_read_deadline(limits core.Limits, mut st PlainState, mut cs ConnState) {
	if cs.awaiting_fd < 0 && (cs.read_buf.len > 0 || cs.body_drain > 0) {
		if limits.read_timeout_ms > 0 && cs.read_deadline == 0 {
			cs.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			st.parked++
		}
	} else if cs.read_deadline != 0 {
		cs.read_deadline = 0
		st.parked--
	}
}

// serve_takeover_conn drives a taken-over connection (issue #136): drain any
// buffered bytes through the ConnHandler, then recv to EAGAIN (edge-triggered
// contract), draining as bytes arrive, and flush the batch at the end. The
// same persistent buffers, EPOLLOUT backpressure parking and timeout sweep as
// the HTTP path — only the framing authority changed.
@[direct_array_access; manualfree]
fn serve_takeover_conn(mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) {
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}
	// Bytes pipelined behind the upgrade request (or left from the previous
	// burst) first — no readable edge is coming for them (vanilla#100 lesson).
	if cs.read_buf.len > 0 {
		if !drain_takeover(mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state) {
			return
		}
	}
	for {
		if cs.read_buf.len == cs.read_buf.cap {
			// A single frame larger than the request-buffer ceiling can never
			// complete — the engine's own bound, mirroring the HTTP 413 path.
			if cs.read_buf.cap >= req_cap {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return
			}
			growth := if cs.read_buf.cap > req_cap - cs.read_buf.cap {
				req_cap - cs.read_buf.cap
			} else {
				cs.read_buf.cap
			}
			unsafe { cs.read_buf.grow_cap(growth) }
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
			// Peer EOF. A taken-over protocol has its own close choreography (the
			// ConnHandler answers close frames with .close); a bare EOF means the
			// peer is gone — nothing left to say, close.
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		unsafe {
			cs.read_buf.len += n
		}
		if !drain_takeover(mut reactor, epoll_fd, fd, limits, active_conns, mut st, mut cs, state) {
			return
		}
	}
	// A partial frame arms the read deadline; an idle (empty-buffer) connection
	// clears it — so read_timeout_ms reaps a peer stalled MID-FRAME but never a
	// quiet long-lived connection between messages.
	update_read_deadline(limits, mut st, mut cs)
	if cs.write_buf.len > cs.write_off {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
}

// drain_takeover feeds the buffered bytes to the connection's ConnHandler until
// it stops consuming (partial frame) or the buffer empties. Mirrors
// drain_requests' shape: consumed bytes are compacted away, responses batch in
// write_buf, and the pending-write cap bounds a peer that floods frames without
// reading. Returns false if the connection was closed.
@[direct_array_access; manualfree]
fn drain_takeover(mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) bool {
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  register_watch
	}
	for cs.read_buf.len > 0 {
		event_loop.last_watched = -1
		mut consumed, step := cs.takeover(buf_view(cs.read_buf, 0, cs.read_buf.len), mut
			cs.write_buf, fd, cs.takeover_state, state, mut event_loop)
		if event_loop.last_watched >= 0 {
			// v1: takeover connections cannot park (.suspend unsupported, issue
			// #136) — any watch a ConnHandler armed is a contract violation; tear
			// it down before it can fire against a reused client_fd.
			detach_rejected_watch(mut reactor, epoll_fd, event_loop.last_watched, fd)
		}
		if consumed > cs.read_buf.len {
			consumed = cs.read_buf.len // defensive: never compact past the buffer
		}
		if consumed > 0 {
			compact_read_buf(mut cs, consumed)
		}
		match step {
			.done {
				if consumed == 0 {
					return true // partial frame — wait for more bytes
				}
				// consumed > 0: more complete frames may still be buffered — loop.
			}
			else {
				// .close — and .suspend (unsupported in v1) degrades to it: flush
				// what the handler appended (e.g. its close frame), then close.
				if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
					close_conn(epoll_fd, fd, active_conns, mut st)
				}
				return false
			}
		}

		if cs.write_buf.len - cs.write_off > sm_max_pending_write {
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
	}
	return true
}

// start_body_drain answers a large-body request from its HEAD alone, then
// puts the connection into streaming-drain mode for the body (the cs.body_drain
// branch above). The async counterpart of start_body_drain — such handlers must
// answer by Content-Length and complete synchronously (.done); a head handler
// that suspends mid-large-body is not supported in v1 and drops the connection.
// Returns 1 = draining started, 2 = connection closed, 0 = head not complete yet.
@[direct_array_access]
fn start_body_drain(h core.Handler, mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr, total int) int {
	head_len := request_parser.frame_head_len(cs.read_buf)
	if head_len <= 0 || head_len > cs.read_buf.len {
		return 0 // head not complete in the buffer yet — grow/recv more
	}
	content_length := total - head_len
	// max_body_bytes must hold on the STREAMED path too: the framed path rejects
	// an oversized declared body with 413 (frame_request_length_lim_idx), and a
	// body large enough to stream must not BYPASS that limit just because it
	// skips buffering. The length is declared in the head, so reject before the
	// handler ever runs; close, since the unread body makes the request stream
	// unrecoverable (same reason the framed 413 closes).
	if limits.max_body_bytes > 0 && content_length > limits.max_body_bytes {
		cs.write_buf << response.status_413_response
		if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			close_conn(epoll_fd, fd, active_conns, mut st)
		}
		return 2
	}
	head := buf_view(cs.read_buf, 0, head_len)
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  register_watch
	}
	head_step := h(head, mut cs.write_buf, fd, state, mut event_loop)
	// A takeover queued on the streamed large-body path is unsupported (the body
	// is still in flight — there is no clean byte at which the protocol could
	// change): drain the thread-local slot and treat it like the suspend case
	// below — 400 and drop, never a half-upgraded connection.
	mut streamed_takeover := false
	if _ := core.take_queued_takeover() {
		streamed_takeover = true
	}
	if head_step != .done || streamed_takeover {
		// suspend/close on a streamed-body request is unsupported in v1 — answer
		// 400 and drop, rather than leave a half-drained connection parked. The
		// handler may ALREADY have registered a watch (and submitted a query)
		// before suspending: tear it down, or the entry would stay active keyed by
		// this soon-reused client_fd, and a pooled fd's orphaned reply would be
		// consumed against the wrong request (vanilla#100 hazard 2).
		if event_loop.last_watched >= 0 {
			detach_rejected_watch(mut reactor, epoll_fd, event_loop.last_watched, fd)
		}
		cs.write_buf << response.tiny_bad_request_response
		if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			close_conn(epoll_fd, fd, active_conns, mut st)
		}
		return 2
	}
	// DRAIN-THEN-RESPOND: the head response is buffered in write_buf but is NOT
	// flushed here. The body is drained first (the cs.body_drain branch in
	// serve_conn) and only once it is fully consumed does serve_conn's end-of-burst
	// flush (gated on body_drain == 0) send it — so a client that writes the whole
	// request before reading is never desynced by an early response. (This path was
	// previously dead: an inverted `flush_batch` check closed the connection right
	// after the head response, so the body was never drained.)
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

// drain_requests answers every complete request currently buffered, appending each
// response to write_buf, and STOPS at the first request that suspends (it parks;
// the rest stay buffered and are drained when the watch resumes). Mirrors the
// synchronous drain_requests but with the async step contract. Returns false if
// the connection was closed (the caller must not touch it).
@[direct_array_access; manualfree]
fn drain_requests(h core.Handler, mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) bool {
	mut pos := 0
	// ONE EventLoop handle per burst, not per request: every field is
	// loop-invariant; only last_watched is reset before each handler call below.
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  register_watch
	}
	for pos < cs.read_buf.len && cs.awaiting_fd < 0 {
		// _idx twin: plain int, no per-request !int boxing. The error sentinel is
		// the negated HTTP status, so `-total` recovers the old err.code() value.
		total := request_parser.frame_request_length_lim_idx(buf_view(cs.read_buf, pos,
			cs.read_buf.len - pos), limits.max_header_bytes, limits.max_body_bytes)
		if total == -1 {
			break // incomplete — wait for more bytes
		}
		if total < -1 {
			match -total {
				413 { cs.write_buf << response.status_413_response }
				431 { cs.write_buf << response.status_431_response }
				else { cs.write_buf << response.tiny_bad_request_response }
			}

			compact_read_buf(mut cs, pos)
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
		// A file deferred by an earlier request in this batch must be emitted (as
		// bytes, in order) BEFORE this next response is appended — same ordering
		// rule as the synchronous drain_requests.
		if cs.file_remaining > 0 {
			append_file_region(mut cs.write_buf, cs.file_fd, cs.file_off, cs.file_remaining)
			cs.file_fd = -1
			cs.file_remaining = 0
		}
		req := buf_view(cs.read_buf, pos, total)
		// Only last_watched can be dirtied between iterations (register_watch is
		// the sole runtime writer during an initial call).
		event_loop.last_watched = -1
		step := h(req, mut cs.write_buf, fd, state, mut event_loop)
		pos += total
		if step != .suspend && event_loop.last_watched >= 0 {
			// The handler registered a watch but did NOT park (.done/.close after
			// watch_fd — a contract violation): tear it down so no stale entry can
			// later fire against this (soon-reused) client_fd.
			detach_rejected_watch(mut reactor, epoll_fd, event_loop.last_watched, fd)
		}
		// Drain the takeover slot on EVERY step, not just .done: it is
		// thread-local, so a handler that queued and then suspended/closed
		// (a contract violation) must not leak its takeover into the next
		// request this worker serves. nil cont = nothing was queued.
		qt := core.take_queued_takeover() or { core.QueuedTakeover{} }
		match step {
			.done {
				// Handler may have appended headers + handed its body off for
				// sendfile(2); it streams after write_buf drains (flush_batch).
				if qf := core.take_queued_file() {
					cs.file_fd = qf.file_fd
					cs.file_off = qf.off
					cs.file_remaining = qf.len
				}
				// ...or handed the CONNECTION off (issue #136): from here on the
				// bytes are no longer HTTP — stop parsing this burst as requests.
				// The leftover stays buffered (compacted below) for the takeover
				// drain, which runs after the switching response flushes.
				if qt.cont != unsafe { nil } {
					cs.takeover = qt.cont
					cs.takeover_state = qt.state
					break
				}
			}
			.suspend {
				cs.awaiting_fd = event_loop.last_watched // park; leftover stays buffered for resume
			}
			.close {
				compact_read_buf(mut cs, pos)
				if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
					close_conn(epoll_fd, fd, active_conns, mut st)
				}
				return false
			}
		}

		// Peer pipelines without reading responses: bail before the batch is unbounded.
		if cs.write_buf.len - cs.write_off > sm_max_pending_write {
			compact_read_buf(mut cs, pos)
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
	}
	compact_read_buf(mut cs, pos)
	return true
}

// compact_read_buf drops the first `pos` consumed bytes, keeping the leftover
// (partial / not-yet-answered) request at the buffer front.
@[direct_array_access; inline]
fn compact_read_buf(mut cs ConnState, pos int) {
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

// on_watch_ready runs a parked request's continuation when its watched fd fires.
// `ev` is the raw epoll event mask for this edge; an error/hangup (EPOLLERR|
// EPOLLHUP) is surfaced to the continuation as the portable Worker.ready_err so
// it can release a dead fd instead of re-arming it into a busy-spin.
@[direct_array_access; manualfree]
fn on_watch_ready(h core.Handler, mut reactor Reactor, epoll_fd int, ext_fd int, ev u32, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	// Resumes count toward the in-flight window too, so a graceful shutdown
	// drain also covers continuations running right now.
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}
	// A pipelined fd (multiple parked clients on one multiplexed pg connection):
	// fan this readiness edge out to the queued continuations in submission order.
	// The single-watch path below is left byte-identical for every other consumer.
	if reactor.watches[ext_fd].queue.len > 0 {
		drain_pipelined(h, mut reactor, epoll_fd, ext_fd, ev, limits, active_conns, mut st, state)
		return
	}
	// Copy the three live fields into locals (NOT the whole entry — that copies
	// the queue array header per resume for nothing), then clear the slot; the
	// continuation re-arms if it needs more.
	parked_client := reactor.watches[ext_fd].client_fd
	cont := reactor.watches[ext_fd].cont
	entry_udata := reactor.watches[ext_fd].udata
	reactor.reactor_clear(ext_fd)
	ready_err := ev & (u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0
	// Clientless background watch (armed by on_worker_start, e.g. a per-worker
	// refresh timerfd): there is no parked connection. Run the continuation with a
	// throwaway buffer; worker_state is passed through and it re-arms via
	// event_loop.watch_fd. The slot was already cleared above, so the ONLY way the
	// watch stays alive is the continuation re-arming THIS SAME fd and suspending
	// (the periodic-refresh case). Any other outcome means the continuation stopped
	// watching ext_fd; we must then ensure ext_fd is neither active nor left in
	// this worker's epoll, otherwise a later readiness edge on it falls through to
	// the client read path and is mistaken for a connection (fabricating a phantom
	// conn and skewing active_conns). The fd OBJECT is the app's: it created it and
	// closes it — except on a clean .done/.close, where the runtime owns teardown.
	if parked_client < 0 {
		mut scratch := []u8{}
		mut bg_loop := core.EventLoop{
			client_fd: -1
			loop_fd:   epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  register_watch
		}
		step := cont(mut scratch, ext_fd, ready_err, entry_udata, state, mut bg_loop)
		// A clientless watch has no connection to take over — drain the
		// thread-local slot so a misbehaving continuation can't leak one.
		if _ := core.take_queued_takeover() {
		}
		if step == .suspend && bg_loop.last_watched == ext_fd {
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
	client_fd := parked_client
	if client_fd >= st.conns.len {
		return
	}
	mut cs := st.conns[client_fd]
	if unsafe { cs == nil } {
		return
	}
	cs.awaiting_fd = -1
	mut event_loop := core.EventLoop{
		client_fd: client_fd
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  register_watch
	}
	cont_step := cont(mut cs.write_buf, ext_fd, ready_err, entry_udata, state, mut event_loop)
	if cont_step != .suspend && event_loop.last_watched >= 0 {
		// Continuation re-watched but did not park (.done/.close after watch_fd):
		// tear the stray watch down before the connection moves on / is closed.
		detach_rejected_watch(mut reactor, epoll_fd, event_loop.last_watched, client_fd)
	}
	// Drain the takeover slot on every step (thread-local — a queued takeover
	// must never leak into another request). On .done this is the ASYNC upgrade
	// path: a handler that parked (e.g. an auth check against an upstream) and
	// whose continuation appended the 101 + queued the takeover.
	qt := core.take_queued_takeover() or { core.QueuedTakeover{} }
	match cont_step {
		.done {
			if qt.cont != unsafe { nil } {
				cs.takeover = qt.cont
				cs.takeover_state = qt.state
				// Flush the switching response, then the takeover drain owns the
				// leftover buffered bytes and the socket.
				if cs.write_buf.len > cs.write_off {
					if !flush_batch(epoll_fd, client_fd, limits, active_conns, mut st, mut cs) {
						return
					}
				}
				serve_takeover_conn(mut reactor, epoll_fd, client_fd, limits, active_conns, mut st, mut
					cs, state)
				return
			}
			// Send this response and drain any requests that were pipelined behind it
			// (and read anything that arrived while parked) — one batched flush.
			serve_conn(h, mut reactor, epoll_fd, client_fd, limits, active_conns, mut st, mut cs,
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
			cs.awaiting_fd = event_loop.last_watched // re-armed (multi-step); stay parked
		}
		.close {
			close_conn(epoll_fd, client_fd, active_conns, mut st)
		}
	}
}

// drain_pipelined fans one readiness edge on a multiplexed pg connection out to
// the clients queued on it, in submission order. The queue head aligns with the
// connection's front in-flight query (each request did async_submit then watch as
// one step), so the head's continuation calls async_on_readable() and gets ITS
// query's result. We run heads until one cannot complete yet (.suspend): by FIFO,
// if the front query is not ready no later one is either, so we stop. Each .done
// is sent (and HTTP pipelined behind it on that client drained) before the next.
@[direct_array_access; manualfree]
fn drain_pipelined(h core.Handler, mut reactor Reactor, epoll_fd int, ext_fd int, ev u32, limits core.Limits, active_conns &core.Counter, mut st PlainState, state voidptr) {
	ready_err := ev & (u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0
	for reactor.watches[ext_fd].queue.len > 0 {
		slot := reactor.watches[ext_fd].queue[0]
		client_fd := slot.client_fd
		// A tombstoned client (disconnected mid-pipeline): run its continuation
		// against a throwaway buffer purely to CONSUME its in-flight query result in
		// order (keeping the queue aligned with the connection's FIFO), then discard
		// it. Never re-look-up st.conns for a dead slot — the fd may have been reused.
		if slot.dead || client_fd < 0 || client_fd >= st.conns.len
			|| unsafe { st.conns[client_fd] == nil } {
			mut scratch := []u8{}
			mut dead_loop := core.EventLoop{
				client_fd: client_fd
				loop_fd:   epoll_fd
				reactor:   unsafe { voidptr(&reactor) }
				register:  register_watch
			}
			// rearming_dead: a re-arm from this tombstone's continuation must leave
			// the watch table alone (the tombstone slot stays exactly as it is) —
			// see register_watch. Without the bypass, dedup matching the dead slot
			// would refresh it, and a dedup that SKIPS dead slots would append a
			// duplicate instead.
			reactor.rearming_dead = true
			dead_step := slot.cont(mut scratch, ext_fd, ready_err, slot.udata, state, mut dead_loop)
			reactor.rearming_dead = false
			// A dead client cannot be taken over — drain the thread-local slot.
			if _ := core.take_queued_takeover() {
			}
			if dead_step == .suspend {
				break // result not ready yet — the tombstone stays at the head
			}
			reactor.watches[ext_fd].queue.delete(0)
			reactor.reactor_clear_if_drained(ext_fd)
			continue
		}
		mut cs := st.conns[client_fd]
		cs.awaiting_fd = -1
		mut event_loop := core.EventLoop{
			client_fd: client_fd
			loop_fd:   epoll_fd
			reactor:   unsafe { voidptr(&reactor) }
			register:  register_watch
		}
		pipelined_step := slot.cont(mut cs.write_buf, ext_fd, ready_err, slot.udata, state, mut
			event_loop)
		if pipelined_step != .suspend && event_loop.last_watched >= 0
			&& event_loop.last_watched != ext_fd {
			// Continuation watched a DIFFERENT fd but did not park: stray watch —
			// tear it down. (A non-suspend re-watch of ext_fd itself just updated
			// this same queue slot, which the .done/.close arms below then pop.)
			detach_rejected_watch(mut reactor, epoll_fd, event_loop.last_watched, client_fd)
		}
		// Same slot discipline as on_watch_ready: drain per step, install on .done.
		qt := core.take_queued_takeover() or { core.QueuedTakeover{} }
		match pipelined_step {
			.done {
				// Pop BEFORE serving: serve_conn may read a request pipelined behind
				// this one and re-park the client on ext_fd (appended at the tail).
				// And if this pop DRAINED the queue, clear the slot BEFORE serving: a
				// re-park inside serve_conn must become a FRESH, live single watch —
				// the former trailing "queue empty ⇒ active=false" epilogue ran AFTER
				// that re-park had updated the stale head fields in place, deactivating
				// its watch and stranding the request forever (vanilla#100 hazard 1).
				reactor.watches[ext_fd].queue.delete(0)
				reactor.reactor_clear_if_drained(ext_fd)
				if qt.cont != unsafe { nil } {
					cs.takeover = qt.cont
					cs.takeover_state = qt.state
					if cs.write_buf.len > cs.write_off {
						if !flush_batch(epoll_fd, client_fd, limits, active_conns, mut st, mut cs) {
							continue
						}
					}
					serve_takeover_conn(mut reactor, epoll_fd, client_fd, limits, active_conns, mut
						st, mut cs, state)
					continue
				}
				serve_conn(h, mut reactor, epoll_fd, client_fd, limits, active_conns, mut st, mut
					cs, state)
			}
			.suspend {
				// Front query not ready yet. The continuation re-armed ext_fd in place
				// (reactor_watch found it already queued — no duplicate). Send anything it
				// streamed, keep it at the head, and stop: nothing behind it is ready.
				if cs.write_buf.len > cs.write_off {
					if !flush_batch(epoll_fd, client_fd, limits, active_conns, mut st, mut cs) {
						reactor.watches[ext_fd].queue.delete(0) // conn closed on write
						reactor.reactor_clear_if_drained(ext_fd)
						continue
					}
				}
				cs.awaiting_fd = ext_fd
				break
			}
			.close {
				reactor.watches[ext_fd].queue.delete(0)
				reactor.reactor_clear_if_drained(ext_fd)
				close_conn(epoll_fd, client_fd, active_conns, mut st)
			}
		}
	}
	// No trailing "queue empty ⇒ active=false" epilogue on purpose: deactivation
	// happens INLINE at each pop that drains the queue (reactor_clear_if_drained
	// above), always BEFORE a continuation/serve that could re-park on this same
	// fd. The fd itself stays in this worker's epoll (pool-owned); the next park
	// re-activates the slot. The drained queue's buffer is retained either way
	// (len 0 from the delete(0)s) — never reassigned, so the next pipeline cycle
	// refills it without reallocating (a fresh array per drain leaks under -gc none).
}

// close_client tears down a connection, first removing any watch it is parked on
// (which closes that request-owned fd, e.g. a timerfd) so nothing leaks.
@[direct_array_access; manualfree]
fn close_client(mut reactor Reactor, epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) {
	if fd < st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs != nil } && cs.awaiting_fd >= 0 {
			ext_fd := cs.awaiting_fd
			if ext_fd < reactor.watches.len && reactor.watches[ext_fd].queue.len > 0 {
				// The fd is a SHARED, pipelined pg connection: detaching this one client
				// must not clear the slot (siblings are still parked) nor close the pooled
				// connection. Tombstone this client's slot — it stays in the queue so the
				// connection's in-flight FIFO stays aligned and its result is consumed
				// (and discarded) in order by drain_pipelined.
				reactor.reactor_mark_dead(ext_fd, fd)
			} else if !reactor.reactor_orphan_single(ext_fd, fd) {
				// Request-owned fd (or an inactive watch): DEL + close it. A persistent,
				// pool-owned fd was tombstoned in place by reactor_orphan_single and is left
				// armed + open for reuse (closing it would force a reconnect + re-handshake).
				reactor.reactor_clear(ext_fd)
				epoll.remove_fd_from_epoll(epoll_fd, ext_fd) // DEL + close the ext fd
			}
		}
	}
	close_conn(epoll_fd, fd, active_conns, mut st)
}
