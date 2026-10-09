module pg_async

import tls
import time

// The connection's byte transport: the socket itself, or a TLS session over it
// (ssl_mode != .disable, vanilla#196). Every send and recv of the query path,
// the re-dial and the blocking bring-up goes through send_some / recv_some,
// so the protocol layer never knows which it is, and the plaintext path is the
// raw syscall it always was behind one predictable branch (PgConn.tls is the
// zero Session: no interface, no indirect call).
//
// TLS is Mbed TLS 4 through tls/ (the client side of the shim the HTTPS
// server uses), TLS 1.3 only, on a socket that is always non-blocking: Mbed
// TLS must never wait in a recv while holding its process-wide crypto lock.
// The edge-triggered contract carries over: a TLS read reports io_again only
// once the socket is drained and Mbed TLS holds nothing more (tls/ reads past
// TLS 1.3 session tickets), so async_on_readable drains TLS records exactly
// as it drains plain bytes.

// io_again: nothing can move now; wait for the socket and call again.
const io_again = -2

// io_failed: the transport failed (errno, or the TLS error, says why).
const io_failed = -1

// ssl_request is PostgreSQL's SSLRequest: Int32(8) Int32(80877103).
const ssl_request = [u8(0), 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f]!

fn C.pg_async_pending_bytes(fd int) int

// recv_some reads into p[..max]: the byte count, 0 once the server closed the
// connection, io_again, or io_failed. Over TLS, call tls.mark_readable() first
// when new bytes may have arrived (every readable wake).
@[inline]
fn (mut c PgConn) recv_some(p &u8, max int) int {
	if !c.tls.active() {
		n := C.recv(c.fd, p, usize(max), 0)
		if n >= 0 {
			return n
		}
		return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { io_again } else { io_failed }
	}
	return c.tls_recv(p, max)
}

@[noinline]
fn (mut c PgConn) tls_recv(p &u8, max int) int {
	n := c.tls.read_into(p, max)
	if n > 0 {
		return n
	}
	if n == tls.want {
		c.tls_wait = C.POLLIN
		return io_again
	}
	if n == tls.want_write {
		// Mbed TLS must send something before it can read on: async_wants_write
		// reports it, and async_flush retries the read once the socket is
		// writable (Mbed TLS's contract: call the same function again).
		c.tls_wait = C.POLLOUT
		c.tls_read_blocked = true
		return io_again
	}
	return if c.tls.peer_closed() { 0 } else { io_failed }
}

// send_some writes from p[..len]: the byte count, io_again, or io_failed.
@[inline]
fn (mut c PgConn) send_some(p &u8, len int) int {
	if !c.tls.active() {
		n := C.send(c.fd, p, usize(len), C.MSG_NOSIGNAL)
		if n >= 0 {
			return n
		}
		return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { io_again } else { io_failed }
	}
	return c.tls_send(p, len)
}

@[noinline]
fn (mut c PgConn) tls_send(p &u8, len int) int {
	// A record Mbed TLS encrypted but could not send whole stays in Mbed TLS,
	// which must be called again with the same length — not the (maybe
	// longer) pending tail, or it would count bytes it never encrypted as sent.
	l := if c.tls_wlen > 0 { c.tls_wlen } else { len }
	n := c.tls.write_from(p, l)
	if n >= 0 {
		c.tls_wlen = 0
		return n
	}
	if n == tls.want || n == tls.want_write {
		c.tls_wait = if n == tls.want { C.POLLIN } else { C.POLLOUT }
		c.tls_wlen = l
		return io_again
	}
	return io_failed
}

// io_error describes a failed send/recv for the loss reason: the errno on a
// plain socket (read right after the call), a TLS failure otherwise.
fn (c &PgConn) io_error(op string) string {
	if c.tls.active() {
		return 'TLS ${op} failed'
	}
	return '${op} failed (errno ${C.errno})'
}

// io_wait is the readiness a blocked call waits for: what the TLS session
// asked for (a TLS write may need to read first, and a read to write), else
// the plain socket's own direction.
@[inline]
fn (c &PgConn) io_wait(plain int) int {
	return if c.tls.active() { c.tls_wait } else { plain }
}

// wait_io blocks until the socket is ready for `events` (POLLIN / POLLOUT),
// up to io_deadline: the blocking bring-up and query() only, never a worker's
// async path. Over TLS it then tells the session new bytes may be there.
fn (mut c PgConn) wait_io(events int) ! {
	mut timeout := -1
	if c.io_deadline > 0 {
		now := time.sys_mono_now()
		if now >= c.io_deadline {
			return error('pg: timed out waiting for the server (connect_timeout_ms)')
		}
		timeout = int((c.io_deadline - now) / u64(time.millisecond)) + 1
	}
	r := C.pg_async_wait(c.fd, events, timeout)
	if r == 0 {
		return error('pg: timed out waiting for the server (connect_timeout_ms)')
	}
	if r < 0 {
		return error('pg: poll failed (errno ${C.errno})')
	}
	if c.tls.active() {
		c.tls.mark_readable()
	}
}

// new_tls_config builds the client TLS config ssl_mode asks for. Without the
// `-d vanilla_tls` build this is the error that says so: never a plaintext
// fallback.
fn new_tls_config(cfg &ConnConfig) !&tls.Config {
	verify := match cfg.ssl_mode {
		.disable { return error('pg: ssl_mode .disable has no TLS config') }
		.require {
			if cfg.ssl_root_cert != '' { tls.Verify.chain } else { tls.Verify.off }
		}
		.verify_ca { tls.Verify.chain }
		.verify_full { tls.Verify.full }
	}
	return tls.new_client(cfg.ssl_root_cert, verify) or {
		return error('pg: ssl_mode .${cfg.ssl_mode} needs TLS: ${err.msg()}')
	}
}

// send_ssl_request writes the SSLRequest on the bare socket. It is the first
// write on a fresh connection: false while a non-blocking connect is still in
// flight (EAGAIN, or ENOTCONN on BSD), true once sent.
fn (mut c PgConn) send_ssl_request() !bool {
	n := C.send(c.fd, &ssl_request[0], usize(ssl_request.len), C.MSG_NOSIGNAL)
	if n == ssl_request.len {
		return true
	}
	if n < 0 {
		e := C.errno
		if e == C.EAGAIN || e == C.EWOULDBLOCK || e == C.ENOTCONN {
			return false
		}
		return error('pg: connect failed (errno ${e})')
	}
	return error('pg: short SSLRequest write')
}

// ssl_answer reads the server's one-byte answer to SSLRequest without
// waiting: false while it has not arrived, true on 'S' (TLS may start), an
// error otherwise — 'N' means the server has no TLS, which every ssl_mode but
// .disable refuses.
fn (mut c PgConn) ssl_answer() !bool {
	mut b := u8(0)
	n := C.recv(c.fd, &b, 1, 0)
	if n == 0 {
		return error('pg: the server closed the connection after SSLRequest')
	}
	if n < 0 {
		e := C.errno
		if e == C.EAGAIN || e == C.EWOULDBLOCK {
			return false
		}
		return error('pg: recv failed after SSLRequest (errno ${e})')
	}
	if b == `N` {
		return error("pg: the server does not accept TLS (it answered 'N' to SSLRequest)")
	}
	if b != `S` {
		return error('pg: unexpected answer to SSLRequest (byte ${b})')
	}
	// Bytes behind the 'S' were sent before any TLS session existed, so nothing
	// authenticates them: read as the server's first replies they would let a
	// man in the middle inject them (CVE-2021-23222). The server sends none.
	if C.pg_async_pending_bytes(c.fd) != 0 {
		return error('pg: received unencrypted data after the SSL response')
	}
	return true
}

// tls_attach puts a TLS session on the socket: the connection's own, re-armed
// for this socket after a re-dial (its buffers are kept), or a new one.
fn (mut c PgConn) tls_attach(cfg &ConnConfig) ! {
	if c.tls.active() {
		if !c.tls.reset(c.fd) {
			return error('pg: cannot reset the TLS session')
		}
		return
	}
	c.tls = c.tls_cfg.new_client_session(c.fd, cfg.host) or {
		return error('pg: cannot start a TLS session')
	}
}

// tls_step advances the TLS handshake as far as it goes without waiting:
// true once done; false while it waits for c.tls_wait.
fn (mut c PgConn) tls_step(cfg &ConnConfig) !bool {
	c.tls.mark_readable()
	r := c.tls.handshake()
	if r == 0 {
		return true
	}
	if r == tls.want || r == tls.want_write {
		c.tls_wait = if r == tls.want { C.POLLIN } else { C.POLLOUT }
		return false
	}
	return error('pg: TLS handshake with ${cfg.host} failed: ${c.tls.handshake_error()}')
}

// close_socket closes a lost connection's socket, first detaching its TLS
// session from it: nothing the session does later can reach that fd number
// once the kernel hands it out again.
fn (mut c PgConn) close_socket() {
	if c.tls.active() {
		c.tls.reset(-1)
	}
	if c.fd >= 0 {
		C.close(c.fd)
		c.fd = -1
	}
}
