module pg_async

import sync.stdatomic
import time

// PgPool is a per-worker pool of PostgreSQL connections. Each worker owns its
// own pool — no cross-worker sharing, so no locks (the make_state model). The
// connections are brought up (connect + SCRAM) blocking at init; the query path
// is non-blocking and reactor-driven.
//
// HEALTH. A connection breaks when the server closes it (a restart, a
// failover, pg_terminate_backend, idle_session_timeout, a managed database's
// maximum connection lifetime), resets, sends a FATAL or desyncs. acquire()
// and acquire_pipelined() never hand out a broken connection; its in-flight
// queries end through their continuations (PgConn.async_on_readable); then
// maintain() re-dials it — off the request path, without blocking: a
// non-blocking connect and handshake stepped from a timer, exponential
// backoff with jitter between failed attempts. The pool keeps the ConnConfig
// (and so the password) for that: it is the one place that holds it.

pub struct PgPool {
mut:
	conns  []PgConn
	idle   []bool // idle[i] ⇒ conns[i] is not held by acquire() (free to take a query)
	cursor int    // where acquire()'s round-robin scan starts
	cfg    ConnConfig
	addrs  []Addr // the server's addresses, resolved at bring-up
	retry  []Retry
	scram  &ScramCache = unsafe { nil }
	rng    u64 // xorshift state for the backoff jitter (per pool, so per worker)
	// next idle health probe (monotonic ns); see maintain
	next_probe u64
	// Background re-resolution of a hostname whose cached addresses all
	// failed: getaddrinfo blocks on DNS, so it runs on a helper thread and
	// maintain() picks the result up.
	resolving   &Resolution = unsafe { nil }
	resolver    thread
	resolutions int // background re-resolutions started
	timer_fd    int = -1 // the maintenance timer (start_maintenance), -1 if none
	closed      bool
}

// Retry is one slot's re-dial bookkeeping.
struct Retry {
mut:
	failures int // consecutive failed attempts (backoff exponent)
	next_try u64 // monotonic ns: the earliest next attempt
	addr     int // the address the current / next attempt uses
}

// Resolution is one background getaddrinfo: the helper thread fills addrs,
// then publishes done (seq_cst); maintain() reads addrs only after it sees done.
@[heap]
struct Resolution {
mut:
	done  i64
	addrs []Addr
}

// dial_tick_ms is how soon maintain() wants to run again while a dial is in
// flight; idle_tick_ms between idle health probes.
const dial_tick_ms = 2

const idle_tick_ms = 1000

// drain_tick_ms: how soon to look again at a broken slot whose in-flight
// queries are still being failed through their continuations.
const drain_tick_ms = 10

// PgPool.connect brings up `size` connections (size >= 1) and returns a ready
// pool. On any failure it closes whatever it already opened.
pub fn PgPool.connect(cfg ConnConfig, size int) !PgPool {
	if size < 1 {
		return error('pg pool: size must be >= 1')
	}
	mut conns := []PgConn{cap: size}
	mut c := new_conn()
	addrs := resolve(cfg.host, cfg.port) or { return c.dial_fail(err.msg(), 0) }
	mut scram := &ScramCache{}
	for i in 0 .. size {
		if i > 0 {
			c = new_conn()
		}
		// A failure is the connection's PgError (kind connect).
		c.dial_blocking(addrs, &cfg, mut scram) or {
			close_all(mut conns)
			return err
		}
		conns << c
	}
	mut p := PgPool{
		conns: conns
		idle:  []bool{len: size, init: true}
		cfg:   cfg
		addrs: addrs
		retry: []Retry{len: size}
		scram: scram
	}
	p.rng = (u64(voidptr(scram)) ^ time.sys_mono_now()) | 1
	return p
}

fn close_all(mut conns []PgConn) {
	for mut c in conns {
		c.close()
	}
}

// new_pool brings up a pool and returns it on the heap — convenient for a
// make_state callback that hands the pool back to the worker as an opaque
// voidptr (the make_state / ctx.state contract).
pub fn new_pool(cfg ConnConfig, size int) !&PgPool {
	pool := PgPool.connect(cfg, size)!
	return &pool
}

// size is the number of connections in the pool.
pub fn (p &PgPool) size() int {
	return p.conns.len
}

// healthy is the number of connections that are not broken.
pub fn (p &PgPool) healthy() int {
	mut n := 0
	for i in 0 .. p.conns.len {
		if !p.conns[i].broken {
			n++
		}
	}
	return n
}

// idx_of_fd maps a socket fd back to its connection index — used by a resume
// continuation to find which connection woke it (ac.ready_fd) without threading
// the index through udata.
pub fn (p &PgPool) idx_of_fd(fd int) ?int {
	for i in 0 .. p.conns.len {
		if p.conns[i].fd == fd {
			return i
		}
	}
	return none
}

// acquire returns the index of an idle, healthy connection (marking it busy),
// or none if every connection is busy or broken (the caller sheds load — e.g.
// 503 — or queues). Round-robin: the scan starts after the last connection
// handed out, so load (and a failure) does not concentrate on slot 0.
@[direct_array_access]
pub fn (mut p PgPool) acquire() ?int {
	n := p.conns.len
	mut i := p.cursor
	for _ in 0 .. n {
		if i >= n {
			i = 0
		}
		if p.idle[i] && !p.conns[i].broken {
			p.idle[i] = false
			p.cursor = i + 1
			return i
		}
		i++
	}
	return none
}

// release returns a connection to the idle set: call it once its query has
// its outcome, whatever it is (a broken connection is re-dialed by
// maintain()), or when giving up on the query without parking for it. In
// that case, a query still in flight would hand its reply to the next
// borrower, so the connection is retired instead: broken, its queries
// dropped (nothing waits for them), then re-dialed.
pub fn (mut p PgPool) release(idx int) {
	if idx >= 0 && idx < p.idle.len {
		if p.conns[idx].inflight.len > 0 {
			p.conns[idx].mark_broken_reason('pg: connection released with a query in flight')
			p.conns[idx].drop_inflight()
		}
		p.idle[idx] = true
	}
}

// acquire_pipelined returns the index of the healthy connection with the
// FEWEST in-flight queries (the shortest pipeline), or none if every healthy
// connection is already at the max_inflight cap (the caller sheds). Unlike
// acquire(), it does NOT take a connection exclusively: a connection
// multiplexes up to max_inflight queries, so several parked requests share
// one. Depth is read straight from the connection, and an idle connection
// (depth 0) is taken immediately. A connection held by acquire() is never
// shared. This is the pooling shape for cross-request pipelining: with only a
// few connections per worker, N in-flight queries each lifts the per-worker DB
// concurrency ceiling to conns×N without needing a large pool.
@[direct_array_access]
pub fn (mut p PgPool) acquire_pipelined() ?int {
	mut best := -1
	mut best_depth := max_inflight
	for i in 0 .. p.conns.len {
		if p.conns[i].broken || !p.idle[i] {
			continue
		}
		d := p.conns[i].inflight.len
		if d == 0 {
			return i // idle connection — optimal, take it now
		}
		if d < best_depth {
			best = i
			best_depth = d
		}
	}
	if best < 0 {
		return none
	}
	return best
}

// conn returns a mutable reference to connection `idx`. The connection array is
// fixed after connect(), so the reference stays valid for the pool's lifetime.
pub fn (mut p PgPool) conn(idx int) &PgConn {
	return &p.conns[idx]
}

// fd returns the raw socket fd of connection `idx` — what the reactor registers
// and watches for readiness. A re-dial changes it.
pub fn (p &PgPool) fd(idx int) int {
	return p.conns[idx].fd
}

// is_broken reports whether connection `idx` is broken (or being re-dialed).
pub fn (p &PgPool) is_broken(idx int) bool {
	return p.conns[idx].broken
}

// maintain is the pool's off-request-path upkeep. Call it periodically from
// this worker (start_maintenance does, from a timer; on a backend without
// on_worker_start, call it from handlers — it is cheap when there is nothing
// to do). It never blocks:
//   - a broken connection whose in-flight queries are all drained and that
//     no acquire() holds is closed and re-dialed: a non-blocking connect and
//     handshake, advanced one step per call; a failed attempt is retried
//     after an exponential backoff with jitter, trying the next address
//     first; a hostname whose every address failed is re-resolved on a
//     helper thread;
//   - about once a second, idle connections are probed (one
//     recv(MSG_PEEK)): one the server closed meanwhile breaks now, before a
//     request finds it dead.
// Returns how many milliseconds until it next has work: re-arm the timer with
// it.
pub fn (mut p PgPool) maintain() int {
	if p.closed {
		return idle_tick_ms
	}
	now := time.sys_mono_now()
	p.collect_resolution()
	probe := now >= p.next_probe
	if probe {
		p.next_probe = now + u64(idle_tick_ms) * 1_000_000
	}
	mut next := idle_tick_ms
	for i in 0 .. p.conns.len {
		if p.conns[i].hs != .idle {
			p.step_redial(i, now)
			if p.conns[i].hs != .idle {
				next = min_ms(next, dial_tick_ms)
			} else if p.conns[i].broken {
				next = min_ms(next, ms_until(p.retry[i].next_try, now))
			}
			continue
		}
		if p.conns[i].broken {
			if !p.idle[i] || p.conns[i].inflight.len > 0 {
				// Still draining: its parked requests get their outcomes first.
				next = min_ms(next, drain_tick_ms)
				continue
			}
			if now < p.retry[i].next_try {
				next = min_ms(next, ms_until(p.retry[i].next_try, now))
				continue
			}
			p.start_redial(i, now)
			next = min_ms(next, if p.conns[i].hs != .idle {
				dial_tick_ms
			} else {
				ms_until(p.retry[i].next_try, now)
			})
			continue
		}
		if probe && p.idle[i] {
			p.conns[i].probe_idle()
			if p.conns[i].broken {
				next = min_ms(next, dial_tick_ms) // re-dial on the next call
			}
		}
	}
	return next
}

fn min_ms(a int, b int) int {
	return if a < b { a } else { b }
}

// ms_until is how many milliseconds (at least 1) until monotonic time t.
fn ms_until(t u64, now u64) int {
	if t <= now {
		return 1
	}
	return int((t - now) / 1_000_000) + 1
}

// start_redial closes the broken connection's socket and starts a
// non-blocking dial on the slot (reusing its buffers). The fd is closed only
// here: nothing is in flight on it and no acquire() holds it, so no parked
// request and no watch refers to it any more.
fn (mut p PgPool) start_redial(i int, now u64) {
	mut c := &p.conns[i]
	c.close_socket()
	if p.addrs.len == 0 {
		p.redial_failed(i, now, true)
		return
	}
	a := p.addrs[p.retry[i].addr % p.addrs.len]
	c.start_connect(&a, &p.cfg, now) or {
		p.redial_failed(i, now, true)
		return
	}
	c.broken = true // until ReadyForQuery
	p.step_redial(i, now)
}

// step_redial advances slot i's dial by one non-blocking step.
fn (mut p PgPool) step_redial(i int, now u64) {
	mut c := &p.conns[i]
	was_connecting := c.hs == .connecting
	w := c.dial_step(&p.cfg, mut p.scram, now) or {
		c.abort_dial()
		p.redial_failed(i, now, was_connecting)
		return
	}
	if w == .done {
		p.retry[i] = Retry{
			addr: p.retry[i].addr
		}
	}
}

// redial_failed schedules slot i's next attempt: at once on the next address
// when this one did not connect, else after the backoff (the address list
// starts over; a hostname is re-resolved when every address failed to connect).
fn (mut p PgPool) redial_failed(i int, now u64, connect_phase bool) {
	mut r := &p.retry[i]
	if connect_phase && r.addr + 1 < p.addrs.len {
		r.addr++
		r.next_try = now
		return
	}
	if connect_phase {
		p.start_resolution()
	}
	r.addr = 0
	r.failures++
	r.next_try = now + p.backoff_ns(r.failures)
}

// backoff_ns is the delay before attempt number `failures` + 1: exponential
// from redial_backoff_ms, capped at redial_backoff_max_ms, with equal jitter
// (half fixed, half random) so the workers' slots, all broken by the same
// event, do not reconnect in lockstep.
fn (mut p PgPool) backoff_ns(failures int) u64 {
	base := u64(if p.cfg.redial_backoff_ms > 0 { p.cfg.redial_backoff_ms } else { 1 })
	cap := u64(if p.cfg.redial_backoff_max_ms > 0 { p.cfg.redial_backoff_max_ms } else { 1 })
	mut d := base
	for k := 1; k < failures && d < cap; k++ {
		d *= 2
	}
	if d > cap {
		d = cap
	}
	half := d * 1_000_000 / 2
	return half + p.next_rand() % (half + 1)
}

// next_rand is xorshift64*: the pool's own generator (never V's shared rand,
// which every worker would contend on).
fn (mut p PgPool) next_rand() u64 {
	mut x := p.rng
	x ^= x >> 12
	x ^= x << 25
	x ^= x >> 27
	p.rng = x
	return x * u64(0x2545F4914F6CDD1D)
}

// start_resolution re-resolves the host on a helper thread, unless it is an
// address literal (nothing to re-resolve) or a resolution is running.
fn (mut p PgPool) start_resolution() {
	if p.resolving != unsafe { nil } || is_ip_literal(p.cfg.host) {
		return
	}
	p.resolving = &Resolution{}
	p.resolver = spawn resolve_into(p.cfg.host, p.cfg.port, p.resolving)
	p.resolutions++
}

fn resolve_into(host string, port int, r &Resolution) {
	mut res := unsafe { r }
	res.addrs = resolve(host, port) or { []Addr{} }
	stdatomic.store_i64(&res.done, 1)
}

// collect_resolution takes a finished background resolution's addresses.
fn (mut p PgPool) collect_resolution() {
	if p.resolving == unsafe { nil } || stdatomic.load_i64(&p.resolving.done) == 0 {
		return
	}
	p.resolver.wait()
	if p.resolving.addrs.len > 0 {
		p.addrs = p.resolving.addrs
	}
	p.resolving = unsafe { nil }
}

// is_ip_literal reports whether host is a numeric IPv4/IPv6 address.
fn is_ip_literal(host string) bool {
	if host.contains(':') {
		return true
	}
	for ch in host {
		if !(ch.is_digit() || ch == `.`) {
			return false
		}
	}
	return host.len > 0
}

// close terminates every connection in the pool. A maintenance timer stops
// at its next tick. Like every PgPool method, call it from the worker that
// owns the pool (or once the server has stopped).
pub fn (mut p PgPool) close() {
	p.closed = true
	close_all(mut p.conns)
	if p.resolving != unsafe { nil } {
		p.resolver.wait()
		p.resolving = unsafe { nil }
	}
}
