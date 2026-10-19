// vtest build: linux
module pg_async

import sync.stdatomic
import time
import testkit
import transport

// Re-dials of a pool that follows a transport.Resolver (vanilla#351), against
// pg_async/testdata/fake_pg.py: they dial the address table the Resolver's
// thread keeps fresh, so the worker never resolves the host after startup and
// never waits on a slow lookup; a lost connection and a max_lifetime_ms
// recycle both follow the table; a pool that follows none resolves at every
// attempt, as before; and failed attempts ask for refreshes without a lookup
// per attempt. The test thread plays the worker. Linux only: the lookups are
// told apart by thread id (gettid). Skipped without python3 unless
// VANILLA_REQUIRE_FAKE_PG is set (CI).

// Lookup is a scripted ConnConfig.resolve: it answers 127.0.0.1 at `port`,
// after waiting slow_ms, and counts its calls by thread: the worker's (the
// thread that built the pool) and the others' (the Resolver's).
@[heap]
struct Lookup {
mut:
	port         i64 // atomic
	slow_ms      i64 // atomic
	worker       u32 // set before any other thread calls
	worker_calls i64 // atomic
	other_calls  i64 // atomic
}

// tid is the calling thread's id.
fn tid() u32 {
	return C.gettid()
}

fn (l &Lookup) resolve_fn() transport.ResolveFn {
	return fn [l] (host string, port int) []transport.Addr {
		if tid() == l.worker {
			stdatomic.add_i64(&l.worker_calls, 1)
		} else {
			stdatomic.add_i64(&l.other_calls, 1)
		}
		slow := stdatomic.load_i64(&l.slow_ms)
		if slow > 0 {
			time.sleep(time.Duration(slow) * time.millisecond)
		}
		a := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&l.port))) or { return [] }
		return [a]
	}
}

fn (l &Lookup) on_worker() i64 {
	return stdatomic.load_i64(&l.worker_calls)
}

fn (l &Lookup) elsewhere() i64 {
	return stdatomic.load_i64(&l.other_calls)
}

fn new_lookup(port int) &Lookup {
	return &Lookup{
		port:   port
		worker: tid()
	}
}

// lookup_cfg reaches the fake through `l`: the host is a name getaddrinfo is
// never asked about.
fn lookup_cfg(l &Lookup) ConnConfig {
	return ConnConfig{
		host:     'db.test'
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
		resolve:  l.resolve_fn()
	}
}

fn port_of(a transport.Addr) int {
	return int(a.data[2]) << 8 | int(a.data[3])
}

fn ms_since(t u64) i64 {
	return i64(time.sys_mono_now() - t) / i64(time.millisecond)
}

// rt_query runs one pipelined query on connection i and returns its int4.
fn rt_query(mut pool PgPool, i int, query string) !int {
	mut c := pool.conn(i)
	if !c.async_submit(query, []?[]u8{}) {
		return error('the connection refused the query')
	}
	for c.async_wants_write() {
		c.async_flush()!
	}
	deadline := time.sys_mono_now() + 2 * u64(time.second)
	for time.sys_mono_now() < deadline {
		poll := c.async_on_readable()!
		if poll.ready {
			mut it := poll.result.rows()
			row := it.next() or { return error('no row') }
			v := row.int4(0)!
			return int(v)
		}
		C.pg_async_wait(c.fd, C.POLLIN, 10)
	}
	return error('the query did not complete')
}

// rt_stat waits for a fake-server counter: the fake counts on its own
// threads, a moment after the client moved on.
fn rt_stat(fake &testkit.FakePg, key string, want int) int {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 && fake.stat(key) < want {
		time.sleep(5 * time.millisecond)
	}
	return fake.stat(key)
}

// drive runs maintain() on the pools as their worker's timer would, until
// done() or `budget_ms`, and returns the longest maintain() call in ms.
fn drive(mut pools []&PgPool, budget_ms i64, done fn () bool) i64 {
	mut slowest := i64(0)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < budget_ms && !done() {
		for mut p in pools {
			t := time.sys_mono_now()
			p.maintain()
			ms := ms_since(t)
			if ms > slowest {
				slowest = ms
			}
		}
		time.sleep(2 * time.millisecond)
	}
	return slowest
}

// wait_table runs maintain() until it has taken a Resolver update that
// points at `port`.
fn wait_table(mut p PgPool, port int) bool {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 {
		p.maintain()
		if p.addrs.len == 1 && port_of(p.addrs[0]) == port {
			return true
		}
		time.sleep(5 * time.millisecond)
	}
	return false
}

// The issue's first test: the Resolver's lookup takes 2 s on its thread. A
// connection is lost; the request that passes it starts its re-dial without
// waiting for any lookup and is answered on the other connection within
// milliseconds; the re-dial completes from the table while the thread is
// still looking up, and the worker never called the lookup after follow.
fn test_redial_never_waits_for_a_slow_resolver() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping resolver tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut l := new_lookup(fake.port)
	mut pool := new_pool(lookup_cfg(l), 2)!
	defer {
		pool.close()
	}
	mut r := transport.Resolver.new(20)!
	pool.follow(mut r)!
	boot_calls := l.on_worker() // the bring-up of 2 connections, and follow
	assert pool.addrs.len == 1 && port_of(pool.addrs[0]) == fake.port
	stdatomic.store_i64(&l.slow_ms, 2000) // every lookup from now on takes 2 s
	r.start()
	defer {
		r.stop() // waits for the lookup in flight
	}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 1000 && l.elsewhere() == 0 {
		time.sleep(time.millisecond)
	}
	assert l.elsewhere() > 0, 'the resolver thread never looked up'
	pool.conn(0).lose('test: the server went away')
	// A request on this worker: acquire_pipelined() passes connection 0 (its
	// re-dial starts) and takes connection 1, whose query answers at once.
	t := time.sys_mono_now()
	idx := pool.acquire_pipelined() or { panic('no connection') }
	step_ms := ms_since(t)
	assert idx == 1
	assert pool.conns[0].state != .broken, 'the re-dial did not start'
	assert rt_query(mut pool, idx, 'select 7')! == 7
	request_ms := ms_since(t)
	// The rest of the re-dial, as the maintenance timer drives it.
	mut pools := [pool]
	slowest := drive(mut pools, 3000, fn [pool] () bool {
		return pool.conns[0].state == .ready
	})
	redial_ms := ms_since(t)
	eprintln('acquire_pipelined: ${step_ms} ms, request on the other connection: ${request_ms} ms, re-dial: ${redial_ms} ms (slowest maintain(): ${slowest} ms) while each lookup takes 2000 ms')
	assert pool.conns[0].state == .ready, 'the re-dial did not complete'
	assert step_ms < 500 && request_ms < 500 && slowest < 500, 'the worker waited for the lookup'
	assert redial_ms < 1500, 'the re-dial waited for the lookup'
	assert rt_query(mut pool, 0, 'select 8')! == 8
	assert rt_stat(fake, 'authenticated', 3) == 3
	assert l.on_worker() == boot_calls, 'the worker looked the host up after follow'
}

// The issue's second test: the host moves (the lookup answers server B). The
// Resolver's update reaches the table through maintain(); then a lost
// connection's re-dial and a max_lifetime_ms recycle both go to B, without a
// lookup on the worker.
fn test_redial_and_recycle_follow_the_table() {
	if !testkit.fake_pg_available() {
		return
	}
	mut a := testkit.start_fake_pg([])!
	defer {
		a.stop()
	}
	mut b := testkit.start_fake_pg([])!
	defer {
		b.stop()
	}
	mut l := new_lookup(a.port)
	mut lost := new_pool(lookup_cfg(l), 1)!
	defer {
		lost.close()
	}
	mut aged := new_pool(ConnConfig{
		...lookup_cfg(l)
		max_lifetime_ms: 60_000
	}, 1)!
	defer {
		aged.close()
	}
	mut r := transport.Resolver.new(20)!
	lost.follow(mut r)!
	aged.follow(mut r)!
	if _ := lost.follow(mut r) {
		assert false, 'a pool followed a second resolver'
	}
	r.start()
	defer {
		r.stop()
	}
	stdatomic.store_i64(&l.port, b.port) // the server moved
	assert wait_table(mut lost, b.port), 'the update did not reach the table'
	assert wait_table(mut aged, b.port), 'the update did not reach the table'
	before := l.on_worker()
	lost.conn(0).lose('test: the server went away')
	aged.conns[0].expires_at = 0 // due for recycling now
	mut pools := [lost, aged]
	drive(mut pools, 3000, fn [lost, aged, b] () bool {
		return lost.conns[0].state == .ready && aged.recycling < 0
			&& aged.conns[0].state == .ready && b.stat('authenticated') >= 2
	})
	assert rt_stat(b, 'authenticated', 2) == 2, 'the re-dial and the recycle did not both reach B'
	assert a.stat('authenticated') == 2 // the two bring-ups only
	assert rt_query(mut lost, 0, 'select 1')! == 1
	assert rt_query(mut aged, 0, 'select 2')! == 2
	assert l.on_worker() == before, 'the worker looked the host up'
}

// The issue's third test: without a Resolver nothing changes. Each re-dial
// attempt resolves the host on the worker, so it reaches the server's new
// address at once.
fn test_redial_without_a_resolver_resolves_on_the_worker() {
	if !testkit.fake_pg_available() {
		return
	}
	mut a := testkit.start_fake_pg([])!
	defer {
		a.stop()
	}
	mut b := testkit.start_fake_pg([])!
	defer {
		b.stop()
	}
	mut l := new_lookup(a.port)
	mut pool := new_pool(lookup_cfg(l), 1)!
	defer {
		pool.close()
	}
	assert pool.addrs.len == 0
	stdatomic.store_i64(&l.port, b.port)
	before := l.on_worker()
	pool.conn(0).lose('test: the server went away')
	mut pools := [pool]
	drive(mut pools, 3000, fn [pool] () bool {
		return pool.conns[0].state == .ready
	})
	assert pool.conns[0].state == .ready
	assert rt_stat(b, 'authenticated', 1) == 1
	assert rt_query(mut pool, 0, 'select 3')! == 3
	assert l.on_worker() == before + 1, 'one attempt, one lookup on the worker'
	assert l.elsewhere() == 0
}

// A failover must not become a resolution storm: four pools of four
// connections (four workers) follow one Resolver whose lookup answers at
// once, and the database goes away. Every failed attempt asks for a refresh
// (about one per connection per second), and the Resolver answers them all
// with at most one lookup per refresh gap (1 s).
fn test_failed_redials_ask_without_a_lookup_storm() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop() // stopped below already: a no-op then
	}
	mut l := new_lookup(fake.port)
	mut r := transport.Resolver.new(60_000)! // only asks refresh within the test
	mut pools := []&PgPool{}
	for _ in 0 .. 4 {
		mut p := new_pool(lookup_cfg(l), 4)!
		p.follow(mut r)!
		pools << p
	}
	defer {
		for mut p in pools {
			p.close()
		}
	}
	r.start()
	defer {
		r.stop()
	}
	fake.stop() // gone: every connection is lost, every attempt refused
	for mut p in pools {
		for i in 0 .. p.size() {
			p.conn(i).lose('test: the server went away')
		}
	}
	window_ms := i64(3000)
	drive(mut pools, window_ms, fn () bool {
		return false
	})
	mut attempts := 0
	for p in pools {
		for c in p.conns {
			attempts += c.addr_cursor // one per failed attempt
		}
	}
	lookups := l.elsewhere()
	eprintln('${attempts} failed attempts in ${window_ms} ms asked for ${lookups} lookups')
	assert attempts >= 32, 'the re-dials did not keep trying'
	assert lookups >= 1, 'no failed attempt asked for a refresh'
	assert lookups <= window_ms / 1000 + 2, 'a lookup storm: ${lookups} lookups for ${attempts} failed attempts'
}

// Re-dials that only requests drive (acquire*() and no maintain(): a backend
// without start_maintenance, or a request that reaches the slot before the
// timer's tick) still dial the Resolver's latest addresses, because each
// attempt takes them first. The server moved from A to B while the
// connection was down: the first attempt, to A, is refused and asks; the
// next one, a backoff later, goes to B.
fn test_an_attempt_takes_the_latest_addresses_first() {
	if !testkit.fake_pg_available() {
		return
	}
	mut a := testkit.start_fake_pg([])!
	defer {
		a.stop()
	}
	mut b := testkit.start_fake_pg([])!
	defer {
		b.stop()
	}
	mut l := new_lookup(a.port)
	mut pool := new_pool(lookup_cfg(l), 1)!
	defer {
		pool.close()
	}
	mut r := transport.Resolver.new(60_000)! // only asks refresh within the test
	pool.follow(mut r)!
	r.start()
	defer {
		r.stop()
	}
	a.stop() // A is gone: its address refuses
	stdatomic.store_i64(&l.port, b.port) // the name now points at B
	pool.conn(0).lose('test: the server went away')
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 4000 && pool.conns[0].state != .ready {
		pool.acquire_pipelined() or {}
		time.sleep(2 * time.millisecond)
	}
	assert pool.conns[0].state == .ready, 'the re-dials never reached B'
	assert pool.conns[0].addr_cursor >= 1, 'no attempt failed first'
	assert l.elsewhere() >= 1, 'the failed attempt did not ask'
	assert rt_stat(b, 'authenticated', 1) == 1
	assert rt_query(mut pool, 0, 'select 4')! == 4
}

// Fail is whether the scripted password_fn below fails.
@[heap]
struct Fail {
mut:
	n i64 // atomic
}

fn C.bind(fd int, addr voidptr, len u32) int
fn C.listen(fd int, backlog int) int
fn C.getsockname(fd int, addr voidptr, len &u32) int

// silent_listener listens on 127.0.0.1 and never accepts: the kernel
// completes every connect, and nothing ever answers. Its fd and address.
// (Each call is made outside its check: -prod strips asserts.)
fn silent_listener() (int, transport.Addr) {
	mut a := transport.ip_addr('127.0.0.1', 0) or { panic('addr') }
	fd := C.socket(a.family, C.SOCK_STREAM, 0)
	bound := C.bind(fd, voidptr(&a.data[0]), a.len)
	listening := C.listen(fd, 16)
	mut sl := u32(128)
	named := C.getsockname(fd, voidptr(&a.data[0]), &sl)
	if fd < 0 || bound != 0 || listening != 0 || named != 0 {
		panic('cannot open a listener on 127.0.0.1')
	}
	return fd, a
}

// Only an attempt whose address failed asks for a refresh. One that never
// dialed (password_fn failed: a token service down) or that connected and
// then failed (a server that accepts and never answers the startup) asks
// nothing: the address answered, or was never tried, and an ask would
// re-resolve every host the Resolver follows (#366). A refused connect then
// asks.
fn test_only_an_address_failure_asks_for_a_refresh() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut l := new_lookup(fake.port)
	fail := &Fail{}
	mut pool := new_pool(ConnConfig{
		...lookup_cfg(l)
		password:           ''
		password_fn:        fn [fail] () !string {
			if stdatomic.load_i64(&fail.n) != 0 {
				return error('the token service is down')
			}
			return 'secret'
		}
		connect_timeout_ms: 300 // bounds a re-dial attempt
	}, 1)!
	defer {
		pool.close()
	}
	mut r := transport.Resolver.new(60_000)! // only asks refresh within the test
	pool.follow(mut r)!
	r.start()
	defer {
		r.stop()
	}
	mut pools := [pool]
	// Attempts at 0 and 1 s fail before dialing.
	stdatomic.store_i64(&fail.n, 1)
	pool.conn(0).lose('test: the server went away')
	drive(mut pools, 1200, fn () bool {
		return false
	})
	no_dial := pool.conns[0].addr_cursor
	// The attempt at 2 s connects to a listener that never answers, and
	// times out in the startup.
	stdatomic.store_i64(&fail.n, 0)
	lfd, silent := silent_listener()
	mut lfd_open := true
	defer {
		if lfd_open {
			C.close(lfd)
		}
	}
	pool.addrs[0] = silent // as if the Resolver had answered it
	drive(mut pools, 1500, fn () bool {
		return false
	})
	connected := pool.conns[0].addr_cursor - no_dial
	asked := l.elsewhere()
	// The attempt at 3.3 s is refused: it asks.
	C.close(lfd)
	lfd_open = false
	drive(mut pools, 1200, fn () bool {
		return false
	})
	eprintln('${no_dial} attempts without a password and ${connected} that connected and timed out asked for ${asked} lookups; a refused connect then asked for ${l.elsewhere()}')
	assert asked == 0, 'an attempt that reached no address, or that connected, asked'
	assert no_dial >= 1 && connected >= 1, 'the attempts did not fail as scripted'
	assert l.elsewhere() >= 1, 'a refused connect did not ask'
}
