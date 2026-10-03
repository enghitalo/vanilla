module upstream

import core
import tls
import time
import transport
import http1_1.client

// The exchange state machine: connecting → handshake (HTTPS) → sending →
// reading → ready | failed. Every step runs until the socket would block,
// then parks the slot's fd with watch_fd_persistent (the pool owns it: a
// client that leaves does not close it) and reports .pending.
//
// The slot's fd NUMBER never changes inside an exchange: a re-dial (the next
// address, or the one retry) dups the new socket onto it. A continuation whose
// client has gone can only re-arm the fd it was woken on, for reading
// (vanilla#229 gap 14), and the runtime still holds a watch on that number.

// send finishes the request (Content-Length from body(), the blank line) and
// starts the exchange: on a kept connection the request is written at once,
// otherwise a connect starts. .pending: a watch is armed, return .suspend and
// call advance() from `cont`, which gets `payload` back. .failed: release()
// and answer. (.ready only for a response already complete, never in
// practice.)
pub fn (mut x Exchange) send(mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	if !x.busy || x.phase != .idle {
		return x.fail(.invalid)
	}
	if !x.head_ok || x.invalid {
		return x.fail(.invalid)
	}
	// RFC 9110 §8.6: a Content-Length on any request with content, and on a
	// POST / PUT / PATCH without (0), so the server never waits for a body.
	m0 := x.head[0]
	if x.body.len > 0 || m0 == `P` {
		ws(mut x.head, 'Content-Length: ')
		wi(mut x.head, x.body.len)
		ws(mut x.head, '\r\n')
	}
	ws(mut x.head, '\r\n')
	if x.head.len + x.body.len > x.pool.origin.max_request_bytes {
		return x.fail(.invalid)
	}
	x.framer.reset(x.is_head)
	x.base = x.pool.cursor
	now := time.sys_mono_now()
	if x.fd >= 0 {
		x.phase = .sending
		x.deadline = now + ms_ns(x.pool.origin.response_timeout_ms)
		return x.drive(false, mut el, cont, payload)
	}
	return x.dial(mut el, cont, payload)
}

// advance continues the exchange from its continuation (the arguments are the
// continuation's own: ready_fd_error, event_loop, and the cont / payload to
// re-arm with). .pending: return .suspend; .ready: read the response, answer,
// release(); .failed: failure() says why, answer, release().
pub fn (mut x Exchange) advance(ready_fd_error bool, mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	match x.phase {
		.ready {
			return .ready
		}
		.failed {
			return .failed
		}
		.idle {
			return x.fail(.invalid) // not sent
		}
		else {}
	}
	if x.timed_out {
		x.pool.stats.timeouts++
		return x.fail(.timeout)
	}
	if x.phase == .connecting {
		// Writable (or an error / hangup): the connect finished one way or
		// the other.
		if ready_fd_error || transport.socket_error(x.fd) != 0 {
			return x.dial(mut el, cont, payload) // refused or unreachable: the next address
		}
		x.pool.cursor = x.addr_i // later exchanges start at the address that answers
		x.connected()
	}
	return x.drive(ready_fd_error, mut el, cont, payload)
}

// dial starts a connect to the origin's next untried address, on the slot's
// fd number when it has one (the retry and the next-address cases). Out of
// addresses (or time), the exchange fails with .connect, and a following
// Resolver is asked for fresh ones.
fn (mut x Exchange) dial(mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	mut p := x.pool
	now := time.sys_mono_now()
	for x.dials < p.addrs.len && (x.limit == 0 || now < x.limit) {
		x.addr_i = (x.base + x.dials) % p.addrs.len
		a := &p.addrs[x.addr_i]
		x.dials++
		nfd := transport.dial_addr(a, p.origin.tcp)
		if nfd < 0 {
			continue // refused at once: the next address
		}
		p.stats.dials++
		if x.fd >= 0 {
			if x.sess.active() {
				x.sess.reset(-1) // re-armed for the new socket once connected
			}
			if C.upstream_dup_onto(nfd, x.fd) < 0 {
				return x.fail(.connect)
			}
		} else {
			x.fd = nfd
		}
		x.born = now
		x.served = 0
		x.off = 0
		x.tls_wlen = 0
		x.phase = .connecting
		x.deadline = now + ms_ns(p.origin.connect_timeout_ms)
		if x.limit > 0 && x.deadline > x.limit {
			x.deadline = x.limit
		}
		return x.park(true, mut el, cont, payload)
	}
	p.request_resolve()
	return x.fail(if p.addrs.len == 0 { Failure.dns } else { Failure.connect })
}

// connected runs once the TCP connect succeeded: the TLS session goes on the
// socket (the slot's own, re-armed: no allocation after the first), or the
// request is next.
fn (mut x Exchange) connected() {
	now := time.sys_mono_now()
	if x.pool.origin.https {
		if x.sess.active() {
			x.sess.reset(x.fd)
		} else {
			x.sess = x.pool.tls_cfg.new_client_session(x.fd, x.pool.origin.host) or {
				x.phase = .failed
				x.failure = .tls
				return
			}
		}
		x.phase = .handshake
		return
	}
	x.phase = .sending
	x.deadline = now + ms_ns(x.pool.origin.response_timeout_ms)
	if x.limit > 0 && x.deadline > x.limit {
		x.deadline = x.limit
	}
}

// drive runs the exchange as far as it goes without waiting.
fn (mut x Exchange) drive(woke_err bool, mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	if x.phase == .failed {
		return .failed
	}
	if x.phase == .handshake {
		x.sess.mark_readable()
		r := x.sess.handshake()
		if r == tls.want || r == tls.want_write {
			return x.park(r == tls.want_write, mut el, cont, payload)
		}
		if r != 0 {
			return x.fail(if x.sess.verify_failed() { Failure.tls_verify } else { Failure.tls })
		}
		x.phase = .sending
		x.deadline = time.sys_mono_now() + ms_ns(x.pool.origin.response_timeout_ms)
		if x.limit > 0 && x.deadline > x.limit {
			x.deadline = x.limit
		}
	}
	if x.phase == .sending {
		total := x.head.len + x.body.len
		for x.off < total {
			n := x.write_some()
			if n > 0 {
				x.off += n
				continue
			}
			if n == io_answered {
				x.no_reuse = true
				break
			}
			if n == io_again {
				// A server that answers before reading the whole request (a 401,
				// a 413) and stops reading leaves the socket full: read that
				// answer instead of waiting for room that never comes.
				if x.answer_waiting() {
					x.no_reuse = true
					break
				}
				return x.park(x.wait_write, mut el, cont, payload)
			}
			// The send failed. An early answer may be waiting behind it; a kept
			// connection that died before answering is retried when that is safe.
			if x.answer_waiting() {
				x.no_reuse = true
				break
			}
			if x.can_retry() {
				return x.retry(mut el, cont, payload)
			}
			return x.fail(.send)
		}
		x.phase = .reading
		if x.off >= total && !woke_err {
			// The answer has not been asked for long enough to arrive: wait.
			return x.park(false, mut el, cont, payload)
		}
	}
	return x.read(mut el, cont, payload)
}

// read takes what arrived and frames it.
fn (mut x Exchange) read(mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	max := x.pool.origin.max_response_bytes
	if x.sess.active() {
		x.sess.mark_readable()
	}
	mut failed := false
	for {
		if x.resp.cap - x.resp.len < 4096 {
			if x.resp.len >= max {
				x.no_reuse = true
				return x.fail(.too_large)
			}
			mut grow := x.resp.cap
			if x.resp.cap + grow > max + 4096 {
				grow = max + 4096 - x.resp.cap
			}
			unsafe { x.resp.grow_cap(grow) }
		}
		n := x.read_some(unsafe { &u8(x.resp.data) + x.resp.len }, x.resp.cap - x.resp.len)
		if n > 0 {
			unsafe {
				x.resp.len += n
			}
			continue
		}
		if n == io_again {
			break
		}
		if n == io_eof {
			x.eof = true
		} else {
			failed = true
		}
		break
	}
	// eof for the framer: the peer closed — over TLS only with close_notify
	// (RFC 9112 §9.8): a bare FIN can be a truncation, so a body delimited by
	// the close is then never complete.
	clean_eof := x.eof && (!x.sess.active() || x.sess.close_notify())
	end := x.framer.feed(x.resp, clean_eof)
	if end > 0 {
		x.end = end
		x.phase = .ready
		return .ready
	}
	if end == client.err_malformed {
		x.no_reuse = true
		return x.fail(.malformed)
	}
	if x.resp.len > max {
		x.no_reuse = true
		return x.fail(.too_large)
	}
	if x.eof || failed || end == client.err_truncated {
		if x.resp.len == 0 {
			if x.can_retry() {
				return x.retry(mut el, cont, payload)
			}
			return x.fail(.closed)
		}
		return x.fail(.truncated)
	}
	return x.park(x.wait_write, mut el, cont, payload)
}

// write_some writes from the unsent part of head + body: a byte count,
// io_again (wait_write says for what) or io_failed.
fn (mut x Exchange) write_some() int {
	hl := x.head.len
	if !x.sess.active() {
		mut p1 := unsafe { &u8(nil) }
		mut n1 := 0
		mut p2 := unsafe { &u8(x.body.data) }
		mut n2 := x.body.len
		if x.off < hl {
			p1 = unsafe { &u8(x.head.data) + x.off }
			n1 = hl - x.off
		} else {
			p2 = unsafe { &u8(x.body.data) + (x.off - hl) }
			n2 = x.body.len - (x.off - hl)
		}
		r := C.upstream_send(x.fd, p1, usize(n1), p2, usize(n2))
		if r >= 0 {
			return int(r)
		}
		if r == -C.EAGAIN || r == -C.EWOULDBLOCK {
			x.wait_write = true
			return io_again
		}
		return io_failed
	}
	// TLS: one buffer at a time. A record Mbed TLS encrypted but could not send
	// whole stays in Mbed TLS, which must be called again with the same length
	// (pg_async's tls_wlen rule).
	if x.off > 0 && x.tls_wlen == 0 && C.upstream_peek(x.fd) == 1 {
		// The server sent something while the request is going out (past its
		// first record): an early answer, or TLS 1.3 session tickets. Read it
		// now, while no record of ours is pending: Mbed TLS takes a ticket
		// through its handshake path, which first flushes pending output, so
		// behind a stuck record of ours neither a ticket nor the answer after
		// it could be read.
		if x.read_early() {
			return io_answered
		}
	}
	mut p := unsafe { &u8(x.head.data) + x.off }
	mut len := hl - x.off
	if x.off >= hl {
		p = unsafe { &u8(x.body.data) + (x.off - hl) }
		len = x.body.len - (x.off - hl)
	}
	l := if x.tls_wlen > 0 { x.tls_wlen } else { len }
	n := x.sess.write_from(p, l)
	if n >= 0 {
		x.tls_wlen = 0
		return n
	}
	if n == tls.want || n == tls.want_write {
		x.wait_write = n == tls.want_write
		x.tls_wlen = l
		return io_again
	}
	return io_failed
}

// read_some reads into p[..max]: a byte count, io_again, io_eof or io_failed.
fn (mut x Exchange) read_some(p &u8, max int) int {
	if !x.sess.active() {
		r := C.upstream_recv(x.fd, p, usize(max))
		if r > 0 {
			return int(r)
		}
		if r == 0 {
			return io_eof
		}
		if r == -C.EAGAIN || r == -C.EWOULDBLOCK {
			x.wait_write = false
			return io_again
		}
		return io_failed
	}
	n := x.sess.read_into(p, max)
	if n > 0 {
		return n
	}
	if n == tls.want || n == tls.want_write {
		x.wait_write = n == tls.want_write
		return io_again
	}
	return if x.sess.peer_closed() { io_eof } else { io_failed }
}

// answer_waiting reports, while the request is still being sent, whether the
// server has begun to answer: then the rest of the request is not sent, the
// answer is read, and the connection is not reused.
fn (mut x Exchange) answer_waiting() bool {
	if x.resp.len > 0 {
		return true
	}
	if x.sess.active() {
		// Ciphertext may sit in the session's read-ahead already, so read
		// through the session whatever a raw peek says.
		return x.read_early()
	}
	return C.upstream_peek(x.fd) == 1
}

// read_early reads what the server sent through the TLS session while the
// request is going out: true when it is (the start of) the answer, false when
// it was only TLS 1.3 session tickets, consumed, or nothing could be read.
fn (mut x Exchange) read_early() bool {
	x.sess.mark_readable()
	if x.resp.cap - x.resp.len < 4096 {
		unsafe { x.resp.grow_cap(4096) }
	}
	n := x.sess.read_into(unsafe { &u8(x.resp.data) + x.resp.len }, x.resp.cap - x.resp.len)
	if n > 0 {
		unsafe {
			x.resp.len += n
		}
		return true
	}
	return false
}

// can_retry: the request may be sent once more on a fresh connection — only
// when it went out on a kept connection that died before any response byte,
// it is idempotent or marked retryable, and there is time left.
fn (x &Exchange) can_retry() bool {
	return !x.retried && x.served > 0 && x.resp.len == 0 && (x.idempotent || x.retry_ok)
		&& !x.timed_out
}

// retry sends the request again on a fresh connection, within the original
// deadline.
fn (mut x Exchange) retry(mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	x.retried = true
	x.pool.stats.retries++
	x.limit = x.deadline
	x.base = x.pool.cursor
	x.dials = 0
	x.resp.clear()
	x.framer.reset(x.is_head)
	x.eof = false
	return x.dial(mut el, cont, payload)
}

// park arms the slot's fd for the next step and reports .pending, moving the
// maintenance timer up when this exchange's deadline is the next one due.
fn (mut x Exchange) park(write bool, mut el core.EventLoop, cont core.WakeFn, payload voidptr) Poll {
	el.watch_fd_persistent(x.fd, if write { .writable } else { .readable }, cont, payload)
	if el.last_watched != x.fd {
		return x.fail(.invalid) // this worker cannot park a request (the TLS / IOCP workers)
	}
	x.pool.due(x.deadline)
	return .pending
}

fn (mut x Exchange) fail(f Failure) Poll {
	x.failure = f
	x.phase = .failed
	return .failed
}

@[inline]
fn ms_ns(ms int) u64 {
	return u64(ms) * u64(time.millisecond)
}

// wi appends n's decimal digits.
fn wi(mut out []u8, n int) {
	if n == 0 {
		out << `0`
		return
	}
	mut d := [20]u8{}
	mut i := d.len
	mut v := n
	for v > 0 {
		i--
		d[i] = u8(`0` + v % 10)
		v /= 10
	}
	unsafe { out.push_many(&d[i], d.len - i) }
}
