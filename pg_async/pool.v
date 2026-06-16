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

// size is the number of connections in the pool.
pub fn (p &PgPool) size() int {
	return p.conns.len
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
