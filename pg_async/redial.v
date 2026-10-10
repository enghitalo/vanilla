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
//   .broken         close the old socket, start a non-blocking connect() → .connecting
//   .connecting     the socket takes the StartupMessage once connected    → .starting
//   .starting       take what arrived, answer the SCRAM exchange          → .ready
//
// and over TLS (ssl_mode != .disable) two more in between:
//
//   .connecting     the socket takes the SSLRequest once connected        → .ssl_request
//   .ssl_request    the server's one-byte answer: 'S', nothing behind it  → .tls_handshake
//   .tls_handshake  the TLS handshake (the session is the connection's
//                   own, re-armed: no allocation), then the
//                   StartupMessage over it                                → .starting
//
// so the worker never waits on the network; name resolution, password_fn (a
// fresh credential for every attempt) and the TLS handshake's crypto steps do
// run inline, once per attempt. The SCRAM key derivation (PBKDF2) does not:
// the pool's ScramCache already holds it, unless the server changed the
// salt. A connection recycled for max_lifetime_ms takes the same path, driven
// by maintain() alone (maintenance.v). A failed attempt
// (refused, closed, authentication error, or redial_timeout) closes its socket
// and is retried after redial_backoff, starting at the next resolved address
// (addr_cursor), so a dead one is not retried first forever. The first attempt starts on the first
// acquire after the loss, so with steady traffic a slot is back within a few
// requests while its siblings keep serving.

// redial_backoff is the pause after a failed attempt (server down or
// restarting) before the next one, so a dead server costs one connect per
// second per slot rather than one per request.
const redial_backoff = u64(time.second)

// redial_timeout bounds one attempt (connect + TLS + handshake): a SYN to an
// unreachable address would otherwise hold the slot for the kernel's ~2 min.
const redial_timeout = u64(10 * time.second)

// redial advances a non-ready connection's re-dial by one non-blocking step and
// reports whether it is ready to serve. Never inlined: it is the cold path of
// acquire*(), and inlined into a request handler it would crowd the hot code
// around it.
@[noinline]
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
	if cfg.ssl_mode != .disable && c.tls_cfg == unsafe { nil } {
		return error('pg: the connection was closed') // close() freed its TLS
	}
	c.close_socket() // also drops it from any epoll set it is still in
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
	c.tls_wlen = 0
	c.tls_read_blocked = false
	c.fatal = PgError{}
	c.loss = ''
	c.ready_status = tx_idle // a new session is in no transaction
	c.rollback_deadline = 0
	c.start_auth(cfg)!
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
		if c.tls_cfg != unsafe { nil } {
			// The connect is done once the socket takes the SSLRequest (see
			// send_ssl_request): TLS is negotiated before anything else.
			if !c.send_ssl_request()! {
				return false // still connecting
			}
			c.state = .ssl_request
		} else {
			if !c.send_startup(cfg)! {
				return false // still connecting
			}
			c.state = .starting
		}
	}
	if c.state == .ssl_request {
		if !c.ssl_answer()! {
			return false
		}
		c.tls_attach(&cfg)!
		c.state = .tls_handshake
	}
	if c.state == .tls_handshake {
		if !c.tls_step(&cfg)! {
			return false
		}
		if !c.send_startup(cfg)! {
			return error('pg: re-dial: the StartupMessage did not fit an empty socket')
		}
		c.state = .starting
	}
	if c.tls.active() {
		c.tls.mark_readable()
	}
	for {
		if c.recv_buf.len == c.recv_buf.cap {
			unsafe { c.recv_buf.grow_cap(c.recv_buf.cap) }
		}
		n := c.recv_some(unsafe { &u8(c.recv_buf.data) + c.recv_buf.len }, c.recv_buf.cap - c.recv_buf.len)
		if n > 0 {
			unsafe {
				c.recv_buf.len += n
			}
			continue
		}
		if n == 0 {
			return error('pg: re-dial: connection closed during startup')
		}
		if n == io_again {
			break
		}
		return error('pg: re-dial: ${c.io_error('recv')}')
	}
	for {
		hdr := next_message_at(c.recv_buf, c.recv_pos) or { break }
		typ := c.recv_buf[c.recv_pos]
		payload := c.recv_buf[c.recv_pos + 5..c.recv_pos + hdr.total]
		c.recv_pos += hdr.total
		if c.on_startup_msg(typ, payload, &cfg, mut c.scram)! {
			c.state = .ready
			c.expires_at = c.lifetime_deadline(&cfg, time.sys_mono_now())
			return true
		}
	}
	return false
}

// start_auth readies an attempt's authentication, for the blocking bring-up
// and the re-dial alike: its password, asked of password_fn when set (once
// per attempt, before dialing: a failing provider costs no connect), in a
// SCRAM client that has the pool's PBKDF2 result (ScramCache): no key
// derivation per re-dial, plain or TLS. A cleartext request is answered with
// the same password.
fn (mut c PgConn) start_auth(cfg ConnConfig) ! {
	c.scram = ScramClient.new(cfg.user, attempt_password(&cfg)!)!
	c.scram.cache = c.scram_cache
}

// send_startup writes the StartupMessage, whole (a few dozen bytes on an empty
// socket buffer): false while a non-blocking connect is still in flight (the
// send reports EAGAIN on Linux, ENOTCONN on BSD), true once sent. On a plain
// socket this is the first write, and so the connect's completion test.
fn (mut c PgConn) send_startup(cfg ConnConfig) !bool {
	if c.submit_scratch.cap == 0 {
		c.submit_scratch = []u8{cap: 512}
	}
	unsafe {
		c.submit_scratch.len = 0
	}
	write_startup(mut c.submit_scratch, cfg.user, cfg.database, cfg.params)
	n := c.send_some(c.submit_scratch.data, c.submit_scratch.len)
	if n == c.submit_scratch.len {
		return true
	}
	if n == io_again || (n == io_failed && !c.tls.active() && C.errno == C.ENOTCONN) {
		return false
	}
	if n >= 0 {
		return error('pg: re-dial: short StartupMessage write')
	}
	return error('pg: re-dial: ${c.io_error('connect')}')
}

// redial_failed abandons the attempt in flight (if any) and schedules the next.
fn (mut c PgConn) redial_failed(now u64) {
	c.close_socket()
	c.state = .broken
	c.retry_at = now + redial_backoff
	c.addr_cursor++
}
