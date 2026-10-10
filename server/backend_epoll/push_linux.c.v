module backend_epoll

// Subscriptions on the epoll plain worker (vanilla#230): a taken-over
// connection registers a wake fn (core.EventLoop.subscribe) that this worker
// calls between client bursts for every event that is not a client byte —
// a post from any thread through the worker's mailbox (mailbox_linux.c.v),
// its wake_after timer (the park-deadline heap, timer_wake), the server's
// shutdown, and, last, its close. The connection stays in takeover mode the
// whole time: it keeps reading client frames, it is not parked (it holds no
// in-flight count, so Server.shutdown(grace) does not wait for it), and the
// wake fn runs on the same thread as its ConnHandler, never at the same time.
//
// A ConnHandle carries the fd and the worker's close stamp for it
// (PlainState.closed_at, the generation every close of the number moves), so
// a post for a connection that is gone, its number maybe reused, is dropped
// here and counted (Mailbox.stale), never delivered to the new owner.
import core
import sync.stdatomic

// push_default_watermark bounds what a pushed connection may have pending
// (ServerConfig.push_watermark_bytes, 0 = this): a wake fn that leaves more
// unsent closes it. A subscriber that stops reading would otherwise grow its
// write buffer without bound — no write timeout is armed by default.
const push_default_watermark = 1024 * 1024

// ClosedNote is a .closed notification due: the subscription that ended.
struct ClosedNote {
	wake_fn   core.WakeFn = unsafe { nil }
	sub_state voidptr
}

// conn_loop is the EventLoop a handler, ConnHandler, continuation or wake fn
// of connection fd runs with.
@[inline]
fn conn_loop(mut reactor Reactor, epoll_fd int, fd int) core.EventLoop {
	return core.EventLoop{
		client_fd:       fd
		loop_fd:         epoll_fd
		reactor:         unsafe { voidptr(&reactor) }
		register:        register_watch
		subscribe_hook:  subscribe_conn
		wake_after_hook: wake_after_conn
	}
}

// stamp_of is fd's close stamp: the generation a ConnHandle records.
@[direct_array_access; inline]
fn (st &PlainState) stamp_of(fd int) u64 {
	return if fd < st.closed_at.len { st.closed_at[fd] } else { u64(0) }
}

// subscribe_conn is core.EventLoop.subscribe on this worker (subscribe_hook).
fn subscribe_conn(mut el core.EventLoop, wake_fn core.WakeFn, sub_state voidptr) core.ConnHandle {
	mut r := unsafe { &Reactor(el.reactor) }
	fd := el.client_fd
	if r.st == unsafe { nil } || fd < 0 || fd >= r.st.conns.len {
		return core.ConnHandle{}
	}
	mut st := r.st
	mut cs := st.conns[fd]
	if unsafe { cs == nil } {
		return core.ConnHandle{}
	}
	// Only a taken-over connection, or one whose handler has just queued its
	// takeover: an HTTP/1.1 connection's byte stream belongs to its responses.
	if cs.takeover == unsafe { nil } && !core.takeover_pending() {
		return core.ConnHandle{}
	}
	if st.closed_q.cap == 0 {
		st.closed_q = []ClosedNote{cap: 64} // once per worker; reused by every close
	}
	cs.wake_fn = wake_fn
	cs.sub_state = sub_state
	return core.ConnHandle{
		post:  if st.mbox != unsafe { nil } { mailbox_post } else { unsafe { nil } }
		mbox:  voidptr(st.mbox)
		fd:    fd
		epoch: st.stamp_of(fd)
	}
}

// wake_after_conn is core.EventLoop.wake_after on this worker.
fn wake_after_conn(mut el core.EventLoop, ms int) bool {
	mut r := unsafe { &Reactor(el.reactor) }
	fd := el.client_fd
	if r.st == unsafe { nil } || fd < 0 || fd >= r.st.conns.len {
		return false
	}
	mut st := r.st
	mut cs := st.conns[fd]
	if unsafe { cs == nil } || cs.wake_fn == unsafe { nil } {
		return false
	}
	if ms <= 0 {
		if cs.wake_timer >= 0 {
			st.cancel_wake_timer(mut cs)
		}
		return true
	}
	st.arm_wake_timer(mut cs, fd, ms)
	return true
}

// deliver_wake runs connection fd's wake fn for `reason` (.posted with the
// post's tag and data view, .timeout, .shutdown) and carries out its step:
//   .close  — what it appended goes out, then the connection closes
//             (flush_then_close, as for any other .close);
//   else    — over the push watermark the connection is closed (a subscriber
//             that does not read); otherwise what was appended is flushed,
//             unless a flush is already parked on EPOLLOUT, which sends it.
// Skipped (false) for a connection that is closing (close_after_flush) or not
// taken over (a subscription whose takeover never happened).
fn deliver_wake(mut reactor Reactor, epoll_fd int, fd int, reason core.WakeReason, tag u64, data voidptr, data_len int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) bool {
	if cs.wake_fn == unsafe { nil } || cs.takeover == unsafe { nil } || cs.close_after_flush {
		return false
	}
	stdatomic.add_i64(&counter.n, 1) // running app code counts as in flight
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}
	parked_flush := cs.write_off < cs.write_buf.len
	mut el := conn_loop(mut reactor, epoll_fd, fd)
	el.reason = reason
	el.post_tag = tag
	el.post_ptr = data
	el.post_len = data_len
	core.set_queue_file_allowed(false) // no file from a wake fn: it writes its bytes
	step := cs.wake_fn(mut cs.write_buf, fd, false, cs.sub_state, state, mut el)
	core.set_queue_file_allowed(true)
	if el.last_watched >= 0 && el.last_watched != cs.awaiting_fd {
		// A wake fn does not park: tear down a watch it armed.
		detach_rejected_watch(mut reactor, epoll_fd, el.last_watched, fd)
	}
	if _ := core.take_queued_takeover() {
	}
	if step == .close {
		flush_then_close(epoll_fd, fd, limits, active_conns, mut st, mut cs)
		return true
	}
	if cs.write_buf.len - cs.write_off > st.push_watermark {
		close_conn(epoll_fd, fd, active_conns, mut st) // not reading: no point flushing
		return true
	}
	if !parked_flush && cs.write_off < cs.write_buf.len {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
	return true
}

// drain_mailbox delivers up to mailbox_drain_max posts, in order. A post goes
// to its connection only if that is still the connection the handle was taken
// for (same close stamp), still subscribed and not closing; otherwise it is
// dropped and counted as stale. Each slot is freed after its delivery: the
// wake fn's post_data() is a view into it.
@[direct_array_access]
fn drain_mailbox(mut reactor Reactor, epoll_fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	mut m := st.mbox
	for n := 0; n < mailbox_drain_max && m.ready(); n++ {
		pos := m.head
		mut slot := unsafe { &m.slots[int(pos & m.mask)] }
		fd := slot.fd
		mut delivered := false
		if fd >= 0 && fd < st.conns.len && st.stamp_of(fd) == slot.epoch {
			mut cs := st.conns[fd]
			if unsafe { cs != nil } {
				delivered = deliver_wake(mut reactor, epoll_fd, fd, .posted, slot.tag, unsafe { &slot.data[0] },
					slot.len, limits, counter, active_conns, mut st, mut cs, state)
			}
		}
		stdatomic.add_u64(if delivered { &m.delivered } else { &m.stale }, 1)
		stdatomic.store_u64(&slot.seq, pos + m.mask + 1) // free the slot for the next lap
		m.head = pos + 1
	}
}

// on_mailbox_wake handles the mailbox eventfd's event: reset it (the drain at
// the top of every loop iteration takes the posts), and deliver .shutdown
// once Server.shutdown() has signalled.
fn on_mailbox_wake(mut reactor Reactor, epoll_fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	mut n := u64(0)
	C.read(st.mbox.wake_fd, &n, 8)
	if !st.shutdown_seen && stdatomic.load_u64(&st.mbox.shutdown) != 0 {
		st.shutdown_seen = true
		deliver_shutdown(mut reactor, epoll_fd, limits, counter, active_conns, mut st, state)
		stdatomic.add_i64(&counter.n, -1) // mailbox_signal_shutdown's count
	}
}

// deliver_shutdown wakes every subscribed connection with .shutdown, so it
// can say goodbye (a WebSocket close 1001) before the process exits.
@[direct_array_access]
fn deliver_shutdown(mut reactor Reactor, epoll_fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	for fd in 0 .. st.conns.len {
		mut cs := st.conns[fd]
		if unsafe { cs != nil } && cs.wake_fn != unsafe { nil } {
			deliver_wake(mut reactor, epoll_fd, fd, .shutdown, 0, unsafe { nil }, 0, limits,
				counter, active_conns, mut st, mut cs, state)
		}
	}
}

// queue_closed ends cs's subscription as its connection closes (close_conn):
// its wake fn gets .closed at the end of this loop iteration (notify_closed),
// and its timer goes. Into a queue that is reused, so a close allocates
// nothing once it has grown to the most closes one iteration has seen.
@[inline]
fn (mut st PlainState) queue_closed(mut cs ConnState) {
	if cs.wake_timer >= 0 {
		st.cancel_wake_timer(mut cs)
	}
	st.closed_q << ClosedNote{
		wake_fn:   cs.wake_fn
		sub_state: cs.sub_state
	}
	cs.wake_fn = unsafe { nil }
	cs.sub_state = unsafe { nil }
}

// notify_closed runs the .closed notifications queued this iteration, after
// every close of it: each wake fn exactly once, with a scratch response, no
// connection (ready_fd -1) and no watches. Called before the worker waits
// again.
@[direct_array_access]
fn notify_closed(mut reactor Reactor, epoll_fd int, mut st PlainState, state voidptr) {
	for i := 0; i < st.closed_q.len; i++ {
		note := st.closed_q[i]
		unsafe {
			reactor.scratch.len = 0
		}
		mut el := core.EventLoop{
			loop_fd:  epoll_fd
			reactor:  unsafe { voidptr(&reactor) }
			register: core.reject_register
			reason:   .closed
		}
		core.set_queue_file_allowed(false)
		note.wake_fn(mut reactor.scratch, -1, false, note.sub_state, state, mut el)
		core.set_queue_file_allowed(true)
		if _ := core.take_queued_takeover() {
		}
	}
	unsafe {
		st.closed_q.len = 0
	}
}

// discard_while_closing reads and drops what a closing connection
// (close_after_flush: its last bytes still going out) receives: nothing more
// reaches its handler or ConnHandler, and unread bytes would turn the close
// into a reset that can cut those last bytes off. Closes on error, and on EOF
// once nothing is left to send: a peer that half-closed still reads (RFC 9112
// §9.6), so with bytes owed handle_writable_plain sends them, then closes.
@[noinline]
fn discard_while_closing(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState, mut cs ConnState) {
	unsafe {
		cs.read_buf.len = 0
	}
	for {
		n := C.recv(fd, cs.read_buf.data, usize(cs.read_buf.cap), 0)
		if n > 0 {
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		if n == 0 && (cs.write_off < cs.write_buf.len || cs.file_remaining > 0) {
			return
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return
	}
}
