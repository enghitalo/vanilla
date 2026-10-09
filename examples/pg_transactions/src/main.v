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
// to, and submits the same batch again. Retries used up: 409. Pool busy: 503,
// a shed, not an error. Any other failure: 500.
//
// The next attempt runs at once, on the connection the request holds
// (acquire()), not after TxRetry.backoff_ms on a timerfd: the request learns of
// the conflict in a continuation parked on that pooled connection, and today's
// runtime only supports re-arming that same fd from there. A step to another
// fd is lost when the parked request is pipelined (acquire_pipelined) or its
// client disconnected meanwhile: the connection's park queue keeps the stale
// slot at its head, and the next reply on that connection runs the wrong
// continuation. Re-running on the held connection is right in every case: the
// failed batch left the session idle, and only this request uses it. (The batch
// itself would be safe pipelined: it has no BEGIN, so its Sync ends its
// transaction.) A transaction that needs a statement's result before the next
// one is BEGIN … COMMIT across park/resume instead, on acquire() too:
// release() rolls back a connection left in a transaction (pg_async/tx.v).
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

// policy: up to 5 runs of a transfer in all (its backoff fields are unused
// here: see above).
const policy = pg_async.TxRetry{
	max_attempts: 5
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

// TxState is one worker's make_state value: its pool, and the attempt number
// of the transfer holding each connection. The count lives here, per held
// connection, not in watch_payload: when the client of a parked request
// disconnects, the runtime still runs its continuation to drain the reply,
// and a re-arm from there keeps the payload of the first park.
struct TxState {
mut:
	pool     &pg_async.PgPool
	attempts []int
}

// build_state is make_state: this worker's pool, as the opaque worker state.
fn build_state() voidptr {
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
		pool:     pool
		attempts: []int{len: pool_size}
	})
}

fn handler(req []u8, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !starts_with(req, 'POST /transfer ') {
		core.append_str(mut out, resp_404)
		return .done
	}
	mut st := unsafe { &TxState(worker_state) }
	idx := st.pool.acquire() or {
		core.append_str(mut out, resp_503) // every connection is busy: shed
		return .done
	}
	st.attempts[idx] = 1
	return run_attempt(mut st, idx, mut out, mut event_loop)
}

// run_attempt submits the batch on connection idx (held: acquire()) and parks
// on it, the slot in watch_payload.
fn run_attempt(mut st TxState, idx int, mut out []u8, mut event_loop core.EventLoop) core.Step {
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
	event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, on_reply, voidptr(usize(idx)))
	return .suspend
}

fn on_reply(mut out []u8, ready_fd int, _ bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &TxState(worker_state) }
	idx := int(usize(watch_payload))
	mut conn := st.pool.conn(idx)
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	poll := conn.async_on_readable() or {
		if policy.retry(st.attempts[idx], err) {
			// A conflict: the batch did nothing. Run it again, whole, on the
			// same connection (see the top of the file for why not after a wait).
			st.attempts[idx]++
			return run_attempt(mut st, idx, mut out, mut event_loop)
		}
		st.pool.release(idx)
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
	answer_attempts(mut out, st.attempts[idx])
	return .done
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
