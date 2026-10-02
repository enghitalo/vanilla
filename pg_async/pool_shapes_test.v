// vtest build: !windows
module pg_async

import testkit

// The two pooling shapes on ONE pool (bench/pg_async/e2e_server serves /db
// with acquire() and /dbp with acquire_pipelined() from the same pool):
// neither may hand out a connection the other shape is using.

fn shapes_pool(port int, size int) !&PgPool {
	return new_pool(ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}, size)
}

// pump_front flushes, then pumps readable until the front query completes.
fn pump_front(mut c PgConn) !Result {
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

// An exclusive borrower may hold its connection between queries (BEGIN …
// COMMIT across park/resume, depth 0 in between): acquire_pipelined must not
// pipeline someone else's query onto it.
fn test_pipelined_never_shares_an_exclusively_held_connection() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping pool shape tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shapes_pool(fake.port, 2)!
	defer {
		pool.close()
	}
	held := pool.acquire() or { panic('expected an idle connection') }
	for _ in 0 .. 4 {
		j := pool.acquire_pipelined() or { panic('the other connection is free') }
		assert j != held, 'acquire_pipelined handed out the exclusively held connection ${held}'
	}
	// With the only free connection exclusively held too, there is nothing to share.
	other := pool.acquire() or { panic('expected the second connection') }
	if j := pool.acquire_pipelined() {
		assert false, 'acquire_pipelined returned ${j} while both connections are held'
	}
	pool.release(held)
	pool.release(other)
}

// A connection carrying other requests' pipelined queries must not be taken
// exclusively: the borrower's release() would find queries in flight and
// retire the connection, failing those requests.
fn test_exclusive_never_takes_a_connection_with_pipelined_queries() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shapes_pool(fake.port, 1)!
	defer {
		pool.close()
	}
	j := pool.acquire_pipelined() or { panic('expected the connection') }
	mut c := pool.conn(j)
	assert c.async_submit('select 7', []?[]u8{})
	if i := pool.acquire() {
		pool.release(i) // what a borrower does when done: retires the shared connection
		assert false, 'acquire() took connection ${i} with a pipelined query in flight (state after release: ${pool.conns[i].state})'
	}
	// The pipelined request still gets its own result.
	res := pump_front(mut c)!
	mut it := res.rows()
	assert (it.next() or { panic('expected a row') }).int4(0)! == 7
	assert pool.conns[j].state == .ready
	// Once drained, the connection can be taken exclusively.
	i := pool.acquire() or { panic('the drained connection should be free') }
	pool.release(i)
}
