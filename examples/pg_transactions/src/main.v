module main

// A PostgreSQL transaction from a handler, with pg_async (vanilla#199): atomic,
// one round trip, and run again when it conflicts with a concurrent one.
//
//   POST /transfer   moves 1 from account 1 to account 2: two UPDATEs sent as
//                    ONE batch (async_submit_batch: one Sync, so one implicit
//                    transaction — both happen or neither does), answered
//                    {"attempts":N}
//   anything else    404
//
// Under SERIALIZABLE, and always on Aurora DSQL (optimistic concurrency), a
// transaction that conflicts with a concurrent one fails with SQLSTATE 40001
// and must be run again, whole: the continuation asks pg_async.TxRetry whether
// to, waits, and submits the same batch again. Retries used up: 409. Pool
// busy: 503, a shed, not an error. Any other failure: 500.
//
// The wait is TxRetry.backoff_ms, jittered, on a timerfd (park_backoff), and
// the request spends it without a connection: on_reply releases the one it
// holds before parking on the timer, and on_backoff acquires one again when
// the timer fires. The jitter spreads apart transactions that collided, and
// meanwhile the connection serves other requests. The attempt number travels
// with the request, in watch_payload. A client that disconnects mid-transfer
// stops it: while it waits on the timer, the runtime closes the timer and
// drops the request; while its batch is in flight, the runtime still runs
// on_reply to drain the reply, and a conflict there releases the connection
// and steps to a timer that the runtime closes without resuming the request.
// (The batch itself would be safe pipelined too: it has no BEGIN, so its
// Sync ends its transaction.) A transaction that needs a statement's result
// before the next one is BEGIN … COMMIT across park/resume instead, on
// acquire(): release() rolls back a connection left in a transaction
// (pg_async/tx.v).
//
// Setup, then run with PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE set:
//   create table accounts (id int4 primary key, balance int4 not null check (balance >= 0));
//   insert into accounts values (1, 100), (2, 0);
//   alter database <db> set default_transaction_isolation = 'serializable'; -- optional
// The CHECK makes an overdraft fail the first UPDATE, and with it the batch:
// no money moves.
import os
import strconv
import server
import core
import pg_async

const pool_size = 4

// transfer is the whole transaction: built once, submitted as is on every
// attempt (no allocation per request).
const transfer = [
	pg_async.Stmt{
		sql: 'update accounts set balance = balance - 1 where id = 1'
	},
	pg_async.Stmt{
		sql: 'update accounts set balance = balance + 1 where id = 2'
	},
]

// policy: up to 5 runs of a transfer in all, with a wait before each rerun
// that starts at up to 10 ms and doubles, to at most 500 ms.
const policy = pg_async.TxRetry{
	max_attempts:    5
	base_backoff_ms: 10
	max_backoff_ms:  500
}

const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_409 = 'HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '

const resp_200_sep = '\r\nConnection: keep-alive\r\n\r\n'

const body_head = '{"attempts":'

fn env_or(name string, dflt string) string {
	v := os.getenv(name)
	return if v != '' { v } else { dflt }
}

// TxState is one worker's make_state value: its pool, its retry policy, and
// per connection the timer the request holding it waited on before its
// current attempt (-1 if none). What a request carries from one wait to the
// next, its attempt number, is in its watch_payload.
struct TxState {
mut:
	pool   &pg_async.PgPool
	policy pg_async.TxRetry
	timers []int
}

// build_state is make_state: this worker's pool, as the opaque worker state.
fn build_state() voidptr {
	return new_state(policy)
}

// new_state brings up this worker's pool, retrying conflicts as `p` says.
fn new_state(p pg_async.TxRetry) voidptr {
	port_env := os.getenv('PGPORT')
	cfg := pg_async.ConnConfig{
		host:     env_or('PGHOST', 'localhost')
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	pool := pg_async.new_pool(cfg, pool_size) or {
		panic('pg_transactions: pool bring-up failed: ${err}')
	}
	return voidptr(&TxState{
		pool:   pool
		policy: p
		timers: []int{len: pool_size, init: -1}
	})
}

fn handler(req []u8, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !starts_with(req, 'POST /transfer ') {
		core.append_str(mut out, resp_404)
		return .done
	}
	mut st := unsafe { &TxState(worker_state) }
	return run_attempt(mut st, 1, -1, mut out, mut event_loop)
}

// run_attempt runs attempt number `attempt`: it takes a connection
// (acquire(): the request's alone until release()), submits the batch on it
// and parks there. `timer` is the wait it comes from (-1 for the first
// attempt): when the attempt parks, its on_reply closes it.
fn run_attempt(mut st TxState, attempt int, timer int, mut out []u8, mut event_loop core.EventLoop) core.Step {
	idx := st.pool.acquire() or {
		core.append_str(mut out, resp_503) // every connection is busy: shed
		return .done
	}
	mut conn := st.pool.conn(idx)
	submitted := conn.async_submit_batch(transfer) or {
		// Empty, or larger than the send buffer: no connection will ever take
		// it. A bug, not load.
		st.pool.release(idx)
		core.append_str(mut out, resp_500)
		return .done
	}
	if !submitted {
		st.pool.release(idx)
		core.append_str(mut out, resp_503) // the connection broke meanwhile: shed
		return .done
	}
	// From here the batch is in the connection's in-flight FIFO: park for its
	// outcome whatever the flush did (a partial flush finishes in on_reply).
	conn.async_flush() or {}
	st.timers[idx] = timer
	event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, on_reply, parked(idx, attempt))
	return .suspend
}

// parked is the watch_payload of a request parked on its connection: the
// connection's index and the attempt number, packed into the pointer (no
// allocation).
@[inline]
fn parked(idx int, attempt int) voidptr {
	return voidptr((u64(attempt) << 16) | u64(idx))
}

fn on_reply(mut out []u8, ready_fd int, _ bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &TxState(worker_state) }
	idx := int(u64(watch_payload) & 0xffff)
	attempt := int(u64(watch_payload) >> 16)
	if st.timers[idx] >= 0 {
		// The timer this attempt waited on: on_backoff stepped away from it,
		// and the runtime has taken it out of the event loop since.
		os.fd_close(st.timers[idx])
		st.timers[idx] = -1
	}
	mut conn := st.pool.conn(idx)
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	poll := conn.async_on_readable() or {
		// Released on every path, and before the step to the timer: when the
		// client is gone the request is never resumed after it.
		st.pool.release(idx)
		if st.policy.retry(attempt, err) {
			// A conflict: the batch did nothing. Wait, then run it again, whole
			// (on_backoff: the next attempt's number is its payload).
			next := voidptr(u64(attempt + 1))
			if st.policy.park_backoff(attempt, mut event_loop, on_backoff, next) {
				return .suspend
			}
			return run_attempt(mut st, attempt + 1, -1, mut out, mut event_loop) // no timerfd here: at once
		}
		core.append_str(mut out, if pg_async.is_serialization_failure(err) {
			resp_409
		} else {
			resp_500
		})
		return .done
	}
	if !poll.ready {
		// Not all here yet. A broken connection never reports not-ready, so
		// this cannot spin on a dead socket.
		event_loop.watch_fd_persistent(ready_fd, .readable, on_reply, watch_payload)
		return .suspend
	}
	st.pool.release(idx)
	answer_attempts(mut out, attempt)
	return .done
}

// on_backoff runs when the wait before attempt number `watch_payload` is
// over, and runs it. The timer (ready_fd) is the request's. Once the attempt
// parks on a connection, its on_reply closes the timer, after the runtime has
// taken it out of the event loop. Closing it here would be correct too: before
// it detaches a stepped-away fd, the runtime checks that the number is still
// an app's open fd and not a connection accepted on it (vanilla#337). Closing
// it later keeps the number the timer's until that detach, so the check has
// nothing to tell apart.
fn on_backoff(mut out []u8, ready_fd int, _ bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &TxState(worker_state) }
	step := run_attempt(mut st, int(u64(watch_payload)), ready_fd, mut out, mut event_loop)
	if step != .suspend {
		os.fd_close(ready_fd) // answered without a watch: nothing steps away from it
	}
	return step
}

// answer_attempts appends 200 {"attempts":N}: parts appended straight into
// out, no allocation.
fn answer_attempts(mut out []u8, attempts int) {
	mut digits := [12]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	n := strconv.write_dec(attempts, mut view)
	mut len_digits := [12]u8{}
	mut len_view := unsafe { (&len_digits[0]).vbytes(len_digits.len) }
	ln := strconv.write_dec(body_head.len + n + 1, mut len_view)
	core.append_str(mut out, resp_200_head)
	unsafe { out.push_many(&len_digits[0], ln) }
	core.append_str(mut out, resp_200_sep)
	core.append_str(mut out, body_head)
	unsafe { out.push_many(&digits[0], n) }
	out << `}`
}

// starts_with reports whether the request begins with `prefix`, compared in
// place.
fn starts_with(req []u8, prefix string) bool {
	return req.len >= prefix.len && unsafe { vmemcmp(req.data, prefix.str, prefix.len) } == 0
}

fn main() {
	mut s := server.new_server(server.ServerConfig{
		port:       8099
		handler:    handler
		make_state: build_state
	})!
	println('pg_transactions listening on http://localhost:8099/ (POST /transfer)')
	s.run()
}
