module pg_async

import time

// Re-dialing a lost pooled connection, without blocking the worker.
//
// A broken connection (LinkState) is not torn down on the spot: requests still
// parked on its socket must first collect their replies or errors from
// async_on_readable, or a new socket reusing the fd number would wake them
// with someone else's reply. Once nothing is in flight on it (and, for
// acquire(), no borrower holds it), the pool re-dials it lazily from
// acquire() / acquire_pipelined(), which skip it until it is .ready again. Each
// call advances the bring-up by at most one step that needs no waiting:
//
//   .broken      close the old socket, start a non-blocking connect()  → .connecting
//   .connecting  the socket takes the StartupMessage once connected     → .starting
//   .starting    take what arrived, answer the SCRAM exchange           → .ready
//
// so the worker never waits on the network; name resolution does run inline,
// once per attempt. The SCRAM key derivation (PBKDF2) does not: the pool's
// ScramCache already holds it, unless the server changed the salt. A failed attempt
// (refused, closed, authentication error, or redial_timeout) closes its socket
// and is retried after redial_backoff, starting at the next resolved address
// (addr_cursor), so a dead one is not retried first forever. The first attempt starts on the first
// acquire after the loss, so with steady traffic a slot is back within a few
// requests while its siblings keep serving.

// redial_backoff is the pause after a failed attempt (server down or
// restarting) before the next one, so a dead server costs one connect per
// second per slot rather than one per request.
const redial_backoff = u64(time.second)

// redial_timeout bounds one attempt (connect + handshake): a SYN to an
// unreachable address would otherwise hold the slot for the kernel's ~2 min.
const redial_timeout = u64(10 * time.second)

// redial advances a non-ready connection's re-dial by one non-blocking step and
// reports whether it is ready to serve.
fn (mut c PgConn) redial(cfg ConnConfig) bool {
	if c.state == .ready {
		return true
	}
	now := time.sys_mono_now()
	if c.state == .broken {
		if c.inflight.len > 0 || now < c.retry_at {
			return false // requests still parked on the old socket, or backing off
		}
		c.redial_start(cfg) or {
			c.redial_failed(now)
			return false
		}
	} else if now >= c.dial_deadline {
		c.redial_failed(now)
		return false
	}
	ready := c.redial_step(cfg) or {
		c.redial_failed(now)
		return false
	}
	return ready
}

// redial_start drops the lost socket and starts a non-blocking connect on a new
// one, resetting the per-connection state in place: the buffers are kept, so a
// reconnect allocates nothing that leaks under -gc none.
fn (mut c PgConn) redial_start(cfg ConnConfig) ! {
	if c.fd >= 0 {
		C.close(c.fd) // also drops it from any epoll set it is still in
		c.fd = -1
	}
	c.inflight.clear()
	c.frame_ring = 0
	c.recv_pos = 0
	if c.recv_buf.cap < 16 * 1024 {
		c.recv_buf = []u8{cap: 16 * 1024}
	}
	unsafe {
		c.recv_buf.len = 0
	}
	c.send_off = 0
	c.send_len = 0
	c.fatal = PgError{}
	c.loss = ''
	c.fd = dial(&cfg, true, c.addr_cursor)!
	c.state = .connecting
	c.dial_deadline = time.sys_mono_now() + if cfg.connect_timeout_ms > 0 {
		u64(cfg.connect_timeout_ms) * u64(time.millisecond)
	} else {
		redial_timeout
	}
}

// redial_step runs whatever part of the bring-up needs no waiting; true once
// ReadyForQuery arrived.
fn (mut c PgConn) redial_step(cfg ConnConfig) !bool {
	if c.state == .connecting {
		// The connect is done once the socket takes the StartupMessage: until then
		// send() reports EAGAIN (Linux) or ENOTCONN (BSD), and the connect's own
		// error once it failed. The message is a few dozen bytes on an empty
		// socket buffer, so it goes out whole.
		if c.submit_scratch.cap == 0 {
			c.submit_scratch = []u8{cap: 512}
		}
		unsafe {
			c.submit_scratch.len = 0
		}
		write_startup(mut c.submit_scratch, cfg.user, cfg.database)
		n := C.send(c.fd, c.submit_scratch.data, usize(c.submit_scratch.len), C.MSG_NOSIGNAL)
		if n < 0 {
			e := C.errno
			if e == C.EAGAIN || e == C.EWOULDBLOCK || e == C.ENOTCONN {
				return false // still connecting
			}
			return error('pg: re-dial connect failed (errno ${e})')
		}
		if n != c.submit_scratch.len {
			return error('pg: re-dial: short StartupMessage write')
		}
		c.scram = ScramClient.new(cfg.user, cfg.password)!
		c.scram.cache = c.scram_cache // the pool's PBKDF2 result: no derivation per re-dial
		c.state = .starting
	}
	for {
		if c.recv_buf.len == c.recv_buf.cap {
			unsafe { c.recv_buf.grow_cap(c.recv_buf.cap) }
		}
		n := C.recv(c.fd, unsafe { &u8(c.recv_buf.data) + c.recv_buf.len },
			usize(c.recv_buf.cap - c.recv_buf.len), 0)
		if n > 0 {
			unsafe {
				c.recv_buf.len += n
			}
			continue
		}
		if n == 0 {
			return error('pg: re-dial: connection closed during startup')
		}
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			break
		}
		return error('pg: re-dial: recv failed (errno ${C.errno})')
	}
	for {
		hdr := next_message_at(c.recv_buf, c.recv_pos) or { break }
		typ := c.recv_buf[c.recv_pos]
		payload := c.recv_buf[c.recv_pos + 5..c.recv_pos + hdr.total]
		c.recv_pos += hdr.total
		if c.on_startup_msg(typ, payload, mut c.scram)! {
			c.state = .ready
			return true
		}
	}
	return false
}

// redial_failed abandons the attempt in flight (if any) and schedules the next.
fn (mut c PgConn) redial_failed(now u64) {
	if c.fd >= 0 {
		C.close(c.fd)
		c.fd = -1
	}
	c.state = .broken
	c.retry_at = now + redial_backoff
	c.addr_cursor++
}
