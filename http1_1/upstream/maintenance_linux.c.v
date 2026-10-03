module upstream

import core
import time

#include <sys/timerfd.h>
#include <time.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// start_maintenance drives maintain() from a one-shot timerfd on this worker's
// event loop, and, for a pool following a Resolver, watches the resolver's
// pipe. Call it from the server's on_worker_start with the pool make_state
// built (clientless watches: the epoll plain worker runs those):
//
//   fn on_start(ws voidptr, mut el core.EventLoop) {
//       mut st := unsafe { &App(ws) }
//       st.pay.start_maintenance(mut el) or { eprintln(err) }
//   }
//
// Without it, nothing enforces the deadlines and expiry: a silent upstream
// holds its exchange (and the client parked on it) for good.
pub fn (mut p Pool) start_maintenance(mut el core.EventLoop) ! {
	if p.timer_fd >= 0 {
		return error('upstream: maintenance is already running')
	}
	fd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	if fd < 0 {
		return error('upstream: timerfd_create failed (errno ${C.errno})')
	}
	el.watch_fd(fd, .readable, maintenance_tick, voidptr(p))
	if el.last_watched != fd {
		C.close(fd)
		return error('upstream: this event loop cannot watch the maintenance timer (epoll plain worker only)')
	}
	p.timer_fd = fd
	p.arm(maintenance_idle_ms)
	if p.feed_fd >= 0 {
		el.watch_fd(p.feed_fd, .readable, on_feed, voidptr(p))
		if el.last_watched != p.feed_fd {
			return error('upstream: this event loop cannot watch the resolver pipe')
		}
	}
}

// arm sets the one-shot timer `ms` milliseconds from now.
fn (mut p Pool) arm(ms int) {
	m := if ms < 1 { 1 } else { ms }
	mut spec := [4]i64{} // struct itimerspec: it_interval {sec, nsec}, it_value {sec, nsec}
	spec[2] = i64(m / 1000)
	spec[3] = i64(m % 1000) * 1_000_000
	C.timerfd_settime(p.timer_fd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	p.timer_due = time.sys_mono_now() + u64(m) * u64(time.millisecond)
}

// maintenance_tick is the timer's clientless continuation: run maintain(),
// re-arm for when it next has work, keep watching. After close() it returns
// .done, and the runtime closes the timerfd.
fn maintenance_tick(mut _ []u8, ready_fd int, _ bool, watch_payload voidptr, _ voidptr, mut el core.EventLoop) core.Step {
	mut p := unsafe { &Pool(watch_payload) }
	mut expirations := u64(0)
	C.read(ready_fd, &expirations, 8)
	if p.closed {
		p.timer_fd = -1
		return .done
	}
	p.timer_due = 0
	p.arm(p.maintain())
	el.watch_fd(ready_fd, .readable, maintenance_tick, watch_payload)
	return .suspend
}
