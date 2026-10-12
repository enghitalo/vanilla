module pg_async

import core

// start_maintenance needs a timerfd (Linux). Elsewhere call maintain() from
// your own timer, or rely on acquire(), which advances re-dials itself.
pub fn (mut p PgPool) start_maintenance(mut event_loop core.EventLoop) ! {
	return error('pg pool: start_maintenance is Linux-only; call maintain() periodically instead')
}

// one_shot_timer needs a timerfd (Linux): none here, so
// TxRetry.park_backoff arms nothing.
fn one_shot_timer(_ int) int {
	return -1
}
