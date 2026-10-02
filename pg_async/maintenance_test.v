// vtest build: !windows
module pg_async

import time
import testkit

// Pool maintenance against the fake server: a connection the server closes
// while idle is found and re-dialed by maintain(), without any query failing.

fn maint_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// pump_reply flushes, then pumps readable until the front query completes.
fn pump_reply(mut c PgConn) !Result {
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

fn one_query(mut pool PgPool, idx int) !int {
	mut c := pool.conn(idx)
	if !c.async_submit('select 1', []?[]u8{}) {
		return error('submit refused')
	}
	res := pump_reply(mut c)!
	mut it := res.rows()
	return (it.next() or { return error('no row') }).int4(0)!
}

fn test_maintain_redials_a_connection_closed_while_idle() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping maintenance tests (no python3)')
		return
	}
	// Every connection is closed by the fake 50 ms after its first reply.
	mut fake := testkit.start_fake_pg(['--close', 'delayed', '--close-after', '1'])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(maint_cfg(fake.port), 2)!
	defer {
		pool.close()
	}
	assert pool.maintain() == maintenance_idle_ms, 'a healthy pool ticks at the idle rate'
	idx := pool.acquire() or { panic('expected an idle connection') }
	assert one_query(mut pool, idx)! == 1
	pool.release(idx)
	time.sleep(150 * time.millisecond) // the fake has closed it by now; nobody has noticed
	assert pool.conns[idx].state == .ready
	// maintain() alone (no acquire, no query) finds the close and re-dials.
	mut saw_busy := false
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 {
		next := pool.maintain()
		if next < maintenance_idle_ms {
			saw_busy = true
		}
		if fake.stat('authenticated') == 3 && pool.conns[idx].state == .ready {
			break
		}
		time.sleep(i64(next) * time.millisecond)
	}
	assert saw_busy, 'a re-dial in flight asks for a fast tick'
	assert fake.stat('authenticated') == 3, 'the closed connection was re-dialed'
	assert pool.conns[idx].state == .ready
	assert pool.maintain() == maintenance_idle_ms
	// And it serves: the first query after the close succeeds.
	j := pool.acquire() or { panic('expected an idle connection') }
	assert one_query(mut pool, j)! == 1
	pool.release(j)
}

fn test_probe_keeps_the_fatal_a_server_sent_while_idle() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'fatal', '--close-after', '1'])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(maint_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	assert one_query(mut pool, 0)! == 1
	time.sleep(150 * time.millisecond) // FATAL 57P01, then the close
	pool.conns[0].probe_idle()
	assert pool.conns[0].state == .broken
	assert pool.conns[0].fatal.sqlstate == '57P01'
	assert pool.conns[0].fatal.severity == 'FATAL'
}

fn test_maintain_leaves_borrowed_connections_alone() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'delayed', '--close-after', '1'])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(maint_cfg(fake.port), 1)!
	defer {
		pool.close()
	}
	idx := pool.acquire() or { panic('expected the connection') }
	assert one_query(mut pool, idx)! == 1
	time.sleep(150 * time.millisecond) // closed while still held by its borrower
	pool.maintain()
	// The borrower holds it: maintain() neither probes nor re-dials it; the
	// borrower's own reader finds the loss.
	assert pool.conns[idx].state == .ready
	assert fake.stat('authenticated') == 1
	pool.release(idx)
}
