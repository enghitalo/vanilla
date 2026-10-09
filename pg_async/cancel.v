module pg_async

import core
import tls
import transport

// Cancelling the query a connection is running (vanilla#200), with
// PostgreSQL's CancelRequest: a second connection to the same server carries
// Int32(length) Int32(80877102) Int32(process id) and the secret key of the
// session's BackendKeyData, and is closed. The server interrupts the backend
// they name, whose query then fails with SQLSTATE 57014 (query_canceled),
// followed by ReadyForQuery, on the ORIGINAL connection: it stays usable. Over
// TLS the cancel connection negotiates TLS first (SSLRequest, then a handshake
// for the same host, verified the same way), as libpq does since PostgreSQL
// 17, so the secret key never crosses the network in the clear when the
// session does not.
//
// cancel() never blocks the worker. Its usual caller is a continuation whose
// park timed out (event_loop.timed_out()): waiting there on a connect or a TLS
// handshake would stall every connection on the worker, and the server a
// query hangs on may well be one that does not answer. So cancel() starts a
// non-blocking connect to the peer address of the connection itself
// (getpeername: no name resolution, and the same server behind a name that
// resolves to several), does what needs no waiting, and leaves the rest to a
// background watch on the worker's event loop (watch_fd_background), whose
// continuation (cancel_ready) moves the exchange on as the socket becomes
// ready and whose .done has the runtime close it. One CancelRequest per
// connection at a time: its state, and over TLS its session (re-armed for
// each one), live in the connection, so a cancel allocates nothing once
// those exist. The connection must stay at the same address until the
// cancel completes; a pool's connections always do.
//
// A cancel is a request, not a guarantee: the query may finish first (its
// result then arrives as usual), and a server that does not take the request
// within cancel_user_timeout_ms is given up on, silently.

fn C.pg_async_peer_addr(fd int, out voidptr, family &i32) u32

// cancel_request_code is CancelRequest's request code, where a StartupMessage
// has its protocol version.
const cancel_request_code = u32(80877102)

// cancel_user_timeout_ms bounds a CancelRequest connection (TCP_USER_TIMEOUT,
// which on Linux covers the connect too): a server that does not take the
// request in this long is given up on.
const cancel_user_timeout_ms = 10_000

// CancelPhase is where a connection's CancelRequest is.
enum CancelPhase {
	idle
	connecting    // non-blocking connect in flight: the first write tells when it is done
	ssl_request   // over TLS: SSLRequest sent, waiting for the server's 'S'
	tls_handshake // over TLS: the handshake under way
	sending       // the CancelRequest being written
	closed        // the connection was closed with a cancel in flight: drop it
}

// PgCancel is a connection's CancelRequest state (PgConn.cancel).
struct PgCancel {
mut:
	fd    int = -1 // the cancel connection's socket
	phase CancelPhase
	wait  int         // what the phase waits for: POLLIN or POLLOUT
	tls   tls.Session // over TLS: kept across cancels, re-armed for each socket
	msg   []u8        // the CancelRequest, written into a reused buffer
	off   int         // bytes of msg written
}

// backend_pid is the process id of the server backend this session runs in
// (BackendKeyData; what pg_backend_pid() returns), 0 when the server sent
// none. It is what a CancelRequest names.
pub fn (c &PgConn) backend_pid() int {
	return c.backend_pid
}

// set_backend_key keeps BackendKeyData's process id and secret key. A
// malformed message (shorter than protocol 3.0's 8 bytes, or a key longer
// than protocol 3.2's 256) leaves the session uncancellable.
fn (mut c PgConn) set_backend_key(payload []u8) {
	c.backend_pid = 0
	unsafe {
		c.cancel_key.len = 0
	}
	if payload.len < 8 || payload.len > 4 + 256 {
		return
	}
	c.backend_pid = int((u32(payload[0]) << 24) | (u32(payload[1]) << 16) | (u32(payload[2]) << 8) | u32(payload[3]))
	unsafe { c.cancel_key.push_many(&payload[4], payload.len - 4) }
}

// cancel asks the server to cancel the query this connection is running (see
// above) and returns once the request is on its way, without blocking. The
// cancelled query's reply (ErrorResponse 57014, then ReadyForQuery) arrives on
// this connection like any reply, so whoever consumes it — the parked request,
// or its tombstone after a park deadline — sees `err is PgError &&
// err.sqlstate == '57014'`. event_loop is the worker's, as handed to a handler
// or a continuation: the exchange runs as a background watch on it, which the
// epoll plain worker runs (elsewhere cancel fails and sends nothing). A cancel
// already in flight on this connection makes this a no-op.
pub fn (mut c PgConn) cancel(mut event_loop core.EventLoop) ! {
	if c.state != .ready || c.fd < 0 {
		return error('pg: cancel: the connection is not live')
	}
	if c.cancel_key.len == 0 {
		return error('pg: cancel: the server sent no BackendKeyData for this session')
	}
	if c.cancel.phase != .idle {
		return // one is already on its way
	}
	mut a := transport.Addr{}
	mut family := i32(0) // a C int
	a.len = C.pg_async_peer_addr(c.fd, voidptr(&a.data[0]), &family)
	if a.len == 0 {
		return error('pg: cancel: cannot read the server address (errno ${C.errno})')
	}
	a.family = int(family)
	fd := transport.dial_addr(&a, transport.TcpOpts{
		keepalive_idle_s: 0
		user_timeout_ms:  cancel_user_timeout_ms
	})
	if fd < 0 {
		return error('pg: cancel: connect failed (errno ${-fd})')
	}
	unsafe {
		c.cancel.msg.len = 0
	}
	put_u32(mut c.cancel.msg, u32(12 + c.cancel_key.len))
	put_u32(mut c.cancel.msg, cancel_request_code)
	put_u32(mut c.cancel.msg, u32(c.backend_pid))
	unsafe { c.cancel.msg.push_many(c.cancel_key.data, c.cancel_key.len) }
	c.cancel.fd = fd
	c.cancel.off = 0
	c.cancel.phase = .connecting
	done := c.cancel_step() or {
		c.cancel_finish()
		C.close(fd)
		return err
	}
	if done {
		c.cancel_finish()
		C.close(fd)
		return
	}
	if !event_loop.watch_fd_background(fd, c.cancel_interest(), cancel_ready, voidptr(c)) {
		c.cancel_finish()
		C.close(fd)
		return error('pg: cancel needs a worker that runs background watches (the epoll plain worker)')
	}
}

// cancel_ready is the background continuation of a CancelRequest: it moves
// the exchange on as the socket becomes ready. Its .done (written, failed, or
// the connection closed meanwhile) has the runtime close the socket.
fn cancel_ready(mut _ []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, _ voidptr, mut event_loop core.EventLoop) core.Step {
	mut c := unsafe { &PgConn(watch_payload) }
	if c.cancel.phase == .closed || c.cancel.fd != ready_fd || ready_fd_error {
		c.cancel_finish() // refused, reset, or abandoned: nothing more to send
		return .done
	}
	done := c.cancel_step() or {
		c.cancel_finish()
		return .done
	}
	if done {
		c.cancel_finish()
		return .done
	}
	event_loop.watch_fd(ready_fd, c.cancel_interest(), cancel_ready, watch_payload)
	return .suspend
}

// cancel_step advances the CancelRequest as far as it goes without waiting:
// true once it is written, false while it waits for c.cancel.wait.
fn (mut c PgConn) cancel_step() !bool {
	if c.cancel.phase == .connecting {
		if c.tls_cfg == unsafe { nil } {
			c.cancel.phase = .sending // the request is the first write
		} else {
			n := C.send(c.cancel.fd, &ssl_request[0], usize(ssl_request.len), C.MSG_NOSIGNAL)
			if n < 0 {
				e := C.errno
				if e == C.EAGAIN || e == C.EWOULDBLOCK || e == C.ENOTCONN {
					c.cancel.wait = C.POLLOUT // still connecting
					return false
				}
				return error('pg: cancel: connect failed (errno ${e})')
			}
			if n != ssl_request.len {
				return error('pg: cancel: short SSLRequest write')
			}
			c.cancel.phase = .ssl_request
		}
	}
	if c.cancel.phase == .ssl_request {
		mut b := u8(0)
		n := C.recv(c.cancel.fd, &b, 1, 0)
		if n < 0 {
			e := C.errno
			if e == C.EAGAIN || e == C.EWOULDBLOCK {
				c.cancel.wait = C.POLLIN
				return false
			}
			return error('pg: cancel: recv failed after SSLRequest (errno ${e})')
		}
		// The same checks as the session's own SSLRequest (ssl_answer): TLS or
		// nothing, and no unprotected bytes behind the 'S'.
		if n == 0 || b != `S` || C.pg_async_pending_bytes(c.cancel.fd) != 0 {
			return error('pg: cancel: the server did not start TLS')
		}
		if c.cancel.tls.active() {
			if !c.cancel.tls.reset(c.cancel.fd) {
				return error('pg: cancel: cannot reset the TLS session')
			}
		} else {
			c.cancel.tls = c.tls_cfg.new_client_session(c.cancel.fd, c.tls_host) or {
				return error('pg: cancel: cannot start a TLS session')
			}
		}
		c.cancel.phase = .tls_handshake
	}
	if c.cancel.phase == .tls_handshake {
		c.cancel.tls.mark_readable()
		r := c.cancel.tls.handshake()
		if r == tls.want || r == tls.want_write {
			c.cancel.wait = if r == tls.want { C.POLLIN } else { C.POLLOUT }
			return false
		}
		if r != 0 {
			return error('pg: cancel: TLS handshake failed: ${c.cancel.tls.handshake_error()}')
		}
		c.cancel.phase = .sending
	}
	if c.cancel.phase != .sending {
		return error('pg: cancel: no request in flight')
	}
	for c.cancel.off < c.cancel.msg.len {
		p := unsafe { &u8(c.cancel.msg.data) + c.cancel.off }
		l := c.cancel.msg.len - c.cancel.off
		if c.tls_cfg != unsafe { nil } {
			// A record Mbed TLS could not finish is retried with the same
			// length: off has not moved.
			n := c.cancel.tls.write_from(p, l)
			if n > 0 {
				c.cancel.off += n
				continue
			}
			if n == tls.want || n == tls.want_write {
				c.cancel.wait = if n == tls.want { C.POLLIN } else { C.POLLOUT }
				return false
			}
			return error('pg: cancel: TLS write failed')
		}
		n := C.send(c.cancel.fd, p, usize(l), C.MSG_NOSIGNAL)
		if n > 0 {
			c.cancel.off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.ENOTCONN) {
			c.cancel.wait = C.POLLOUT // still connecting (plaintext: the first write)
			return false
		}
		return error('pg: cancel: send failed (errno ${C.errno})')
	}
	return true
}

// cancel_interest is what the CancelRequest waits for, as a watch interest.
@[inline]
fn (c &PgConn) cancel_interest() core.WatchInterest {
	return if c.cancel.wait == C.POLLIN { core.WatchInterest.readable } else { .writable }
}

// cancel_finish ends the CancelRequest in flight; its socket is the caller's
// to close (the runtime's, after a background continuation's .done). Over TLS
// the session is kept for the next one, detached from that socket.
fn (mut c PgConn) cancel_finish() {
	if c.cancel.tls.active() {
		c.cancel.tls.reset(-1)
	}
	c.cancel.fd = -1
	c.cancel.phase = .idle
}

// cancel_teardown frees the cancel's TLS session when the connection is torn
// down (before the TLS config it comes from is freed); a request still in
// flight is dropped by its continuation.
fn (mut c PgConn) cancel_teardown() {
	if c.cancel.tls.active() {
		c.cancel.tls.free()
		c.cancel.tls = tls.Session{}
	}
	if c.cancel.phase != .idle {
		c.cancel.phase = .closed
	}
}
