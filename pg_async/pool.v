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
// Transactions (tx.v): an explicit BEGIN … COMMIT goes on a connection taken
// with acquire(), never acquire_pipelined(); release() rolls back a
// connection left in a transaction before anyone else gets it.

// rollback_timeout bounds the wait for the ROLLBACK release() queues: a
// server that does not answer one within it is treated as lost, and the
// connection is re-dialed.
const rollback_timeout = u64(5 * time.second)

pub struct PgPool {
mut:
	conns []PgConn
	// idle[i] ⇒ conns[i] is free to take a query. False while acquire() holds
	// it, and while the ROLLBACK release() queued on it is in flight
	// (conns[i].rollback_deadline != 0).
	idle  []bool
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
}

// PgPool.connect brings up `size` connections (size >= 1) and returns a ready
// pool. On any failure it closes whatever it already opened.
pub fn PgPool.connect(cfg ConnConfig, size int) !PgPool {
	if size < 1 {
		return error('pg pool: size must be >= 1')
	}
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
// connection, failing the requests they belong to. Nor is one whose session
// is in a transaction nobody holds (a BEGIN sent through acquire_pipelined):
// the borrower would run inside it.
//
// acquire() is the borrow for an explicit transaction (BEGIN … COMMIT across
// park/resume): the connection is the borrower's alone until release(), and
// acquire_pipelined() never shares it.
pub fn (mut p PgPool) acquire() ?int {
	for i in 0 .. p.conns.len {
		if !p.idle[i] && (p.conns[i].rollback_deadline == 0 || !p.finish_rollback(i)) {
			continue // held, or its release-time ROLLBACK is still in flight
		}
		if p.conns[i].inflight.len == 0
			&& (p.conns[i].state == .ready || p.conns[i].redial(p.cfg))
			&& p.conns[i].ready_status == tx_idle {
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
// re-dialed like a lost one.
//
// A connection released inside a transaction (in_transaction: a BEGIN without
// its COMMIT or ROLLBACK — an error path, a continuation that bailed out, a
// client that disconnected mid-transaction — or a failed transaction block)
// must not reach the next borrower, who would run inside that transaction.
// release() queues a ROLLBACK on it and returns at once; the connection
// stays out of the idle set until that ROLLBACK's ReadyForQuery reports the
// session idle. Nobody is parked on it any more, so acquire(),
// acquire_pipelined() and maintain() read that reply as they pass it
// (finish_rollback). If the ROLLBACK fails or gets no answer within
// rollback_timeout, the connection is broken and re-dialed instead. The
// common release, of a connection not in a transaction, is just the flag.
pub fn (mut p PgPool) release(idx int) {
	if idx >= 0 && idx < p.idle.len {
		if p.conns[idx].inflight.len > 0 {
			p.conns[idx].lose('released with a query in flight')
			p.conns[idx].inflight.clear()
			p.conns[idx].rollback_deadline = 0
		} else if p.conns[idx].ready_status != tx_idle && p.conns[idx].state == .ready {
			p.start_rollback(idx)
			return
		}
		p.idle[idx] = true
	}
}

// start_rollback queues a ROLLBACK on connection idx, released inside a
// transaction, and keeps the slot out of the idle set until finish_rollback
// sees the session idle. Never waits: a ROLLBACK the socket does not take now
// is sent from finish_rollback, and a failed send breaks the connection,
// which finish_rollback then finds. Allocates nothing: the submit reuses the
// connection's buffers.
@[noinline]
fn (mut p PgPool) start_rollback(idx int) {
	p.idle[idx] = false
	mut c := p.conn(idx)
	if !c.async_submit('rollback', []?[]u8{}) {
		// Nothing is in flight on a live connection, so the submit fits; if it
		// ever does not, the session cannot be cleaned: re-dial it.
		c.lose('could not queue a ROLLBACK at release')
		p.idle[idx] = true
		return
	}
	c.async_flush() or {}
	c.rollback_deadline = time.sys_mono_now() + rollback_timeout
}

// finish_rollback advances the ROLLBACK start_rollback queued on connection i
// by one non-blocking step (send what the socket did not take, read what
// arrived) and reports whether the slot is back in the idle set: once that
// ROLLBACK's ReadyForQuery reports the session idle. A connection lost
// meanwhile, a ROLLBACK that failed, or one with no answer within
// rollback_timeout breaks the connection; the slot then goes back to the idle
// set too, to be re-dialed like any lost connection. Never inlined: the cold
// path of acquire*() and maintain().
@[noinline]
fn (mut p PgPool) finish_rollback(i int) bool {
	mut c := p.conn(i)
	if c.async_wants_write() {
		c.async_flush() or {}
	}
	if poll := c.async_on_readable() {
		if !poll.ready {
			if time.sys_mono_now() < c.rollback_deadline {
				return false // not answered yet
			}
			c.lose('no answer to the ROLLBACK queued at release')
		} else if c.ready_status != tx_idle {
			c.lose('the ROLLBACK queued at release left the session in a transaction')
		}
	} else {
		// lose keeps the first cause: a connection lost before the reply
		// already says why.
		c.lose('the ROLLBACK queued at release failed')
	}
	c.inflight.clear() // the ROLLBACK, when it got no answer: nobody else reads it
	c.rollback_deadline = 0
	p.idle[i] = true
	return true
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
// transaction. Nor is a connection whose session is in a transaction
// (tx_status, as of its last completed query), or whose release-time ROLLBACK
// is in flight. So a BEGIN must never go through acquire_pipelined(): the
// queries already pipelined behind it would run inside its transaction. A
// batch (async_submit_batch) without BEGIN is fine here: its one Sync ends
// its implicit transaction.
//
// Broken connections are skipped, and re-dialed once their in-flight count is
// back to 0 — which relies on the FIFO contract every pipelined caller already
// keeps: a request that submitted a query parks on the connection and consumes
// its reply (or error) with async_on_readable, even when the flush failed.
pub fn (mut p PgPool) acquire_pipelined() ?int {
	mut best := -1
	mut best_depth := max_inflight
	for i in 0 .. p.conns.len {
		if !p.idle[i] && (p.conns[i].rollback_deadline == 0 || !p.finish_rollback(i)) {
			continue // held by acquire() (its borrower may be mid-transaction), or rolling back
		}
		if p.conns[i].state != .ready && !p.conns[i].redial(p.cfg) {
			continue
		}
		if p.conns[i].ready_status != tx_idle {
			continue // in a transaction: whatever is pipelined here would run inside it
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
