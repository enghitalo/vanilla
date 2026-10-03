module upstream

import core

// start_maintenance needs a timerfd (Linux). Elsewhere call maintain() from
// your own timer: it enforces the deadlines and expiry.
pub fn (mut p Pool) start_maintenance(mut el core.EventLoop) ! {
	return error('upstream: start_maintenance is Linux-only; call maintain() periodically instead')
}

fn (mut p Pool) arm(ms int) {}
