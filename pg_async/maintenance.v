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
// of every idle broken one by one non-blocking step, and returns how soon, in
// milliseconds, it wants to run again: maintenance_busy_ms while a re-dial is
// in flight, the remaining backoff while one waits to retry, else
// maintenance_idle_ms. A connection held by acquire() or carrying pipelined
// queries is left alone: its reader finds out on its own. Never blocks on the
// network.
pub fn (mut p PgPool) maintain() int {
	mut next := maintenance_idle_ms
	now := time.sys_mono_now()
	for i in 0 .. p.conns.len {
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
	return next
}
