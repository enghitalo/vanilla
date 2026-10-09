module pg_async

import tls
import time

// PgPool is a per-worker pool of PostgreSQL connections. Each worker owns its
// own pool — no cross-worker sharing, so no locks (the make_state model). The
// connections are brought up (connect + SCRAM) blocking at init, then flipped to
// non-blocking for the reactor-driven query path. v1: one in-flight query per
// connection (no pipelining-while-busy), so a query needs a fully idle slot.
//
// A connection the server closes (restart, failover, pg_terminate_backend, an
// idle or lifetime timeout) breaks (PgConn.is_broken): acquire() and
// acquire_pipelined() skip it and re-dial it in place, non-blocking, once the
// requests parked on it have collected their errors (redial.v). So a dead
// connection costs at most the queries that were already on it — the other
// slots keep serving, and the slot comes back on its own.
//
// With max_lifetime_ms, maintain() also recycles connections that have been up
// that long, before the server's own cap closes them under a query: one at a
// time, out of the idle set, so no request ever waits on its re-dial
// (maintenance.v).

pub struct PgPool {
mut:
	conns []PgConn
	idle  []bool     // idle[i] ⇒ conns[i] is free to take a query
	cfg   ConnConfig // to re-dial a lost connection
	scram &ScramCache = unsafe { nil } // PBKDF2 result shared by every connection and re-dial
	// tls_cfg is the client TLS config every connection's session comes from
	// (ssl_mode != .disable): the trusted CAs are parsed once per pool, not
	// per connection or per re-dial.
	tls_cfg &tls.Config = unsafe { nil }
	// The maintenance timer (start_maintenance), -1 if none; closed tells its
	// next tick to stop.
	timer_fd int = -1
	closed   bool
	// clock is the monotonic time of the last maintain() tick: release()
	// compares lifetime deadlines with it, so the query path reads no clock.
	clock u64
	// recycling is the connection being recycled for max_lifetime_ms (-1 if
	// none): the pool holds it out of the idle set until maintain() has
	// re-dialed it.
	recycling int = -1
}

// PgPool.connect brings up `size` connections (size >= 1) and returns a ready
// pool. On any failure it closes whatever it already opened.
pub fn PgPool.connect(cfg ConnConfig, size int) !PgPool {
	if size < 1 {
		return error('pg pool: size must be >= 1')
	}
	check_startup_params(cfg.params) or { return error('pg pool: ${err}') }
	mut tls_cfg := &tls.Config(unsafe { nil })
	if cfg.ssl_mode != .disable {
		tls_cfg = new_tls_config(&cfg) or { return error('pg pool: ${err}') }
	}
	mut conns := []PgConn{cap: size}
	scram := &ScramCache{}
	for i in 0 .. size {
		mut c := PgConn{
			recv_buf:    []u8{cap: 16 * 1024}
			scram_cache: scram
			tls_cfg:     tls_cfg
		}
		c.bring_up(&cfg) or {
			c.teardown()
			close_all(mut conns)
			free_tls_config(tls_cfg)
			return error('pg pool: connection ${i} failed: ${err}')
		}
		c.set_nonblocking() or {
			c.close()
			close_all(mut conns)
			free_tls_config(tls_cfg)
			return error('pg pool: set_nonblocking on connection ${i} failed: ${err}')
		}
		c.expires_at = c.lifetime_deadline(&cfg, time.sys_mono_now())
		conns << c
	}
	return PgPool{
		conns:   conns
		idle:    []bool{len: size, init: true}
		cfg:     cfg
		scram:   scram
		tls_cfg: tls_cfg
	}
}

fn free_tls_config(c &tls.Config) {
	if c != unsafe { nil } {
		c.free()
	}
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

// acquire returns the index of an idle, live connection (marking it busy), or
// none if every connection is busy or broken (the caller sheds load — e.g. 503
// — or queues). An idle broken slot it passes gets its re-dial advanced one
// non-blocking step, and is taken the moment it is ready again.
//
// A connection that still carries pipelined queries (acquire_pipelined) is
// not idle for acquire(), even though nobody holds it exclusively: the
// borrower's release() would find those queries in flight and retire the
// connection, failing the requests they belong to.
pub fn (mut p PgPool) acquire() ?int {
	for i in 0 .. p.conns.len {
		if p.idle[i] && p.conns[i].inflight.len == 0
			&& (p.conns[i].state == .ready || p.conns[i].redial(p.cfg)) {
			p.idle[i] = false
			return i
		}
	}
	return none
}

// release returns a connection to the idle set (call once its query completes,
// successfully or not). A connection released with a query still in flight —
// the borrower gave up on it, e.g. after a failed or partial flush — is retired
// instead of reused: its late reply would go to the next borrower. It is
// re-dialed like a lost one. A connection past its max_lifetime_ms (as of the
// last maintain() tick) is kept by the pool instead, and recycled by
// maintain() before anyone takes it again.
pub fn (mut p PgPool) release(idx int) {
	if idx >= 0 && idx < p.idle.len {
		if p.conns[idx].inflight.len > 0 {
			p.conns[idx].lose('released with a query in flight')
			p.conns[idx].inflight.clear()
		}
		if p.conns[idx].expires_at <= p.clock && p.recycling < 0 {
			p.recycling = idx
			return
		}
		p.idle[idx] = true
	}
}

// lifetime_deadline is when a connection that came up at `now` is due for
// recycling: max_u64 (never) unless cfg.max_lifetime_ms is set. A random share
// of lifetime_jitter_ms comes off it, so connections opened together (every
// worker's pool, at startup) spread over the jitter instead of coming due in
// the same tick. The share hashes the clock with the connection's address
// (splitmix64): per connection, no shared RNG, no lock, no allocation.
fn (c &PgConn) lifetime_deadline(cfg &ConnConfig, now u64) u64 {
	if cfg.max_lifetime_ms <= 0 {
		return max_u64
	}
	life := u64(cfg.max_lifetime_ms) * u64(time.millisecond)
	mut span := if cfg.lifetime_jitter_ms > 0 {
		u64(cfg.lifetime_jitter_ms) * u64(time.millisecond)
	} else {
		u64(0)
	}
	if span >= life {
		span = life - 1 // a connection always gets some lifetime
	}
	return now + life - splitmix64(now ^ u64(voidptr(c))) % (span + 1)
}

// splitmix64 is one round of the SplitMix64 generator's output mix (Steele,
// Lea and Flood, 2014): nearby inputs (two clock readings, two addresses)
// come out unrelated.
@[inline]
fn splitmix64(x u64) u64 {
	mut z := x + 0x9e37_79b9_7f4a_7c15
	z = (z ^ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ^ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ^ (z >> 31)
}

// acquire_pipelined returns the index of the connection with the FEWEST in-flight
// queries (the shortest pipeline), or none if every connection is already at the
// max_inflight cap (the caller sheds). Unlike acquire(), it does NOT take a
// connection exclusively: a connection multiplexes up to max_inflight queries, so
// several parked requests share one. Depth is read straight from the connection
// (no idle bookkeeping), and an idle connection (depth 0) is taken immediately.
// This is the pooling shape for cross-request pipelining: with only a few
// connections per worker, N in-flight queries each lifts the per-worker DB
// concurrency ceiling to conns×N without needing a large pool.
//
// A connection held exclusively by acquire() is never shared: its borrower may
// hold it across several queries (BEGIN … COMMIT over park/resume, with no
// query in flight in between), and a pipelined query would land inside that
// transaction.
//
// Broken connections are skipped, and re-dialed once their in-flight count is
// back to 0 — which relies on the FIFO contract every pipelined caller already
// keeps: a request that submitted a query parks on the connection and consumes
// its reply (or error) with async_on_readable, even when the flush failed.
pub fn (mut p PgPool) acquire_pipelined() ?int {
	mut best := -1
	mut best_depth := max_inflight
	for i in 0 .. p.conns.len {
		if !p.idle[i] {
			continue // held by acquire(): its borrower may be mid-transaction
		}
		if p.conns[i].state != .ready && !p.conns[i].redial(p.cfg) {
			continue
		}
		d := p.conns[i].inflight_count()
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
// and watches for readiness.
pub fn (p &PgPool) fd(idx int) int {
	return p.conns[idx].fd
}

// close terminates every connection in the pool, then frees its TLS config.
pub fn (mut p PgPool) close() {
	p.closed = true // a running maintenance timer stops at its next tick
	close_all(mut p.conns)
	free_tls_config(p.tls_cfg)
	p.tls_cfg = unsafe { nil }
}
