module upstream

import time

// Pool maintenance, off the request path: deadlines, idle and lifetime
// expiry, and the liveness probe of kept connections.
//
// Deadlines: maintain() enforces each exchange's own, connect_timeout_ms for
// the connect and the TLS handshake, then response_timeout_ms. It shuts the
// socket of an exchange past its deadline down (expire(): shutdown(2),
// SHUT_RDWR), the watch parked on it fires as a hangup, and advance() answers
// .failed with .timeout. The connection is closed at release, after that
// run, so a late reply can never reach another exchange. The timer is
// re-armed for the next thing due, so a deadline is kept to within a
// millisecond or so, not to a tick.
//
// The runtime's deadlines (#200) cannot take this over: the epoll worker
// gives a tombstone (an exchange whose client left) and a clientless watch
// (examples/logging's shipper) none, and those exchanges must end on time
// too, or a silent upstream holds their slot for good. A parked request's
// watch has one more deadline, the runtime's Limits.park_timeout_ms, armed
// afresh at each park: it bounds each wait (the connect, a TLS flight, a full
// socket, the response), not the whole exchange. When it passes first, the
// continuation runs with event_loop.timed_out(), and advance() ends the
// exchange the same way: expire(), then it watches the socket again, for the
// hangup. When both pass together, this timer's event comes first in the
// loop iteration and the timed-out run finds the exchange expired: it only
// watches the socket again. That run never answers itself: a watch it left
// would turn into a tombstone on the fd release() closes (#342). Either way
// the app sees .failed with .timeout once, from the hangup's run, and the fd
// is closed once no watch is left on it.

// maintenance_idle_ms is the tick when nothing is due sooner: how long a kept
// connection the upstream closed can sit unnoticed by the pool (acquire()
// probes it anyway before reusing it).
const maintenance_idle_ms = 1000

// maintain enforces deadlines and expiry on every slot, closes what must be
// closed, and returns how soon (ms) it wants to run again. Never blocks.
pub fn (mut p Pool) maintain() int {
	now := time.sys_mono_now()
	mut next := u64(maintenance_idle_ms) * u64(time.millisecond)
	idle := ms_ns(p.origin.idle_timeout_ms)
	life := ms_ns(p.origin.max_lifetime_ms)
	for mut x in p.slots {
		if x.busy {
			if x.deadline == 0 || x.timed_out || x.fd < 0 || x.phase == .idle
				|| x.phase == .ready || x.phase == .failed {
				continue // not in flight
			}
			if now >= x.deadline {
				x.expire() // the parked watch wakes; advance() reports .timeout
			} else if x.deadline - now < next {
				next = x.deadline - now
			}
			continue
		}
		if x.fd < 0 {
			continue
		}
		if now - x.idle_since >= idle || now - x.born >= life || !x.idle_alive() {
			x.drop_conn()
			continue
		}
		due := min_u64(x.idle_since + idle, x.born + life) - now
		if due < next {
			next = due
		}
	}
	return int(next / u64(time.millisecond)) + 1
}

// due moves the maintenance timer up to `deadline` when it is armed for later
// (a new exchange with a deadline shorter than the next tick). One syscall,
// only then.
fn (mut p Pool) due(deadline u64) {
	if deadline == 0 || p.timer_fd < 0 || (p.timer_due != 0 && deadline >= p.timer_due) {
		return
	}
	now := time.sys_mono_now()
	ms := if deadline > now { int((deadline - now) / u64(time.millisecond)) + 1 } else { 1 }
	p.arm(ms)
}

@[inline]
fn min_u64(a u64, b u64) u64 {
	return if a < b { a } else { b }
}
