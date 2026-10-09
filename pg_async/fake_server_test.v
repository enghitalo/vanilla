// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import testkit

// Deterministic, PostgreSQL-free tests against pg_async/testdata/fake_pg.py
// (python3, stdlib only): real SCRAM-SHA-256, the extended-query flow and
// canned binary results. They pin today's behaviour on the paths a live
// server is not needed for. Skipped when python3 is missing (unless
// VANILLA_REQUIRE_FAKE_PG is set, as in CI).

fn fake_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// pump_one flushes whatever is pending, then pumps readable until the front
// query completes (or fails).
fn pump_one(mut c PgConn) !Result {
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

fn test_fake_scram_handshake_and_blocking_query() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping fake-server tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(fake_cfg(fake.port))!
	defer {
		c.close()
	}
	assert fake.stat('authenticated') == 1
	res := c.query('select 7', []?[]u8{})!
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	assert row.int4(0)! == 7
	res2 := c.query(r'select $1::int4, $2::text', [?[]u8('42'.bytes()), ?[]u8('hi'.bytes())])!
	mut it2 := res2.rows()
	row2 := it2.next() or { panic('expected a row') }
	assert row2.int4(0)! == 42
	assert row2.text(1)!.bytestr() == 'hi'
	// A query error leaves the connection usable (its ReadyForQuery was read).
	if _ := c.query('select 1/0', []?[]u8{}) {
		assert false, 'expected division by zero'
	}
	res3 := c.query('select 3', []?[]u8{})!
	mut it3 := res3.rows()
	assert (it3.next() or { panic('expected a row') }).int4(0)! == 3
}

fn test_fake_wrong_password_fails_the_handshake() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	cfg := ConnConfig{
		...fake_cfg(fake.port)
		password: 'wrong'
	}
	if _ := PgConn.connect(cfg) {
		assert false, 'a wrong password must fail the handshake'
	}
	assert fake.stat('authenticated') == 0
}

fn test_fake_async_pipeline_keeps_order_and_isolates_errors() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(fake_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	assert c.async_submit('select 10', []?[]u8{})
	assert c.async_submit('select 1/0', []?[]u8{})
	assert c.async_submit(r'select $1::int4', [?[]u8('30'.bytes())])
	assert c.inflight_count() == 3
	first := pump_one(mut c)!
	mut it := first.rows()
	assert (it.next() or { panic('row') }).int4(0)! == 10
	if _ := pump_one(mut c) {
		assert false, 'the middle query must fail alone'
	}
	third := pump_one(mut c)!
	mut it3 := third.rows()
	assert (it3.next() or { panic('row') }).int4(0)! == 30
	assert !c.is_busy()
}

fn test_fake_large_reply_spans_many_reads() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(fake_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	// 20000 DataRows (~300 KB): far past the 16 KiB receive buffer.
	assert c.async_submit('select g from generate_series(1, 20000) g', []?[]u8{})
	res := pump_one(mut c)!
	mut it := res.rows()
	mut n := 0
	for {
		row := it.next() or { break }
		n++
		assert row.int4(0)! == n
	}
	assert n == 20000
	assert res.rows_affected == 20000
}

fn test_fake_pool_brings_up_every_connection() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := PgPool.connect(fake_cfg(fake.port), 3)!
	defer {
		pool.close()
	}
	assert pool.size() == 3
	assert fake.stat('authenticated') == 3
}
