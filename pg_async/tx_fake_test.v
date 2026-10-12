// vtest build: !windows
module pg_async

import core
import os
import time
import testkit

// Transactions against the fake server (pg_async/testdata/fake_pg.py, which
// tracks the transaction status like PostgreSQL and answers a batch's
// statements at its one Sync): the status byte, the pool keeping sessions in
// a transaction to themselves, the ROLLBACK at release, batches, and a
// conflict retried with TxRetry, after a wait on a timerfd (park_backoff).
// Skipped without python3 unless VANILLA_REQUIRE_FAKE_PG is set.

fn tx_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// run_poll flushes, then pumps readable until the front query (or batch)
// completes or fails.
fn run_poll(mut c PgConn) !Result {
	for _ in 0 .. 10000 {
		if c.async_flush()! {
			break
		}
	}
	for _ in 0 .. 2_000_000 {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
	}
	return error('query did not complete')
}

fn run_sql(mut c PgConn, query string) !Result {
	assert c.async_submit(query, []?[]u8{})
	return run_poll(mut c)
}

// acquire_within polls acquire() for up to 3 s (a release-time ROLLBACK or a
// re-dial completes on its own between calls).
fn acquire_within(mut pool PgPool) ?int {
	for _ in 0 .. 3000 {
		if i := pool.acquire() {
			return i
		}
		time.sleep(time.millisecond)
	}
	return none
}

fn test_fake_status_follows_begin_failure_and_rollback() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping fake transaction tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(tx_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	assert c.tx_status() == tx_idle
	run_sql(mut c, 'begin')!
	assert c.tx_status() == tx_in_block
	run_sql(mut c, 'select 1')!
	assert c.tx_status() == tx_in_block
	if _ := run_sql(mut c, 'select 1/0') {
		assert false, 'division by zero'
	}
	assert c.tx_status() == tx_failed
	if _ := run_sql(mut c, 'select 2') {
		assert false, 'a failed transaction block refuses every statement'
	} else {
		if err is PgError {
			assert err.sqlstate == '25P02'
		}
	}
	run_sql(mut c, 'rollback')!
	assert c.tx_status() == tx_idle
	// The blocking query() tracks it too (on a connection of its own: it does
	// not share the async path's receive cursor).
	mut b := PgConn.connect(tx_cfg(fake.port))!
	defer {
		b.close()
	}
	b.query('begin', []?[]u8{})!
	assert b.in_transaction()
	b.query('commit', []?[]u8{})!
	assert !b.in_transaction()
}

// BEGIN on a connection taken with acquire(): acquire_pipelined() never
// returns it until the transaction ends; COMMIT then release() needs no
// ROLLBACK.
fn test_fake_pipelined_never_shares_a_transaction() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(tx_cfg(fake.port), 2)!
	defer {
		pool.close()
	}
	i := pool.acquire() or { panic('free') }
	mut c := pool.conn(i)
	run_sql(mut c, 'begin')!
	for _ in 0 .. 4 {
		j := pool.acquire_pipelined() or { panic('the other connection is free') }
		assert j != i
		mut cj := pool.conn(j)
		res := run_sql(mut cj, 'select 3')!
		mut it := res.rows()
		assert (it.next() or { panic('row') }).int4(0)! == 3
	}
	run_sql(mut c, 'commit')!
	pool.release(i)
	assert pool.idle[i]
	assert fake.stat('rollbacks') == 0
}

// A BEGIN sent through acquire_pipelined() (what the docs forbid) leaves an
// unheld connection in a transaction, which both acquire paths skip and
// nobody will release: maintain() rolls it back, and the slot comes back.
fn test_fake_maintain_rolls_back_an_unheld_transaction() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(tx_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	j := pool.acquire_pipelined() or { panic('free') }
	mut c := pool.conn(j)
	run_sql(mut c, 'begin')!
	assert c.in_transaction()
	assert pool.idle[j], 'nobody holds a pipelined connection'
	if k := pool.acquire_pipelined() {
		assert false, 'acquire_pipelined() shared a session in a transaction (${k})'
	}
	if k := pool.acquire() {
		assert false, 'acquire() took a session in a transaction (${k})'
	}
	assert pool.maintain() == maintenance_busy_ms, 'a ROLLBACK started: fast tick'
	for _ in 0 .. 2000 {
		if pool.idle[j] && pool.conns[j].rollback_deadline == 0 {
			break
		}
		pool.maintain()
		time.sleep(time.millisecond)
	}
	assert pool.idle[j]
	assert pool.conns[j].tx_status() == tx_idle
	assert !pool.conns[j].is_broken()
	assert fake.stat('rollbacks') == 1
	assert fake.stat('authenticated') == 1, 'rolled back, not re-dialed'
	assert pool.maintain() == maintenance_idle_ms
	k := pool.acquire_pipelined() or { panic('the slot did not come back') }
	assert k == j
}

fn test_fake_release_rolls_back_before_reuse() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(tx_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	i := pool.acquire() or { panic('free') }
	mut c := pool.conn(i)
	run_sql(mut c, 'begin')!
	pool.release(i) // a borrower that bails out mid-transaction
	j := acquire_within(mut pool) or { panic('the rolled-back connection never came back') }
	assert j == i
	assert fake.stat('rollbacks') == 1
	assert !pool.conns[j].in_transaction()
	assert !pool.conns[j].is_broken()
	assert fake.stat('authenticated') == 1, 'rolled back, not re-dialed'
	res := run_sql(mut c, 'select 4')!
	mut it := res.rows()
	assert (it.next() or { panic('row') }).int4(0)! == 4
	pool.release(j)
}

// Until the ROLLBACK's ReadyForQuery arrives the connection is nobody's; when
// it never arrives, the connection is re-dialed.
fn test_fake_unanswered_rollback_is_never_handed_out() {
	if !testkit.fake_pg_available() {
		return
	}
	// Each connection's 2nd query (the ROLLBACK) is never answered.
	mut fake := testkit.start_fake_pg(['--hang-after', '2'])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(tx_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	i := pool.acquire() or { panic('free') }
	mut c := pool.conn(i)
	run_sql(mut c, 'begin')!
	pool.release(i)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 300 {
		if j := pool.acquire() {
			assert false, 'acquire() handed out ${j} mid-ROLLBACK'
		}
		if j := pool.acquire_pipelined() {
			assert false, 'acquire_pipelined() handed out ${j} mid-ROLLBACK'
		}
		assert pool.maintain() == maintenance_busy_ms
		time.sleep(5 * time.millisecond)
	}
	assert fake.stat('queries') == 2, 'the ROLLBACK reached the server'
	pool.conns[i].rollback_deadline = 1 // rollback_timeout is up
	j := acquire_within(mut pool) or { panic('the slot was not re-dialed') }
	assert j == i
	assert fake.stat('authenticated') == 2, 're-dialed'
	assert !pool.conns[j].in_transaction()
	res := run_sql(mut c, 'select 6')!
	mut it := res.rows()
	assert (it.next() or { panic('row') }).int4(0)! == 6
	pool.release(j)
}

fn test_fake_server_gone_mid_transaction() {
	if !testkit.fake_pg_available() {
		return
	}
	// Every connection is closed 50 ms after its first reply, unanswered.
	mut fake := testkit.start_fake_pg(['--close', 'delayed', '--close-after', '1'])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(tx_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	i := pool.acquire() or { panic('free') }
	mut c := pool.conn(i)
	run_sql(mut c, 'begin')!
	pool.release(i) // queues a ROLLBACK the server never answers: it closes
	j := acquire_within(mut pool) or { panic('the slot was not re-dialed') }
	assert j == i
	assert fake.stat('rollbacks') == 0
	assert fake.stat('authenticated') == 2, 're-dialed'
	assert !pool.conns[j].in_transaction()
	pool.release(j)
}

fn test_fake_batch_is_one_sync() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(tx_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	q0, s0 := fake.stat('queries'), fake.stat('statements')
	assert c.async_submit_batch([
		Stmt{
			sql: 'select 1'
		},
		Stmt{
			sql:    r'select $1::int4'
			params: [?[]u8('2'.bytes())]
		},
		Stmt{
			sql: 'insert into t values (3)'
		},
	])!
	res := run_poll(mut c)!
	assert fake.stat('queries') == q0 + 1, 'one Sync'
	assert fake.stat('statements') == s0 + 3
	for k in 0 .. 2 {
		mut it := res.statement(k)!.rows()
		assert (it.next() or { panic('row') }).int4(0)! == k + 1
	}
	assert res.statement(2)!.rows_affected == 1
	assert !c.in_transaction()

	// A failing statement: its index; the rest is skipped; the connection is fine.
	q1 := fake.stat('queries')
	assert c.async_submit_batch([Stmt{
		sql: 'select 1'
	}, Stmt{
		sql: 'select 1/0'
	}, Stmt{
		sql: 'select 3'
	}])!
	if _ := run_poll(mut c) {
		assert false, 'the batch must fail'
	} else {
		assert err is PgError
		if err is PgError {
			assert err.sqlstate == '22012'
			assert err.statement == 1
		}
	}
	assert fake.stat('queries') == q1 + 1
	assert !c.in_transaction()

	// Pipelined between single queries: replies stay in order.
	assert c.async_submit('select 10', []?[]u8{})
	assert c.async_submit_batch([Stmt{
		sql: 'select 20'
	}, Stmt{
		sql: 'select 21'
	}])!
	assert c.async_submit('select 30', []?[]u8{})
	assert c.inflight_count() == 3
	r1 := run_poll(mut c)!
	r2 := run_poll(mut c)!
	r3 := run_poll(mut c)!
	mut i1 := r1.rows()
	assert (i1.next() or { panic('row') }).int4(0)! == 10
	mut i2 := r2.statement(1)!.rows()
	assert (i2.next() or { panic('row') }).int4(0)! == 21
	mut i3 := r3.rows()
	assert (i3.next() or { panic('row') }).int4(0)! == 30
}

// A batch that fails with 40001 is run again, whole, until it commits:
// TxRetry decides and spaces the attempts.
fn test_fake_batch_retried_on_serialization_failure() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--conflicts', '2'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(tx_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	transfer := [
		Stmt{
			sql: 'update accounts set balance = balance - 1 where id = 1'
		},
		Stmt{
			sql: 'update accounts set balance = balance + 1 where id = 2'
		},
	]
	policy := TxRetry{
		base_backoff_ms: 1
		max_backoff_ms:  5
	}
	mut attempt := 1
	for {
		assert c.async_submit_batch(transfer)!
		res := run_poll(mut c) or {
			assert err is PgError
			if err is PgError {
				assert err.statement == 0
			}
			if policy.retry(attempt, err) {
				time.sleep(i64(policy.backoff_ms(attempt)) * time.millisecond) // a test, not a worker
				attempt++
				continue
			}
			panic('gave up: ${err}')
		}
		assert res.statement(1)!.rows_affected == 1
		break
	}
	assert attempt == 3
	assert fake.stat('conflicts') == 2
	// More conflicts than attempts: the policy gives up with the 40001.
	mut fake2 := testkit.start_fake_pg(['--conflicts', '10'])!
	defer {
		fake2.stop()
	}
	mut c2 := PgConn.connect(tx_cfg(fake2.port))!
	defer {
		c2.close()
	}
	c2.set_nonblocking()!
	mut tries := 0
	for {
		tries++
		assert c2.async_submit_batch(transfer)!
		run_poll(mut c2) or {
			if policy.retry(tries, err) {
				continue
			}
			assert is_serialization_failure(err)
			break
		}
		assert false, 'every attempt conflicts'
	}
	assert tries == policy.max_attempts
}

fn C.timerfd_gettime(fd int, curr_value voidptr) int

const tx_transfer = [
	Stmt{
		sql: 'update accounts set balance = balance - 1 where id = 1'
	},
	Stmt{
		sql: 'update accounts set balance = balance + 1 where id = 2'
	},
]

// BoLoop stands in for the worker's loop that park_backoff parks a request
// on: it records the watch armed (one at a time), or refuses every watch, as
// an event loop that watches nothing does.
struct BoLoop {
mut:
	fd      int         = -1
	cont    core.WakeFn = unsafe { nil }
	payload voidptr
	refuse  bool
}

fn bo_register(mut w core.EventLoop, fd int, interest core.WatchInterest, cont core.WakeFn, payload voidptr) {
	mut l := unsafe { &BoLoop(w.reactor) }
	if l.refuse {
		w.last_watched = -1
		return
	}
	l.fd = fd
	l.cont = cont
	l.payload = payload
	w.last_watched = fd
}

// bo_loop is the event loop a continuation would hand park_backoff: one for
// a request (client_fd 7), on the BoLoop.
fn bo_loop(l &BoLoop) core.EventLoop {
	return core.EventLoop{
		client_fd: 7
		reactor:   voidptr(l)
		register:  bo_register
	}
}

// bo_fired is what a request resumes with when its wait is over: here it only
// closes the timer, which is the request's own.
fn bo_fired(mut _ []u8, ready_fd int, _ bool, _ voidptr, _ voidptr, mut _ core.EventLoop) core.Step {
	C.close(ready_fd)
	return .done
}

// timer_left_ms is how long the timerfd has left to run, in whole ms rounded
// up; 0 once it fired. -1 if it is periodic, which a wait must not be.
fn timer_left_ms(fd int) int {
	mut spec := [4]i64{} // struct itimerspec: it_interval {sec, nsec}, it_value {sec, nsec}
	r := C.timerfd_gettime(fd, unsafe { voidptr(&spec[0]) })
	assert r == 0
	if spec[0] != 0 || spec[1] != 0 {
		return -1
	}
	return int(spec[2] * 1000 + (spec[3] + 999_999) / 1_000_000)
}

// timerfds counts this process's open timerfds.
fn timerfds() int {
	mut n := 0
	for name in os.ls('/proc/self/fd') or { return -1 } {
		target := os.readlink('/proc/self/fd/' + name) or { continue }
		if target == 'anon_inode:[timerfd]' {
			n++
		}
	}
	return n
}

// A conflict is run again after a wait on a timerfd armed for backoff_ms,
// spent without the connection (it serves another query meanwhile), with the
// next attempt's number in the watch payload, until it commits. Running out
// of attempts gives up with the 40001. Every timer is closed.
fn test_fake_conflict_waits_on_a_timerfd_between_attempts() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		mut fake := testkit.start_fake_pg(['--conflicts', '2'])!
		defer {
			fake.stop()
		}
		mut pool := new_pool(tx_cfg(fake.port), 1)!
		defer {
			pool.close()
		}
		policy := TxRetry{
			base_backoff_ms: 30
			max_backoff_ms:  30
		}
		t0 := timerfds()
		mut l := BoLoop{}
		mut scratch := []u8{}
		mut attempt := 1
		mut waits := 0
		for {
			i := pool.acquire() or { panic('the connection is free') }
			mut c := pool.conn(i)
			submitted := c.async_submit_batch(tx_transfer)!
			assert submitted
			res := run_poll(mut c) or {
				pool.release(i)
				assert policy.retry(attempt, err)
				mut el := bo_loop(&l)
				parked := policy.park_backoff(attempt, mut el, bo_fired, voidptr(usize(attempt + 1)))
				assert parked
				assert el.last_watched == l.fd
				assert el.timeout_ms == -1, 'the timer is its own deadline'
				assert os.readlink('/proc/self/fd/${l.fd}')! == 'anon_inode:[timerfd]'
				left := timer_left_ms(l.fd)
				assert left >= 0 && left <= 30, 'one-shot, armed for backoff_ms(attempt)'
				// The connection was released: it serves a query during the wait.
				j := pool.acquire() or { panic('the connection was not released') }
				assert j == i
				mut cj := pool.conn(j)
				r7 := run_sql(mut cj, 'select 7')!
				mut it := r7.rows()
				assert (it.next() or { panic('row') }).int4(0)! == 7
				pool.release(j)
				ready := C.pg_async_wait(l.fd, C.POLLIN, 2000)
				assert ready > 0, 'the timer fires'
				waits++
				mut fired := bo_loop(&l)
				step := l.cont(mut scratch, l.fd, false, l.payload, unsafe { nil }, mut fired)
				assert step == .done
				attempt = int(usize(l.payload))
				continue
			}
			pool.release(i)
			assert res.statement(1)!.rows_affected == 1
			break
		}
		assert attempt == 3
		assert waits == 2
		assert fake.stat('conflicts') == 2
		assert timerfds() == t0, 'every timer closed'

		// More conflicts than attempts: two waits, then the policy gives up.
		mut fake2 := testkit.start_fake_pg(['--conflicts', '10'])!
		defer {
			fake2.stop()
		}
		mut pool2 := new_pool(tx_cfg(fake2.port), 1)!
		defer {
			pool2.close()
		}
		quick := TxRetry{
			max_attempts:    3
			base_backoff_ms: 1
			max_backoff_ms:  2
		}
		attempt = 1
		waits = 0
		for {
			i := pool2.acquire() or { panic('the connection is free') }
			mut c := pool2.conn(i)
			submitted := c.async_submit_batch(tx_transfer)!
			assert submitted
			run_poll(mut c) or {
				pool2.release(i)
				if !quick.retry(attempt, err) {
					assert is_serialization_failure(err)
					break
				}
				mut el := bo_loop(&l)
				parked := quick.park_backoff(attempt, mut el, bo_fired, voidptr(usize(attempt + 1)))
				assert parked
				ready := C.pg_async_wait(l.fd, C.POLLIN, 2000)
				assert ready > 0
				waits++
				mut fired := bo_loop(&l)
				l.cont(mut scratch, l.fd, false, l.payload, unsafe { nil }, mut fired)
				attempt = int(usize(l.payload))
				continue
			}
			assert false, 'every attempt conflicts'
		}
		assert attempt == quick.max_attempts
		assert waits == quick.max_attempts - 1
		assert fake2.stat('conflicts') == quick.max_attempts
		assert timerfds() == t0, 'every timer closed'
	}
}

// Where no timer can be armed (an event loop that watches nothing; no
// timerfd outside Linux), park_backoff arms nothing and says so: the caller
// runs the next attempt at once, or answers. Nothing is left open.
fn test_park_backoff_without_a_watch_arms_nothing() {
	mut l := BoLoop{
		refuse: true
	}
	mut el := bo_loop(&l)
	$if linux {
		t0 := timerfds()
		refused := TxRetry{}.park_backoff(1, mut el, bo_fired, unsafe { nil })
		assert !refused
		assert timerfds() == t0, 'the timer it could not watch is closed'
		l.refuse = false
		mut el2 := bo_loop(&l)
		parked := TxRetry{}.park_backoff(1, mut el2, bo_fired, unsafe { nil })
		assert parked
		assert timerfds() == t0 + 1
		C.close(l.fd)
	} $else {
		l.refuse = false
		parked := TxRetry{}.park_backoff(1, mut el, bo_fired, unsafe { nil })
		assert !parked
		assert l.fd == -1, 'no timerfd here: nothing watched'
	}
}
