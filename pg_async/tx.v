module pg_async

import time

// Transactions (vanilla#199).
//
// Every async_submit carries its own Sync, so each query is its own implicit
// transaction. A transaction of several statements takes one of two shapes:
//
//   - A batch (async_submit_batch): N statements and ONE Sync, one implicit
//     transaction — atomic, one round trip, no BEGIN/COMMIT. It fits when no
//     statement needs another's result (an INSERT … RETURNING read by a later
//     statement does not fit). A batch is safe on a pipelined connection —
//     unless it contains a BEGIN: its transaction then outlives the Sync,
//     and the batch belongs on acquire() like the shape below.
//   - An explicit BEGIN … COMMIT across park/resume, on a connection taken
//     with acquire() — never acquire_pipelined(): the queries other requests
//     pipeline onto a shared connection would run inside the transaction, a
//     ROLLBACK would undo them, and after a failed statement every one of
//     them would fail with 25P02 until someone rolled back. acquire() holds
//     the connection exclusively until release(), and acquire_pipelined()
//     also skips any connection whose session is in a transaction.
//
// release() is safe on every path: a connection released while still in a
// transaction (a continuation that bailed out, an error path, a client that
// disconnected mid-transaction) gets a ROLLBACK, and is handed out again only
// once that ROLLBACK's ReadyForQuery reports it idle; if the ROLLBACK fails
// or gets no answer, the connection is re-dialed instead (PgPool.release).
//
// Under SERIALIZABLE, and always on Aurora DSQL (optimistic concurrency, no
// locks), a conflict fails the transaction with SQLSTATE 40001 — on DSQL
// usually at COMMIT, with OC000 (data conflict) or OC001 (schema conflict) in
// the message. The fix is to run the WHOLE transaction again: TxRetry decides
// whether to, and computes a randomized wait between attempts — never a
// sleep on the worker. A request learns of the conflict in a continuation
// parked on its pooled connection. Until vanilla#247 lands, that continuation
// cannot step to another fd (a timerfd for the wait) when the request is
// pipelined or its client disconnected meanwhile, and a disconnected client's
// re-arm keeps its first watch_payload: run the next attempt at once on the
// connection the request holds (acquire()), counting attempts outside
// watch_payload (examples/pg_transactions). Once #247 is in, backoff_ms can
// arm a timerfd the request parks on between attempts.
//
// Aurora DSQL's transaction limits, which a batch or a retried transaction
// must stay within (exceeding one is a clear error from the server, not
// worth retrying):
//   - at most 3,000 rows modified and 10 MiB of data written per transaction;
//   - at most 5 minutes per transaction;
//   - DDL and DML cannot be mixed in one transaction;
//   - one DDL statement per transaction.

// The transaction status byte of a ReadyForQuery (tx_status).
pub const tx_idle = u8(`I`) // not in a transaction block
pub const tx_in_block = u8(`T`) // in a transaction block (after BEGIN)
pub const tx_failed = u8(`E`) // in a failed transaction block: every statement fails (25P02) until ROLLBACK

// tx_status is the transaction status the server reported with the
// ReadyForQuery of the last query to complete: tx_idle, tx_in_block or
// tx_failed. While queries are in flight it describes the session before
// them.
pub fn (c &PgConn) tx_status() u8 {
	return c.ready_status
}

// in_transaction reports whether the session is inside a transaction block,
// failed or not (tx_status is not tx_idle).
pub fn (c &PgConn) in_transaction() bool {
	return c.ready_status != tx_idle
}

// sqlstate_serialization_failure is what a conflict between concurrent
// transactions fails with: serialization_failure under SERIALIZABLE (and
// REPEATABLE READ), and every optimistic-concurrency conflict on Aurora DSQL.
pub const sqlstate_serialization_failure = '40001'

// is_serialization_failure reports whether err is a serialization failure
// (PgError, SQLSTATE 40001): the transaction did nothing and running all of
// it again may succeed. Any other error is not retried.
pub fn is_serialization_failure(err IError) bool {
	if err is PgError {
		return err.sqlstate == sqlstate_serialization_failure
	}
	return false
}

// TxRetry is a retry policy for transactions that fail with a serialization
// failure: up to max_attempts runs in all, the first included, with a
// jittered exponential wait in between where the caller can wait. It is a
// value with no state of its own (the caller counts the attempts), and every
// method is allocation-free.
//
//   poll := conn.async_on_readable() or {
//       if policy.retry(st.attempts[idx], err) {
//           st.attempts[idx]++
//           // submit the whole transaction again on conn and re-arm the
//           // same fd (until vanilla#247: see above); afterwards, park on a
//           // timerfd armed for policy.backoff_ms(attempt) first
//       }
//       ...
//   }
pub struct TxRetry {
pub:
	max_attempts    int = 5
	base_backoff_ms int = 10
	max_backoff_ms  int = 500
}

// retry reports whether a transaction whose attempt number `attempt` (1 for
// the first run) failed with err should run again: err is a serialization
// failure and attempts are left.
pub fn (r TxRetry) retry(attempt int, err IError) bool {
	return attempt < r.max_attempts && is_serialization_failure(err)
}

// backoff_ms is how long to wait before running again a transaction whose
// attempt number `attempt` failed: uniform in [1, cap] ms ("full jitter"),
// where cap is base_backoff_ms doubled per attempt after the first, at most
// max_backoff_ms. The randomness spreads apart transactions that conflicted
// with each other, so they do not collide again; it comes from the monotonic
// clock, so it needs no state and no lock. Never 0, so it can arm a timerfd
// (where a 0 expiry disarms it) — from a continuation on a pooled connection
// once vanilla#247 lands (see the top of this file).
pub fn (r TxRetry) backoff_ms(attempt int) int {
	return r.backoff_from(attempt, time.sys_mono_now())
}

// backoff_from is backoff_ms with its random input given.
fn (r TxRetry) backoff_from(attempt int, seed u64) int {
	mut cap := i64(r.base_backoff_ms)
	for k := 1; k < attempt && cap < r.max_backoff_ms; k++ {
		cap *= 2
	}
	if cap > r.max_backoff_ms {
		cap = r.max_backoff_ms
	}
	if cap <= 1 {
		return 1
	}
	return 1 + int(mix64(seed) % u64(cap))
}

// mix64 is splitmix64's finalizer: every input bit moves every output bit, so
// clock readings a few ns apart give unrelated waits.
@[inline]
fn mix64(x u64) u64 {
	mut z := x + 0x9e37_79b9_7f4a_7c15
	z = (z ^ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ^ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ^ (z >> 31)
}
