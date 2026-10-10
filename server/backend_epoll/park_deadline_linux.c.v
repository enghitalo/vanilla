module backend_epoll

// Park deadlines (vanilla#200): a request parked on a watch (.suspend) is
// bounded by its watch's deadline (watch_fd_deadline) or by
// Limits.park_timeout_ms. When it passes first, the continuation runs ONCE
// with event_loop.timed_out() true (on_park_timeout), so the app answers 504
// and cleans up, instead of the request and its client waiting as long as the
// fd does: a hung database or upstream, a pipe whose writer died.
//
// The read, write and idle deadlines live in the connections themselves and
// are swept; these do not, for two reasons. The sweep and its clock run only
// when a Limits timeout is set, and a per-watch deadline must hold with
// default Limits. And a scan per interval over every connection would be the
// cost of every park. So each worker keeps the armed deadlines in a binary
// min-heap (PlainState.timers, one entry per parked connection, its index in
// ConnState.park_timer): arming and cancelling (every park and every resume)
// are O(log n), the earliest deadline bounds the epoll_wait timeout, and a
// deadline fires within about a millisecond of its time. A worker with
// nothing armed pays one length check per loop iteration.
import core
import epoll
import sync.stdatomic
import time

// ParkTimer is one armed park deadline: when it passes, and whose park it is.
struct ParkTimer {
	at u64 // monotonic ns
	fd int // the parked client connection; its ConnState.park_timer is this entry's index
}

// arm_park_timer is park_conn's slow path: arm (or move) cs's park deadline,
// timeout_ms from now (0 = Limits.park_timeout_ms; < 0 = none). Reads the
// clock itself: the batch clock only runs while a Limits timeout or a
// deadline is armed.
@[direct_array_access; noinline]
fn (mut st PlainState) arm_park_timer(mut cs ConnState, fd int, timeout_ms int) {
	ns := if timeout_ms > 0 {
		u64(timeout_ms) * 1_000_000
	} else if timeout_ms == 0 {
		st.park_ns
	} else {
		u64(0)
	}
	if cs.park_timer >= 0 {
		st.cancel_park_timer(mut cs)
	}
	if ns == 0 {
		return
	}
	t := ParkTimer{
		at: time.sys_mono_now() + ns
		fd: fd
	}
	// Grows to the worker's high-water mark of parked requests, then reused
	// (len only shrinks): no allocation per park once warm.
	st.timers << t
	st.timer_up(st.timers.len - 1, t)
}

// cancel_park_timer drops cs's armed park deadline (unpark_conn).
@[inline]
fn (mut st PlainState) cancel_park_timer(mut cs ConnState) {
	i := cs.park_timer
	cs.park_timer = -1
	st.timer_remove(i)
}

// timer_remove takes entry i out of the heap: the last entry fills the hole
// and moves up or down to its place.
@[direct_array_access]
fn (mut st PlainState) timer_remove(i int) {
	last := st.timers[st.timers.len - 1]
	unsafe {
		st.timers.len = st.timers.len - 1
	}
	if i >= st.timers.len {
		return // it was the last entry
	}
	if i > 0 && last.at < st.timers[(i - 1) / 2].at {
		st.timer_up(i, last)
	} else {
		st.timer_down(i, last)
	}
}

// timer_up places t at slot i or above it (sift up).
@[direct_array_access]
fn (mut st PlainState) timer_up(start int, t ParkTimer) {
	mut i := start
	for i > 0 {
		p := (i - 1) / 2
		if st.timers[p].at <= t.at {
			break
		}
		st.timer_set(i, st.timers[p])
		i = p
	}
	st.timer_set(i, t)
}

// timer_down places t at slot i or below it (sift down).
@[direct_array_access]
fn (mut st PlainState) timer_down(start int, t ParkTimer) {
	n := st.timers.len
	mut i := start
	for {
		mut c := 2 * i + 1
		if c >= n {
			break
		}
		if c + 1 < n && st.timers[c + 1].at < st.timers[c].at {
			c++
		}
		if st.timers[c].at >= t.at {
			break
		}
		st.timer_set(i, st.timers[c])
		i = c
	}
	st.timer_set(i, t)
}

// timer_set stores t at slot i and tells its connection where it is. Every
// armed entry's connection exists: close_conn cancels the deadline (through
// unpark_conn) before it clears the slot.
@[direct_array_access; inline]
fn (mut st PlainState) timer_set(i int, t ParkTimer) {
	st.timers[i] = t
	st.conns[t.fd].park_timer = i
}

// park_wait_ms is how long the worker may block before the earliest park
// deadline is due: whole ms, rounded up, from a fresh clock (it runs only
// when the worker is about to block with a deadline armed).
@[direct_array_access]
fn (st &PlainState) park_wait_ms() int {
	now := time.sys_mono_now()
	at := st.timers[0].at
	if at <= now {
		return 0
	}
	return int((at - now) / 1_000_000) + 1
}

// fire_park_deadlines times out every park whose deadline passed by the batch
// clock, earliest first. A continuation that re-parks arms a deadline later
// than st.now, so the loop ends.
@[direct_array_access]
fn fire_park_deadlines(h core.Handler, mut reactor Reactor, epoll_fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, state voidptr) {
	for st.timers.len > 0 && st.timers[0].at <= st.now {
		fd := st.timers[0].fd
		mut cs := st.conns[fd]
		cs.park_timer = -1
		st.timer_remove(0)
		on_park_timeout(h, mut reactor, epoll_fd, fd, limits, counter, active_conns, mut st, mut
			cs, state)
	}
}

// on_park_timeout runs the continuation of connection fd's park, whose
// deadline passed, with the timeout reason (event_loop.timed_out()): the
// watched fd is not ready. What it returns is handled as for a readiness
// resume (resume_step). The watch it stops waiting on is retired first
// (retire_watch), so a readiness that comes later never runs it for this
// request again.
@[direct_array_access; manualfree]
fn on_park_timeout(h core.Handler, mut reactor Reactor, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState, mut cs ConnState, state voidptr) {
	// Held across the continuation, as by on_watch_ready: the park's own count
	// goes at the unpark below, and a .done response counts only while it is
	// written, so without it Server.shutdown() could see zero in between.
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}
	ext_fd := cs.awaiting_fd
	// The parked request: the fd's single watch, or this client's live slot in
	// its pipelined queue (not necessarily the head: each slot has its own
	// deadline).
	mut cont := core.WakeFn(unsafe { nil })
	mut udata := voidptr(unsafe { nil })
	if ext_fd >= 0 && ext_fd < reactor.watches.len && reactor.watches[ext_fd].active {
		if reactor.watches[ext_fd].queue.len == 0 {
			if reactor.watches[ext_fd].client_fd == fd {
				cont = reactor.watches[ext_fd].cont
				udata = reactor.watches[ext_fd].udata
			}
		} else {
			for i in 0 .. reactor.watches[ext_fd].queue.len {
				if !reactor.watches[ext_fd].queue[i].dead
					&& reactor.watches[ext_fd].queue[i].client_fd == fd {
					cont = reactor.watches[ext_fd].queue[i].cont
					udata = reactor.watches[ext_fd].queue[i].udata
					break
				}
			}
		}
	}
	if cont == unsafe { nil } {
		// A park always has its watch, so this does not happen; if it did,
		// nothing could ever resume the request: close it.
		close_client(mut reactor, epoll_fd, fd, active_conns, mut st)
		return
	}
	unpark_conn(mut st, mut cs)
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		reactor:   unsafe { voidptr(&reactor) }
		register:  register_watch
		reason:    .timeout
	}
	// The watch stays in place while the continuation runs, so a re-arm of the
	// same fd (keep waiting, with a new deadline) updates it in place.
	core.set_queue_file_allowed(false) // no file from a continuation (on_watch_ready)
	step := cont(mut cs.write_buf, ext_fd, false, udata, state, mut event_loop)
	core.set_queue_file_allowed(true)
	if step != .suspend || event_loop.last_watched != ext_fd {
		retire_watch(mut reactor, epoll_fd, ext_fd, fd)
	}
	resume_step(h, mut reactor, epoll_fd, ext_fd, fd, step, mut event_loop, limits, active_conns, mut
		st, mut cs, state)
}

// retire_watch takes connection fd's timed-out park off ext_fd once its
// continuation stopped waiting there:
//   - its own socket (parked on its writability): the watch goes and the
//     socket gets its connection registration back;
//   - a pipelined queue, or a caller-owned (persistent) single watch: the
//     reply still due belongs to this request, so its slot becomes a
//     tombstone, as on a client disconnect (close_client): drain_pipelined
//     runs the continuation against the scratch buffer when that reply
//     arrives, consuming it in order, and the fd stays open for reuse;
//   - a request-owned single watch: it is cleared and the fd taken out of the
//     epoll set (never closed: the continuation owns it, as on readiness), so
//     a late readiness wakes nothing.
fn retire_watch(mut reactor Reactor, epoll_fd int, ext_fd int, fd int) {
	if ext_fd < 0 || ext_fd >= reactor.watches.len || !reactor.watches[ext_fd].active {
		return
	}
	if reactor.watches[ext_fd].queue.len > 0 {
		reactor.reactor_mark_dead(ext_fd, fd)
		return
	}
	if reactor.watches[ext_fd].client_fd != fd {
		return // not this park's watch (the continuation armed another one on the number)
	}
	if ext_fd == fd {
		reactor.reactor_clear(ext_fd)
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN) | u32(C.EPOLLET))
		return
	}
	if !reactor.reactor_orphan_single(ext_fd, fd) {
		reactor.reactor_clear(ext_fd)
		epoll.detach_fd_from_epoll(epoll_fd, ext_fd)
	}
}
