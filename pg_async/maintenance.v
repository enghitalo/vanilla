module pg_async

import time

// Pool maintenance, off the request path: finding connections the server
// closed while they sat idle, and re-dialing broken ones.
//
// Without it, a connection the server closes while idle (a restart,
// idle_session_timeout, a managed database's lifetime cap such as Aurora
// DSQL's 1 h) is only found out by the next query on it, which fails, and its
// re-dial only advances when a request calls acquire(). maintain() looks at
// every idle connection without blocking: an EOF or a FATAL that arrived
// unasked marks it broken right away, and the re-dial runs from the same tick,
// so the slot is usually back before any request meets it. Drive it with
// start_maintenance (a timer on the worker's event loop) or call it yourself.
//
// It also enforces max_lifetime_ms. A connection past its deadline is
// recycled before the server's own cap can close it under a query: taken out
// of the idle set (an idle one at the tick that finds it due, a borrowed one
// when release() returns it), so neither acquire() nor acquire_pipelined()
// hands it out again; once the pipelined queries already on it have drained,
// it sends Terminate and is re-dialed in place by the re-dial state machine
// (redial.v), one non-blocking step per tick, then rejoins the idle set. No
// request ever advances, or waits on, that re-dial. One connection is recycled
// at a time, so a pool of N keeps N-1 serving (a pool of 1 sheds for the length
// of one re-dial); the others due wait their turn, still serving.

// maintenance_idle_ms is the tick while every connection is healthy: how long
// a connection the server closed can sit unnoticed.
const maintenance_idle_ms = 1000

// maintenance_busy_ms is the tick while a re-dial is in flight (connect or
// handshake under way): each tick advances it one non-blocking step.
const maintenance_busy_ms = 5

// probe_idle looks at an idle, live connection without blocking. An EOF, or an
// ErrorResponse that ends the session (FATAL/PANIC: e.g. 57P01 on
// pg_terminate_backend or a server shutdown), marks it broken now, keeping the
// FATAL so it is reported as the cause. Other messages a server may send unasked
// (ParameterStatus, NoticeResponse, NotificationResponse) stay buffered for
// the next query's reader, exactly as without the probe.
fn (mut c PgConn) probe_idle() {
	if c.state != .ready || c.inflight.len > 0 || c.fd < 0 {
		return
	}
	// The common case, nothing arrived: one peek, no copy.
	mut b := u8(0)
	n := C.recv(c.fd, &b, 1, C.MSG_PEEK | C.MSG_DONTWAIT)
	if n < 0 {
		e := C.errno
		if e != C.EAGAIN && e != C.EWOULDBLOCK && e != C.EINTR {
			c.lose('recv failed while idle (errno ${e})')
		}
		return
	}
	if n == 0 {
		c.lose('connection closed by server while idle')
		return
	}
	// Bytes arrived unasked: take everything there is — through the TLS session
	// when there is one (raw ciphertext must never land in recv_buf); an EOF
	// behind them breaks the connection — then look for a FATAL among them.
	c.fill_recv_buf()
	mut pos := c.recv_pos
	for {
		hdr := next_message_at(c.recv_buf, pos) or { break }
		if c.recv_buf[pos] == bt_error_response {
			info := parse_error_response(c.recv_buf[pos + 5..pos + hdr.total])
			if ends_session(info.severity) {
				c.fatal = PgError{
					severity: info.severity.bytestr()
					sqlstate: info.code.bytestr()
					message:  info.message.bytestr()
				}
				c.lose('connection closed by server')
				return
			}
		}
		pos += hdr.total
	}
}

// maintain probes every idle connection (probe_idle) and advances the re-dial
// of every idle broken one by one non-blocking step, recycles connections past
// max_lifetime_ms (above), and returns how soon, in milliseconds, it wants to
// run again: maintenance_busy_ms while a re-dial or a recycle is in flight,
// the remaining backoff while one waits to retry, else maintenance_idle_ms or
// the time to the next lifetime deadline, whichever is sooner. A connection
// held by acquire() or carrying pipelined queries is not probed: its reader
// finds out on its own. Never blocks on the network.
pub fn (mut p PgPool) maintain() int {
	mut next := maintenance_idle_ms
	now := time.sys_mono_now()
	p.clock = now
	for i in 0 .. p.conns.len {
		if p.idle[i] && p.conns[i].expires_at <= now && p.conns[i].state == .ready {
			if p.recycling < 0 {
				p.idle[i] = false // due: no new query lands on it
				p.recycling = i
			} else {
				next = maintenance_busy_ms // its turn comes after the recycle in flight
			}
		}
		if !p.idle[i] || p.conns[i].inflight.len > 0 {
			continue
		}
		p.conns[i].probe_idle()
		if p.conns[i].state == .ready || p.conns[i].redial(p.cfg) {
			continue
		}
		wait := if p.conns[i].state == .broken && p.conns[i].retry_at > now {
			int((p.conns[i].retry_at - now) / u64(time.millisecond)) + 1
		} else {
			maintenance_busy_ms
		}
		if wait < next {
			next = wait
		}
	}
	if p.recycling >= 0 {
		wait := p.recycle_step(now)
		if wait < next {
			next = wait
		}
	}
	// Wake up at the next lifetime deadline (+1 ms): an idle connection is
	// recycled right then, and a borrowed one meets the clock at release().
	for i in 0 .. p.conns.len {
		expires_at := p.conns[i].expires_at
		if expires_at > now && expires_at - now < u64(next) * u64(time.millisecond) {
			next = int((expires_at - now) / u64(time.millisecond)) + 1
		}
	}
	return next
}

// recycle_step advances the recycle of connection p.recycling: it waits for
// the pipelined queries already on it to drain (their requests collect the
// replies), says goodbye (Terminate, one attempt), re-dials in place (one
// non-blocking step per call, a fresh password_fn credential) and returns the
// connection to the idle set once it is ready. Returns the milliseconds until
// it next has work.
fn (mut p PgPool) recycle_step(now u64) int {
	i := p.recycling
	mut c := &p.conns[i]
	if c.inflight.len > 0 {
		return maintenance_busy_ms
	}
	if c.state == .ready {
		c.send_terminate()
		c.lose('recycled: max_lifetime_ms reached')
		c.retry_at = 0
	}
	if c.redial(p.cfg) {
		p.idle[i] = true
		p.recycling = -1
		return maintenance_idle_ms
	}
	if c.state == .broken && c.retry_at > now {
		return int((c.retry_at - now) / u64(time.millisecond)) + 1
	}
	return maintenance_busy_ms
}
