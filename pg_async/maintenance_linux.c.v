module pg_async

import core

#include <sys/timerfd.h>
#include <time.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// start_maintenance drives maintain() from a timerfd on this worker's event
// loop. Call it from the server's on_worker_start, with the pool the worker's
// make_state built (a clientless watch; the epoll plain worker runs those):
//
//   fn on_start(worker_state voidptr, mut event_loop core.EventLoop) {
//       mut pool := unsafe { &pg_async.PgPool(worker_state) }
//       pool.start_maintenance(mut event_loop) or { eprintln(err) }
//   }
//
// The timer re-arms itself with maintain()'s answer: every few ms while a
// re-dial is in flight, about once a second otherwise. The pool must outlive
// the worker (new_pool's heap pool held in the worker state); close() stops
// the timer at its next tick.
pub fn (mut p PgPool) start_maintenance(mut event_loop core.EventLoop) ! {
	if p.timer_fd >= 0 {
		return error('pg pool: maintenance is already running')
	}
	fd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	if fd < 0 {
		return error('pg pool: timerfd_create failed (errno ${C.errno})')
	}
	arm_timer(fd, maintenance_idle_ms)
	event_loop.watch_fd(fd, .readable, maintenance_tick, voidptr(p))
	if event_loop.last_watched != fd {
		C.close(fd)
		return error('pg pool: this event loop cannot watch the maintenance timer (epoll plain worker only)')
	}
	p.timer_fd = fd
}

// arm_timer arms a one-shot expiry `ms` milliseconds from now.
fn arm_timer(fd int, ms int) {
	mut spec := [4]i64{} // struct itimerspec: it_interval {sec, nsec}, it_value {sec, nsec}
	m := if ms < 1 { 1 } else { ms }
	spec[2] = i64(m / 1000)
	spec[3] = i64(m % 1000) * 1_000_000
	C.timerfd_settime(fd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
}

// maintenance_tick is the timer's clientless continuation: run maintain(),
// re-arm for when it next has work, keep watching. After close() it returns
// .done, and the runtime closes the timerfd.
fn maintenance_tick(mut _ []u8, ready_fd int, _ bool, watch_payload voidptr, _ voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { &PgPool(watch_payload) }
	mut expirations := u64(0)
	C.read(ready_fd, &expirations, 8)
	if p.closed {
		p.timer_fd = -1
		return .done
	}
	arm_timer(ready_fd, p.maintain())
	event_loop.watch_fd(ready_fd, .readable, maintenance_tick, watch_payload)
	return .suspend
}
