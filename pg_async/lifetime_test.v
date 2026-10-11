// vtest build: !windows
module pg_async

import os
import time
import testkit

// Connection max lifetime (vanilla#197): maintain() recycles pooled
// connections past max_lifetime_ms (minus their jitter) without a query ever
// failing or waiting on the re-dial, against pg_async/testdata/fake_pg.py.
// Skipped without python3 unless VANILLA_REQUIRE_FAKE_PG is set (CI).

@[heap]
struct Dials {
mut:
	n int
}

fn lifetime_cfg(port int, mut dials Dials, max_lifetime_ms int, jitter_ms int) ConnConfig {
	return ConnConfig{
		host:               '127.0.0.1'
		port:               port
		user:               'vanilla'
		database:           'vanilla'
		password_fn:        fn [mut dials] () !string {
			dials.n++
			return 'secret'
		}
		max_lifetime_ms:    max_lifetime_ms
		lifetime_jitter_ms: jitter_ms
	}
}

// lt_pump flushes, then pumps readable until the front query completes.
fn lt_pump(mut c PgConn) !Result {
	deadline := time.sys_mono_now() + 5 * u64(time.second)
	for c.async_wants_write() {
		c.async_flush()!
	}
	for time.sys_mono_now() < deadline {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		C.pg_async_wait(c.fd, C.POLLIN, 10)
	}
	return error('query did not complete')
}

fn lt_int(res Result) int {
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	return int(row.int4(0) or { panic(err) })
}

// await_stat waits for a fake-server counter: the fake counts on its own
// threads, a moment after the client moved on.
fn await_stat(fake &testkit.FakePg, key string, want int) int {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 && fake.stat(key) < want {
		time.sleep(5 * time.millisecond)
	}
	return fake.stat(key)
}

// The jitter spreads connections that come up at the same instant over
// [max_lifetime_ms - lifetime_jitter_ms, max_lifetime_ms], per connection
// (its address), with no RNG state; max_lifetime_ms stays the bound.
fn test_lifetime_deadline_spreads_connections_opened_together() {
	mut dials := &Dials{}
	cfg := lifetime_cfg(5432, mut dials, 60_000, 10_000)
	conns := []PgConn{len: 64}
	now := time.sys_mono_now()
	life := 60 * u64(time.second)
	jitter := 10 * u64(time.second)
	mut lo := max_u64
	mut hi := u64(0)
	mut seconds := map[u64]bool{}
	for i in 0 .. conns.len {
		d := conns[i].lifetime_deadline(&cfg, now)
		assert d <= now + life && d >= now + life - jitter
		lo = if d < lo { d } else { lo }
		hi = if d > hi { d } else { hi }
		seconds[(d - now) / u64(time.second)] = true
	}
	assert hi - lo > jitter / 2, 'the deadlines bunch up'
	assert seconds.len >= 8, 'the deadlines fall in ${seconds.len} distinct seconds of 11'
	assert conns[0].lifetime_deadline(&ConnConfig{}, now) == max_u64, 'no max_lifetime_ms: never'
	assert conns[0].lifetime_deadline(&ConnConfig{ max_lifetime_ms: 100, lifetime_jitter_ms: 500 },
		now) > now, 'a jitter past the lifetime still leaves some'
}

// A pool of 2 with a ~150 ms lifetime, served the way a worker would
// (maintain() on the timer it asks for, exclusive and pipelined queries in
// between) until each connection was recycled at least 4 times: one at a
// time, so acquire() always finds the other one, and queries go through
// during every recycle; the timer never sleeps past a deadline; no query
// fails; each recycle says Terminate and asks password_fn for a fresh
// credential.
//
// The loop counts recycles, not time: a re-dial takes a few maintain() ticks,
// one per round of queries, so how many recycles fit in a fixed window
// depends on how busy the machine is (1.2 s held about 16 on an idle
// machine, 5 to 7 on loaded CI runners). The bound only catches recycling
// that stopped.
fn test_lifetime_recycles_without_failing_or_shedding_a_query() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping lifetime tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut dials := &Dials{}
	mut pool := PgPool.connect(lifetime_cfg(fake.port, mut dials, 150, 50), 2)!
	assert dials.n == 2
	mut recycled := [0, 0]
	mut served := false // a query went through during the recycle in flight
	mut queries := 0
	mut next_tick := time.sys_mono_now()
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 20_000 && (recycled[0] < 4 || recycled[1] < 4) {
		now := time.sys_mono_now()
		if now >= next_tick {
			r := pool.recycling
			wait := pool.maintain()
			next_tick = now + u64(wait) * u64(time.millisecond)
			if r >= 0 && pool.recycling < 0 {
				assert served, 'no query went through while connection ${r} was recycled'
				served = false
				recycled[r]++
			}
			// The timer never sleeps past a deadline: it asks for a fast
			// tick, or for one by the time each connection comes due.
			for k in 0 .. 2 {
				assert wait <= maintenance_busy_ms || k == pool.recycling
					|| next_tick <= pool.conns[k].expires_at + u64(time.millisecond), 'the next tick comes after connection ${k} is due'
			}
		}
		i := pool.acquire() or { panic('acquire() found no connection during a recycle') }
		served = served || pool.recycling >= 0
		mut c := pool.conn(i)
		assert c.async_submit('select 1', []?[]u8{})
		assert lt_int(lt_pump(mut c)!) == 1
		pool.release(i)
		j := pool.acquire_pipelined() or { panic('acquire_pipelined() found no connection') }
		mut cj := pool.conn(j)
		assert cj.async_submit('select 2', []?[]u8{})
		assert cj.async_submit('select 3', []?[]u8{})
		assert lt_int(lt_pump(mut cj)!) == 2
		assert lt_int(lt_pump(mut cj)!) == 3
		queries += 3
		time.sleep(2 * time.millisecond)
	}
	assert recycled[0] >= 4 && recycled[1] >= 4, 'recycled ${recycled[0]} and ${recycled[1]} times in ${sw.elapsed().milliseconds()} ms of 100-150 ms lifetimes'
	// Let a recycle in flight finish, so close() finds both connections up.
	for _ in 0 .. 1000 {
		r := pool.recycling
		if r < 0 {
			break
		}
		time.sleep(i64(pool.maintain()) * time.millisecond)
		if pool.recycling < 0 {
			recycled[r]++
		}
	}
	assert pool.recycling < 0
	total := fake.stat('authenticated')
	assert total == 2 + recycled[0] + recycled[1], 'one authentication per recycle'
	assert dials.n == total, 'password_fn: once per connection'
	pool.close()
	// Every connection ended with a Terminate: each recycled one, then the
	// two close() ended.
	assert await_stat(fake, 'terminates', total) == total
	assert fake.stat('queries') == queries
}

// A connection held by acquire() when it comes due is left to its borrower;
// release() hands it to the pool, which recycles it before anyone else takes
// it. maintain() wakes up for the deadline instead of its 1 s idle tick.
fn test_lifetime_recycles_a_borrowed_connection_at_release() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut dials := &Dials{}
	mut pool := PgPool.connect(lifetime_cfg(fake.port, mut dials, 100, 0), 1)!
	defer {
		pool.close()
	}
	assert pool.maintain() <= 101, 'the next tick is the lifetime deadline'
	i := pool.acquire() or { panic('acquire') }
	mut c := pool.conn(i)
	assert c.async_submit('select 1', []?[]u8{})
	assert lt_int(lt_pump(mut c)!) == 1
	time.sleep(150 * time.millisecond)
	pool.maintain() // due, but borrowed: untouched
	assert pool.conns[i].state == .ready
	assert pool.recycling == -1
	pool.release(i)
	assert pool.recycling == i, 'release() keeps a connection past its lifetime'
	if _ := pool.acquire() {
		assert false, 'a connection due for recycling was handed out'
	}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 && pool.recycling >= 0 {
		time.sleep(i64(pool.maintain()) * time.millisecond)
	}
	assert pool.recycling == -1, 'the recycle did not finish'
	assert fake.stat('authenticated') == 2
	assert await_stat(fake, 'terminates', 1) == 1
	assert dials.n == 2
	j := pool.acquire() or { panic('the recycled connection did not come back') }
	mut cj := pool.conn(j)
	assert cj.async_submit('select 4', []?[]u8{})
	assert lt_int(lt_pump(mut cj)!) == 4
	pool.release(j)
	assert pool.recycling == -1, 'a fresh connection is not due'
}

// Pipelined queries already on a connection that comes due finish normally:
// the pool stops sending it new ones and recycles it once they drained.
fn test_lifetime_drains_pipelined_queries_before_recycling() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut dials := &Dials{}
	mut pool := PgPool.connect(lifetime_cfg(fake.port, mut dials, 100, 0), 1)!
	defer {
		pool.close()
	}
	i := pool.acquire_pipelined() or { panic('acquire_pipelined') }
	mut c := pool.conn(i)
	for v in [10, 20, 30] {
		assert c.async_submit(r'select $1::int4', [?[]u8(v.str().bytes())])
	}
	for c.async_wants_write() {
		c.async_flush()!
	}
	time.sleep(150 * time.millisecond)
	assert pool.maintain() == maintenance_busy_ms, 'draining asks for a fast tick'
	assert pool.recycling == i
	if _ := pool.acquire_pipelined() {
		assert false, 'a query was pipelined onto a connection being recycled'
	}
	assert c.state == .ready, 'not torn down under its pipelined queries'
	for v in [10, 20, 30] {
		assert lt_int(lt_pump(mut c)!) == v
	}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 && pool.recycling >= 0 {
		time.sleep(i64(pool.maintain()) * time.millisecond)
	}
	assert pool.recycling == -1
	assert fake.stat('authenticated') == 2
	j := pool.acquire_pipelined() or { panic('the recycled connection did not come back') }
	mut cj := pool.conn(j)
	assert cj.async_submit('select 5', []?[]u8{})
	assert lt_int(lt_pump(mut cj)!) == 5
}

// Against a live PostgreSQL (PGHOST; over TLS when PGSSLMODE asks): with a
// 200 ms lifetime the pool's backends keep changing under a steady stream of
// queries, and none of those queries fails. As above, the loop runs until 6
// backends have answered, not for a fixed time.
fn test_live_lifetime_recycles_backends() {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping the live lifetime test (no PGHOST)')
		return
	}
	port_env := os.getenv('PGPORT')
	mut dials := &Dials{}
	cfg := ConnConfig{
		host:               host
		port:               if port_env != '' { port_env.int() } else { 5432 }
		user:               os.getenv('PGUSER')
		database:           os.getenv('PGDATABASE')
		password_fn:        fn [mut dials] () !string {
			dials.n++
			return os.getenv('PGPASSWORD')
		}
		ssl_mode:           SslMode.from_string(os.getenv('PGSSLMODE').replace('-', '_')) or {
			SslMode.disable
		}
		ssl_root_cert:      os.getenv('PGSSLROOTCERT')
		max_lifetime_ms:    200
		lifetime_jitter_ms: 50
	}
	mut pool := PgPool.connect(cfg, 2)!
	defer {
		pool.close()
	}
	mut pids := map[int]bool{}
	mut next_tick := time.sys_mono_now()
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 20_000 && pids.len < 6 {
		if time.sys_mono_now() >= next_tick {
			next_tick = time.sys_mono_now() + u64(pool.maintain()) * u64(time.millisecond)
		}
		i := pool.acquire() or { panic('acquire() found no connection during a recycle') }
		mut c := pool.conn(i)
		assert c.async_submit('select pg_backend_pid()', []?[]u8{})
		pids[lt_int(lt_pump(mut c)!)] = true
		pool.release(i)
		time.sleep(5 * time.millisecond)
	}
	assert pids.len >= 6, 'only ${pids.len} backends in ${sw.elapsed().milliseconds()} ms of 150-200 ms lifetimes'
	assert dials.n >= pids.len
}
