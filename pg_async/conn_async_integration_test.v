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
		c.async_submit(r'select $1::int4, $2::text', [?[]u8('${expect}'.bytes()),
			?[]u8('round'.bytes())])
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
