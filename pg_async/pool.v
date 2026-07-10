module pg_async

// PgPool is a per-worker pool of PostgreSQL connections. Each worker owns its
// own pool — no cross-worker sharing, so no locks (the make_state model). The
// connections are brought up (connect + SCRAM) blocking at init, then flipped to
// non-blocking for the reactor-driven query path. v1: one in-flight query per
// connection (no pipelining-while-busy), so a query needs a fully idle slot.

pub struct PgPool {
mut:
	conns []PgConn
	idle  []bool // idle[i] ⇒ conns[i] is free to take a query
}

// PgPool.connect brings up `size` connections (size >= 1) and returns a ready
// pool. On any failure it closes whatever it already opened.
pub fn PgPool.connect(cfg ConnConfig, size int) !PgPool {
	if size < 1 {
		return error('pg pool: size must be >= 1')
	}
	mut conns := []PgConn{cap: size}
	for i in 0 .. size {
		mut c := PgConn.connect(cfg) or {
			close_all(mut conns)
			return error('pg pool: connection ${i} failed: ${err}')
		}
		c.set_nonblocking() or {
			c.close()
			close_all(mut conns)
			return error('pg pool: set_nonblocking on connection ${i} failed: ${err}')
		}
		conns << c
	}
	return PgPool{
		conns: conns
		idle:  []bool{len: size, init: true}
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

// acquire returns the index of an idle connection (marking it busy), or none if
// every connection is busy (the caller sheds load — e.g. 503 — or queues).
pub fn (mut p PgPool) acquire() ?int {
	for i in 0 .. p.conns.len {
		if p.idle[i] {
			p.idle[i] = false
			return i
		}
	}
	return none
}

// release returns a connection to the idle set (call once its query completes).
pub fn (mut p PgPool) release(idx int) {
	if idx >= 0 && idx < p.idle.len {
		p.idle[idx] = true
	}
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
pub fn (mut p PgPool) acquire_pipelined() ?int {
	mut best := -1
	mut best_depth := max_inflight
	for i in 0 .. p.conns.len {
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

// close terminates every connection in the pool.
pub fn (mut p PgPool) close() {
	close_all(mut p.conns)
}
