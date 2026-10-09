// vtest build: !windows
module pg_async

import time
import testkit

// Transactions against the fake server (pg_async/testdata/fake_pg.py, which
// tracks the transaction status like PostgreSQL and answers a batch's
// statements at its one Sync): the status byte, the pool keeping sessions in
// a transaction to themselves, the ROLLBACK at release, batches, and a
// conflict retried with TxRetry. Skipped without python3 unless
// VANILLA_REQUIRE_FAKE_PG is set.

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
