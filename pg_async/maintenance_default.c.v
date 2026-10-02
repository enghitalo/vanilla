module pg_async

import core

// start_maintenance needs a timerfd and the epoll backend's clientless
// watches (Linux). Elsewhere, call maintain() yourself — from a handler is
// fine: it does nothing costly unless a re-dial or a probe is due.
pub fn (mut p PgPool) start_maintenance(mut event_loop core.EventLoop) ! {
	return error('pg pool: start_maintenance needs Linux (timerfd); call maintain() periodically instead')
}

// kick_timer: without a maintenance timer there is nothing to pull in.
@[inline]
fn kick_timer(fd int) {}
