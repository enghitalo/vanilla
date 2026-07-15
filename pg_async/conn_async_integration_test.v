// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import os

// Live-Postgres test of the NON-BLOCKING query pump. Skipped unless PGHOST is
// set. Drives the connection with a simple pump loop — exactly the
// flush-on-writable / read-on-readable mechanism the async HTTP worker performs
// via ac.watch, minus the epoll. (Each _test.v file is compiled independently,
// so the env read is inlined rather than shared with conn_integration_test.v.)
fn test_async_query_pump_against_live_pg() {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping async pump test (no PGHOST)')
		return
	}
	port_env := os.getenv('PGPORT')
	cfg := ConnConfig{
		host:     host
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	c.set_nonblocking()!

	// Two sequential queries prove the connection returns to idle and is reusable.
	for round in 0 .. 2 {
		expect := round + 7
		assert c.async_submit(r'select $1::int4, $2::text', [
			?[]u8('${expect}'.bytes()),
			?[]u8('round'.bytes()),
		])
		assert c.is_busy()

		// Flush the request (a small request goes out in one write; loop guards EAGAIN).
		mut sent := false
		for _ in 0 .. 10000 {
			if c.async_flush()! {
				sent = true
				break
			}
		}
		assert sent, 'request flush did not complete'

		// Pump readable until the result is ready (not-ready = need more bytes).
		mut got := ?Result(none)
		for _ in 0 .. 200000 {
			poll := c.async_on_readable()!
			if poll.ready {
				got = poll.result
				break
			}
		}
		res := got or { panic('async query did not complete') }
		assert !c.is_busy() // back to idle, reusable for the next round

		mut it := res.rows()
		row := it.next() or { panic('expected a row') }
		assert row.int4(0)! == expect
		assert row.text(1)!.bytestr() == 'round'
		if _ := it.next() {
			assert false, 'expected exactly one row'
		}
	}
}

// Live-Postgres test of CROSS-REQUEST PIPELINING: many queries submitted
// back-to-back on ONE connection before any reply is drained. Postgres returns
// replies in submission order, so the in-flight FIFO yields them in order with
// no correlation id. Skipped unless PGHOST is set.
fn test_async_pipeline_against_live_pg() {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping async pipeline test (no PGHOST)')
		return
	}
	port_env := os.getenv('PGPORT')
	cfg := ConnConfig{
		host:     host
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	c.set_nonblocking()!

	// 1. Pipeline three queries before draining any; the FIFO must yield 10,20,30.
	expected := [10, 20, 30]
	for v in expected {
		assert c.async_submit(r'select $1::int4', [?[]u8('${v}'.bytes())])
	}
	assert c.inflight_count() == 3

	mut sent := false
	for _ in 0 .. 10000 {
		if c.async_flush()! {
			sent = true
			break
		}
	}
	assert sent, 'pipelined flush did not complete'

	mut got := []int{}
	for _ in 0 .. 200000 {
		if got.len == expected.len {
			break
		}
		poll := c.async_on_readable()!
		if poll.ready {
			mut it := poll.result.rows()
			row := it.next() or { panic('expected a row') }
			got << row.int4(0)!
		}
	}
	assert got == expected
	assert !c.is_busy() // ring drained, connection idle + reusable

	// 2. Error isolation: a bad query in the middle fails only itself; the good
	// queries on either side still complete and the connection resyncs (each
	// query carries its own Sync, so the error is bounded to that query).
	assert c.async_submit(r'select 100::int4', []?[]u8{})
	assert c.async_submit(r'select nonexistent_col_zzz', []?[]u8{})
	assert c.async_submit(r'select 300::int4', []?[]u8{})
	for _ in 0 .. 10000 {
		if c.async_flush()! {
			break
		}
	}
	mut ok_vals := []int{}
	mut errors := 0
	mut drained := 0
	for _ in 0 .. 200000 {
		if drained == 3 {
			break
		}
		poll := c.async_on_readable() or {
			// The failed query's ReadyForQuery was consumed before the error
			// surfaced, so the stream stays in sync for the next query.
			errors++
			drained++
			continue
		}
		if poll.ready {
			mut it := poll.result.rows()
			row := it.next() or { panic('expected a row') }
			ok_vals << row.int4(0)!
			drained++
		}
	}
	assert errors == 1
	assert ok_vals == [100, 300]
	assert !c.is_busy()
}
