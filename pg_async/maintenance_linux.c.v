module pg_async

import core

fn C.pg_async_timer_new() int
fn C.pg_async_timer_arm(fd int, ms int) int
fn C.read(fd int, buf voidptr, count usize) int

// start_maintenance drives maintain() from a timerfd on this worker's event
// loop: call it from on_worker_start (a clientless watch; Linux epoll), e.g.
//
//   fn on_start(worker_state voidptr, mut event_loop core.EventLoop) {
//       mut st := unsafe { &MyState(worker_state) }
//       st.pool.start_maintenance(mut event_loop) or { eprintln(err) }
//   }
//
// The timer re-arms itself with maintain()'s answer: every ~2 ms while a
// re-dial is in flight, the backoff while one waits, about once a second
// otherwise (idle probes). The pool must outlive the worker (new_pool's heap
// pool held in the worker state). close() stops it.
pub fn (mut p PgPool) start_maintenance(mut event_loop core.EventLoop) ! {
	if p.timer_fd >= 0 {
		return error('pg pool: maintenance is already running')
	}
	fd := C.pg_async_timer_new()
	if fd < 0 {
		return error('pg pool: timerfd_create failed (errno ${C.errno})')
	}
	C.pg_async_timer_arm(fd, idle_tick_ms)
	event_loop.watch_fd(fd, .readable, maintenance_tick, voidptr(p))
	if event_loop.last_watched != fd {
		C.close(fd)
		return error('pg pool: this event loop cannot watch the maintenance timer')
	}
	p.timer_fd = fd
	for mut c in p.conns {
		c.kick_fd = fd
	}
}

// kick_timer pulls a maintenance timer in to fire within a millisecond: a
// connection just broke and should be re-dialed now, not at the next idle
// tick. Once per break (PgConn.set_broken), never per query.
@[inline]
fn kick_timer(fd int) {
	C.pg_async_timer_arm(fd, 1)
}

// maintenance_tick is the timer's clientless continuation: run maintain(),
// re-arm the timer for when it next has work, keep watching.
fn maintenance_tick(mut _ []u8, ready_fd int, _ bool, watch_payload voidptr, _ voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { &PgPool(watch_payload) }
	mut expirations := u64(0)
	C.read(ready_fd, &expirations, 8)
	if p.closed {
		p.timer_fd = -1
		for mut c in p.conns {
			c.kick_fd = -1
		}
		return .done // the runtime closes the timerfd
	}
	C.pg_async_timer_arm(ready_fd, p.maintain())
	event_loop.watch_fd(ready_fd, .readable, maintenance_tick, watch_payload)
	return .suspend
}
