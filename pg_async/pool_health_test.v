// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import os
import time
import testkit

// Pool health (#191) against pg_async/testdata/fake_pg.py: round-robin
// acquire, broken connections never handed out, at most one failed request
// per dead connection, and maintain() re-dialing them off the request path
// without ever blocking — even with the server gone.

fn pool_cfg(port int) ConnConfig {
	return ConnConfig{
		host:              '127.0.0.1'
		port:              port
		user:              'vanilla'
		password:          'secret'
		database:          'vanilla'
		redial_backoff_ms: 20
	}
}

// run_one runs `select n` on pooled connection idx through the async pump.
fn run_one(mut p PgPool, idx int, n int) !int {
	mut c := p.conn(idx)
	if !c.submit('select ${n}', []?[]u8{})! {
		return error('shed')
	}
	c.async_flush() or {}
	for _ in 0 .. 4000 {
		poll := c.async_on_readable()!
		if poll.ready {
			mut it := poll.result.rows()
			row := it.next() or { return error('no row') }
			return int(row.int4(0)!)
		}
		C.pg_async_wait(c.fd, C.POLLIN, 5)
	}
	return error('no outcome')
}

// settle calls maintain() until cond holds (or 3 s pass).
fn settle(mut p PgPool, cond fn (p &PgPool) bool) bool {
	for _ in 0 .. 1500 {
		p.maintain()
		if cond(p) {
			return true
		}
		time.sleep(2 * time.millisecond)
	}
	return false
}

fn open_fds() int {
	return (os.ls('/proc/self/fd') or { []string{} }).len
}

fn test_acquire_is_round_robin() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping pool-health tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 3)!
	defer {
		p.close()
	}
	mut seen := []int{}
	for _ in 0 .. 6 {
		i := p.acquire() or { panic('pool exhausted') }
		seen << i
		p.release(i)
	}
	assert seen == [0, 1, 2, 0, 1, 2]
	// Held slots are skipped, the rest still rotate.
	a := p.acquire() or { panic('acquire') }
	b := p.acquire() or { panic('acquire') }
	c := p.acquire() or { panic('acquire') }
	assert [a, b, c] == [0, 1, 2]
	if _ := p.acquire() {
		assert false, 'every slot is held'
	}
}

fn test_a_broken_connection_is_never_handed_out() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 2)!
	defer {
		p.close()
	}
	p.conn(0).mark_broken()
	for _ in 0 .. 4 {
		i := p.acquire() or { panic('slot 1 is healthy') }
		assert i == 1
		p.release(i)
		assert p.acquire_pipelined() or { panic('slot 1 is healthy') } == 1
	}
	p.conn(1).mark_broken()
	if _ := p.acquire() {
		assert false, 'both slots are broken'
	}
	if _ := p.acquire_pipelined() {
		assert false, 'both slots are broken'
	}
	assert p.healthy() == 0
}

fn test_a_connection_held_by_acquire_is_never_shared() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 2)!
	defer {
		p.close()
	}
	held := p.acquire() or { panic('acquire') }
	assert held == 0
	// Slot 0 is idle on the wire (depth 0) but held: pipelined queries go to 1.
	for _ in 0 .. 3 {
		assert p.acquire_pipelined() or { panic('slot 1 is free') } == 1
	}
	assert p.acquire() or { panic('slot 1 is not held') } == 1
	if _ := p.acquire_pipelined() {
		assert false, 'both slots are held'
	}
	p.release(held)
	assert p.acquire_pipelined() or { panic('slot 0 was released') } == 0
}

fn test_release_with_a_query_in_flight_retires_the_connection() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 1)!
	defer {
		p.close()
	}
	fds := open_fds()
	i := p.acquire() or { panic('acquire') }
	old_fd := p.fd(i)
	mut c := p.conn(i)
	assert c.submit('select 1', []?[]u8{})!
	c.async_flush() or {}
	// The borrower gives up without parking: the reply to `select 1` must
	// never reach the next borrower.
	p.release(i)
	assert p.is_broken(i)
	assert c.inflight_count() == 0
	if _ := p.acquire() {
		assert false, 'a retired connection was handed out'
	}
	assert settle(mut p, fn (p &PgPool) bool {
		return p.healthy() == 1
	}), 'not re-dialed'
	// A new socket, on the dead one's number (the lowest free fd).
	assert p.fd(i) == old_fd
	assert open_fds() == fds
	j := p.acquire() or { panic('re-dialed') }
	assert run_one(mut p, j, 2)! == 2
	p.release(j)
	assert !p.is_broken(j)
}

fn test_a_dead_connection_fails_at_most_one_request() {
	if !testkit.fake_pg_available() {
		return
	}
	// Every connection is closed by the server 50 ms after its first reply.
	mut fake := testkit.start_fake_pg(['--close', 'delayed'])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 2)!
	defer {
		p.close()
	}
	mut ok := 0
	mut failed := 0
	for n in 1 .. 7 {
		i := p.acquire() or {
			failed++ // nothing healthy left (no maintain() here: no re-dial)
			continue
		}
		v := run_one(mut p, i, n) or {
			failed++
			p.release(i)
			continue
		}
		assert v == n
		ok++
		p.release(i)
		time.sleep(100 * time.millisecond) // the server closes it meanwhile
	}
	// Two connections answer once each, then die; each death costs at most
	// one request. (Before: the dead slot 0 was handed out again and again.)
	assert ok == 2
	assert p.healthy() == 0
}

fn test_maintain_redials_off_the_request_path() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'delayed'])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 2)!
	defer {
		p.close()
	}
	assert p.scram.computed == 1 // PBKDF2 once for the whole pool
	fds := open_fds()
	for n in 1 .. 9 {
		i := p.acquire() or { panic('no healthy slot at request ${n}') }
		assert run_one(mut p, i, n)! == n
		p.release(i)
		time.sleep(80 * time.millisecond) // the server closes the connection
		// maintain()'s idle probe (about once a second; forced here) finds it
		// closed and re-dials it: healthy again.
		p.next_probe = 0
		assert settle(mut p, fn (p &PgPool) bool {
			return p.healthy() == 2
		}), 'not re-dialed after request ${n}'
	}
	assert fake.stat('authenticated') >= 2 + 8
	assert p.scram.computed == 1, 're-dials reuse the SCRAM keys'
	assert open_fds() == fds, 'a re-dial leaked an fd'
}

fn test_maintain_never_blocks_on_a_dead_server_and_backs_off() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	mut p := PgPool.connect(pool_cfg(fake.port), 2)!
	defer {
		p.close()
	}
	fake.stop() // the server is gone: its connections close
	time.sleep(50 * time.millisecond)
	p.next_probe = 0
	fds := open_fds()
	mut slowest := i64(0)
	mut gaps := []u64{}
	mut last_failures := 0
	for _ in 0 .. 600 {
		sw := time.new_stopwatch()
		p.maintain()
		el := sw.elapsed().microseconds()
		if el > slowest {
			slowest = el
		}
		r := p.retry[0]
		if r.failures > last_failures {
			gaps << r.next_try - time.sys_mono_now()
			last_failures = r.failures
		}
		time.sleep(2 * time.millisecond)
	}
	assert p.healthy() == 0
	assert slowest < 20_000, 'maintain() blocked ${slowest} us'
	assert last_failures >= 3, 'only ${last_failures} attempts'
	// Exponential with jitter: attempt k waits in [d/2, d], d = 20 ms * 2^(k-1).
	for k, g in gaps {
		d := u64(20_000_000) << u32(k)
		cap := u64(5_000_000_000)
		dd := if d > cap { cap } else { d }
		assert g <= dd, 'attempt ${k + 1}: ${g} ns > ${dd}'
		assert g + 5_000_000 >= dd / 2, 'attempt ${k + 1}: ${g} ns < ${dd / 2}'
	}
	assert open_fds() <= fds, 'failed dials leaked fds'
}

fn test_a_hostname_whose_addresses_all_failed_is_re_resolved_off_the_worker() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	mut p := PgPool.connect(ConnConfig{
		...pool_cfg(fake.port)
		host: 'localhost'
	}, 1)!
	defer {
		p.close()
	}
	fake.stop() // every address of localhost now refuses
	time.sleep(50 * time.millisecond)
	p.next_probe = 0
	fds := open_fds()
	// Each failed round over the addresses re-resolves the name on a helper
	// thread; maintain() only polls for the result.
	for _ in 0 .. 1500 {
		sw := time.new_stopwatch()
		p.maintain()
		assert sw.elapsed().milliseconds() < 20, 'maintain() blocked'
		if p.resolutions >= 2 && p.resolving == unsafe { nil } {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	assert p.resolutions >= 2, 'resolutions: ${p.resolutions}'
	assert p.resolving == unsafe { nil }, 'a finished resolution was not collected'
	assert p.addrs.len >= 1
	assert p.healthy() == 0
	assert open_fds() <= fds, 'failed dials leaked fds'
}

fn test_a_broken_connection_is_not_redialed_while_queries_are_in_flight() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--hang-after', '1'])!
	defer {
		fake.stop()
	}
	mut p := PgPool.connect(pool_cfg(fake.port), 1)!
	defer {
		p.close()
	}
	mut c := p.conn(0)
	old_fd := c.fd
	assert c.submit('select 1', []?[]u8{})! // never answered
	c.async_flush() or {}
	c.mark_broken()
	for _ in 0 .. 20 {
		p.maintain()
	}
	// Its parked request has not had its outcome yet: the fd it is parked on
	// must stay open and unchanged.
	assert p.fd(0) == old_fd
	assert C.fcntl(old_fd, C.F_GETFD, 0) != -1
	// The outcome comes (unknown), the FIFO empties, then the re-dial runs.
	if _ := c.async_on_readable() {
		assert false, 'the query was abandoned'
	}
	assert c.inflight_count() == 0
	assert settle(mut p, fn (p &PgPool) bool {
		return p.healthy() == 1
	})
}
