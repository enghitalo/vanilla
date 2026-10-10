// vtest build: !windows
module pg_async

import os
import time

// Transactions against a live PostgreSQL (vanilla#199), skipped unless PGHOST
// is set: a batch is atomic, a connection released mid-transaction reaches
// its next borrower rolled back, and a SERIALIZABLE conflict (40001) is run
// again, whole, until it commits. Each uses its own rows of pg_async_tx
// (created if missing).

fn tx_live_cfg() ?ConnConfig {
	host := os.getenv('PGHOST')
	if host == '' {
		return none
	}
	port_env := os.getenv('PGPORT')
	return ConnConfig{
		host:          host
		port:          if port_env != '' { port_env.int() } else { 5432 }
		user:          os.getenv('PGUSER')
		password:      os.getenv('PGPASSWORD')
		database:      os.getenv('PGDATABASE')
		// PGSSLMODE=verify-full + PGSSLROOTCERT: the TLS lane of pg_async.yml
		ssl_mode:      SslMode.from_string(os.getenv('PGSSLMODE').replace('-', '_')) or {
			SslMode.disable
		}
		ssl_root_cert: os.getenv('PGSSLROOTCERT')
	}
}

// live_poll flushes, then pumps the front query (or batch) to completion.
fn live_poll(mut c PgConn) !Result {
	for _ in 0 .. 10000 {
		if c.async_flush()! {
			break
		}
	}
	for _ in 0 .. 5000 {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		time.sleep(time.millisecond)
	}
	return error('query did not complete')
}

fn live_sql(mut c PgConn, query string) !Result {
	assert c.async_submit(query, []?[]u8{})
	return live_poll(mut c)
}

fn live_batch(mut c PgConn, stmts []Stmt) !Result {
	assert c.async_submit_batch(stmts)!
	assert c.inflight_count() == 1
	return live_poll(mut c)
}

fn first_int(res Result) !int {
	mut it := res.rows()
	return int((it.next() or { return error('expected a row') }).int4(0)!)
}

// rows_with counts pg_async_tx rows with this id, on a connection of its own.
fn rows_with(mut admin PgConn, id int) !int {
	res := admin.query(r'select count(*)::int4 from pg_async_tx where id = $1::int4', [
		?[]u8(id.str().bytes()),
	])!
	return first_int(res)
}

fn live_acquire_within(mut pool PgPool) ?int {
	for _ in 0 .. 3000 {
		if i := pool.acquire() {
			return i
		}
		time.sleep(time.millisecond)
	}
	return none
}

fn tx_live_setup(cfg ConnConfig) !PgConn {
	mut admin := PgConn.connect(cfg)!
	admin.query('create table if not exists pg_async_tx (id int4 primary key, v int4 not null)',
		[]?[]u8{})!
	return admin
}

fn test_live_batch_is_atomic() {
	cfg := tx_live_cfg() or {
		eprintln('pg_async: skipping live transaction tests (no PGHOST)')
		return
	}
	mut admin := tx_live_setup(cfg)!
	defer {
		admin.close()
	}
	admin.query('delete from pg_async_tx where id between 1 and 9', []?[]u8{})!
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	c.set_nonblocking()!

	// [insert 1, insert 1]: the second violates the key, so neither row exists.
	ins := r'insert into pg_async_tx values ($1::int4, 0)'
	if _ := live_batch(mut c, [Stmt{
		sql:    ins
		params: [?[]u8('1'.bytes())]
	}, Stmt{
		sql:    ins
		params: [?[]u8('1'.bytes())]
	}]) {
		assert false, 'the duplicate key must fail the batch'
	} else {
		assert err is PgError, err.msg()
		if err is PgError {
			assert err.sqlstate == '23505'
			assert err.statement == 1
		}
	}
	assert rows_with(mut admin, 1)! == 0, 'the first insert was rolled back with the batch'
	assert !c.in_transaction()

	// [insert 2, insert 3]: both, in one round trip.
	res := live_batch(mut c, [Stmt{
		sql:    ins
		params: [?[]u8('2'.bytes())]
	}, Stmt{
		sql:    ins
		params: [?[]u8('3'.bytes())]
	}])!
	assert res.statement(0)!.rows_affected == 1
	assert res.statement(1)!.rows_affected == 1
	assert rows_with(mut admin, 2)! == 1
	assert rows_with(mut admin, 3)! == 1

	// A later statement's error undoes the earlier ones too.
	if _ := live_batch(mut c, [Stmt{
		sql:    ins
		params: [?[]u8('4'.bytes())]
	}, Stmt{
		sql: 'select 1/0'
	}, Stmt{
		sql:    ins
		params: [?[]u8('5'.bytes())]
	}]) {
		assert false, 'division by zero'
	} else {
		if err is PgError {
			assert err.sqlstate == '22012'
			assert err.statement == 1
		}
	}
	assert rows_with(mut admin, 4)! == 0
	assert rows_with(mut admin, 5)! == 0
	// And a batch's rows come back per statement.
	sel := live_batch(mut c, [Stmt{
		sql: 'select 7::int4'
	}, Stmt{
		sql: 'select count(*)::int4 from pg_async_tx where id between 2 and 3'
	}])!
	assert first_int(sel.statement(0)!)! == 7
	assert first_int(sel.statement(1)!)! == 2
}

// A connection released in the middle of a transaction reaches its next
// borrower rolled back: idle, and the uncommitted write gone. Meanwhile
// acquire_pipelined() never hands it out.
fn test_live_release_rolls_back_uncommitted_work() {
	cfg := tx_live_cfg() or { return }
	mut admin := tx_live_setup(cfg)!
	defer {
		admin.close()
	}
	admin.query('delete from pg_async_tx where id = 10', []?[]u8{})!
	mut pool := PgPool.connect(cfg, 2)!
	defer {
		pool.close()
	}
	a := pool.acquire() or { panic('free') }
	mut ca := pool.conn(a)
	live_sql(mut ca, 'begin')!
	live_sql(mut ca, 'insert into pg_async_tx values (10, 0)')!
	assert ca.in_transaction()
	for _ in 0 .. 4 {
		j := pool.acquire_pipelined() or { panic('the other connection is free') }
		assert j != a, 'acquire_pipelined() shared the connection in a transaction'
		mut cj := pool.conn(j)
		assert first_int(live_sql(mut cj, 'select count(*)::int4 from pg_async_tx where id = 10')!)! == 0
	}
	// The borrower bails out without COMMIT or ROLLBACK.
	pool.release(a)
	other := pool.acquire() or { panic('the other connection is free') }
	assert other != a
	b := live_acquire_within(mut pool) or { panic('the released connection never came back') }
	assert b == a, 'the same connection, rolled back'
	mut cb := pool.conn(b)
	assert cb.tx_status() == tx_idle
	assert first_int(live_sql(mut cb, 'select count(*)::int4 from pg_async_tx where id = 10')!)! == 0
	assert rows_with(mut admin, 10)! == 0
	pool.release(b)
	pool.release(other)
}

// Two transactions on the same row under SERIALIZABLE: the one whose snapshot
// predates the other's commit fails with 40001, and TxRetry runs it again,
// whole, until it commits. First as statements across round trips, then as a
// batch holding the whole explicit transaction (one round trip).
fn test_live_serializable_conflict_is_retried() {
	cfg := tx_live_cfg() or { return }
	mut admin := tx_live_setup(cfg)!
	defer {
		admin.close()
	}
	admin.query('delete from pg_async_tx where id = 20', []?[]u8{})!
	admin.query('insert into pg_async_tx values (20, 0)', []?[]u8{})!
	mut pool := PgPool.connect(cfg, 2)!
	defer {
		pool.close()
	}
	policy := TxRetry{}
	bump := 'update pg_async_tx set v = v + 1 where id = 20'
	// The other writer: one implicit transaction that commits at once.
	b := pool.acquire() or { panic('free') }
	mut cb := pool.conn(b)

	mut attempt := 1
	for {
		a := live_acquire_within(mut pool) or { panic('no connection for the attempt') }
		mut ca := pool.conn(a)
		live_sql(mut ca, 'begin isolation level serializable')!
		assert first_int(live_sql(mut ca, 'select v from pg_async_tx where id = 20')!)! >= 0 // the snapshot
		if attempt == 1 {
			live_batch(mut cb, [Stmt{
				sql: bump
			}])! // commits after A's snapshot
		}
		live_sql(mut ca, bump) or {
			assert is_serialization_failure(err), err.msg()
			assert ca.tx_status() == tx_failed
			pool.release(a) // rolls the failed transaction back
			if !policy.retry(attempt, err) {
				panic('gave up after ${attempt} attempts')
			}
			time.sleep(i64(policy.backoff_ms(attempt)) * time.millisecond) // a test, not a worker
			attempt++
			continue
		}
		live_sql(mut ca, 'commit')!
		assert !ca.in_transaction()
		pool.release(a)
		break
	}
	assert attempt == 2
	v1 := first_int(admin.query('select v from pg_async_tx where id = 20', []?[]u8{})!)!
	assert v1 == 2, 'both increments committed'

	// The same, each attempt ONE batch: BEGIN … COMMIT with the isolation
	// level, so the conflict needs B to commit between A's snapshot and A's
	// update — A's first attempt is split in two batches to make room for it.
	attempt = 1
	whole := [
		Stmt{
			sql: 'begin isolation level serializable'
		},
		Stmt{
			sql: 'select v from pg_async_tx where id = 20'
		},
		Stmt{
			sql: bump
		},
		Stmt{
			sql: 'commit'
		},
	]
	for {
		a := live_acquire_within(mut pool) or { panic('no connection for the attempt') }
		mut ca := pool.conn(a)
		whole_attempt(attempt, mut ca, mut cb, whole, bump) or {
			assert is_serialization_failure(err), err.msg()
			if err is PgError {
				assert err.statement == 0, 'the UPDATE of the second batch'
			}
			pool.release(a) // the session is in a failed block: rolled back here
			if !policy.retry(attempt, err) {
				panic('gave up after ${attempt} attempts')
			}
			time.sleep(i64(policy.backoff_ms(attempt)) * time.millisecond)
			attempt++
			continue
		}
		assert !ca.in_transaction()
		pool.release(a)
		break
	}
	assert attempt == 2
	v2 := first_int(admin.query('select v from pg_async_tx where id = 20', []?[]u8{})!)!
	assert v2 == 4
	pool.release(b)
}

// whole_attempt runs the explicit transaction `whole` as one batch; the first
// attempt is split in two batches with B's commit between them, so that it
// conflicts.
fn whole_attempt(attempt int, mut ca PgConn, mut cb PgConn, whole []Stmt, bump string) !Result {
	if attempt > 1 {
		return live_batch(mut ca, whole)
	}
	live_batch(mut ca, whole[..2])!
	assert ca.tx_status() == tx_in_block, 'a BEGIN in a batch outlives its Sync'
	live_batch(mut cb, [Stmt{
		sql: bump
	}])!
	return live_batch(mut ca, whole[2..])
}
