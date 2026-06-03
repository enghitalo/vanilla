module backend_epoll

// TLS connection state machine (epoll worker side). The plaintext path is
// untouched and uses a separate worker — this code only runs for HTTPS
// connections, so it adds zero cost to the plain hot path.
//
// Mirrors the plain state machine (conn_state.c.v) over a TLS session:
//   • handshake   — driven across epoll edges; WANT_READ waits on EPOLLIN,
//     WANT_WRITE arms EPOLLOUT (a handshake flight can fill the send buffer);
//   • cross-edge reads — a request split across TLS records / round-trips is
//     buffered per-fd in `read_buf` and resumed on the next EPOLLIN;
//   • EPOLLOUT writes  — a response that can't be flushed (TLS WANT_WRITE) is
//     parked in `write_buf` and drained on EPOLLOUT (mbedTLS is re-called with
//     the same arguments until it accepts them);
//   • timeouts    — per-conn read/write deadlines, swept by the worker.
//
// Per-fd state lives in a per-worker `map[int]&TlsConn`; the worker is
// single-threaded, so no locking.

import http_server.core
import http_server.epoll
import http_server.http1_1.request_parser
import http_server.tls
import sync.stdatomic
import time

#include <sys/epoll.h>

const tls_max_request_bytes = 8 * 1024 * 1024

struct TlsConn {
mut:
	sess           tls.Session
	established    bool
	watching_out   bool // currently subscribed to EPOLLOUT (avoid redundant epoll_ctl)
	read_buf       []u8 // partial request accumulated across edges
	write_buf      []u8 // response remaining to be flushed (mbedTLS retries same data)
	write_off      int
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read
	write_deadline u64 // monotonic ns; >0 while a response is parked
}

// tls_set_out subscribes/unsubscribes the fd from EPOLLOUT, but only issues the
// epoll_ctl syscall when the state actually changes.
@[inline]
fn tls_set_out(mut conn TlsConn, epoll_fd int, fd int, want_out bool) {
	if conn.watching_out == want_out {
		return
	}
	conn.watching_out = want_out
	if want_out {
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLOUT | C.EPOLLET))
	} else {
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET))
	}
}

// tls_handshake_step drives the handshake one step. Returns true once the
// session is established (caller may proceed to read); false while it is still
// pending or has been closed (caller must return).
fn tls_handshake_step(mut conn TlsConn, epoll_fd int, fd int, active_conns &core.Counter, mut sessions map[int]&TlsConn) bool {
	r := conn.sess.handshake()
	if r == tls.want {
		tls_set_out(mut conn, epoll_fd, fd, false) // need to read — EPOLLIN only
		return false
	}
	if r == tls.want_write {
		tls_set_out(mut conn, epoll_fd, fd, true) // send buffer full — wait for EPOLLOUT
		return false
	}
	if r == tls.closed {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return false
	}
	conn.established = true
	tls_set_out(mut conn, epoll_fd, fd, false) // handshake done — back to reading
	return true
}

@[direct_array_access; manualfree]
fn handle_readable_fd_tls(request_handler fn ([]u8, int) ![]u8, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	mut conn := sessions[fd] or {
		s := cfg.new_session(fd) or {
			release_conn(epoll_fd, fd, active_conns)
			return
		}
		nc := &TlsConn{
			sess: s
		}
		sessions[fd] = nc
		nc
	}

	// 1) Drive the handshake (spans multiple readiness events).
	if !conn.established {
		if !tls_handshake_step(mut conn, epoll_fd, fd, active_conns, mut sessions) {
			return
		}
		// established — fall through: a request may already be buffered by TLS.
	}

	// 2) Read one complete request over TLS, resuming any partial from a prior edge.
	mut buf := []u8{len: 0, cap: 256}
	if conn.read_buf.len > 0 {
		unsafe {
			buf = conn.read_buf // take ownership (move)
		}
		conn.read_buf = []u8{}
	}

	for {
		if buf.len == buf.cap {
			unsafe { buf.grow_cap(buf.cap) }
		}
		spare := buf.cap - buf.len
		n := conn.sess.read_into(unsafe { &u8(buf.data) + buf.len }, spare)
		if n == tls.want {
			if buf.len == 0 {
				unsafe { buf.free() }
				return // nothing buffered yet — keep the connection, wait for EPOLLIN
			}
			tls_save_read(mut conn, buf, limits.read_timeout_ms) // partial — resume on EPOLLIN
			return
		}
		if n == tls.want_write {
			// Rare (post-handshake key update / ticket): TLS needs to write before
			// it can read more. Park the partial read and wait for EPOLLOUT.
			tls_save_read(mut conn, buf, limits.read_timeout_ms)
			tls_set_out(mut conn, epoll_fd, fd, true)
			return
		}
		if n <= 0 { // closed / fatal
			unsafe { buf.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions)
			return
		}
		unsafe { buf.len += n }
		if buf.len > tls_max_request_bytes {
			unsafe { buf.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions)
			return
		}
		total := request_parser.frame_request_length_lim(buf, limits.max_header_bytes,
			limits.max_body_bytes) or {
			unsafe { buf.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions) // malformed/too-large → drop
			return
		}
		if total >= 0 {
			if buf.len > total {
				buf.trim(total)
			}
			break
		}
		// incomplete — keep draining this burst
	}

	// Request complete — clear the read deadline.
	conn.read_deadline = 0

	resp := request_handler(buf, fd) or {
		unsafe { buf.free() }
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return
	}
	unsafe { buf.free() }
	tls_send_or_park(epoll_fd, fd, limits, active_conns, mut sessions, mut conn, resp)
}

// handle_writable_fd_tls resumes work blocked on writability: a handshake that
// wanted to write, or a parked response.
@[direct_array_access; manualfree]
fn handle_writable_fd_tls(epoll_fd int, fd int, active_conns &core.Counter, mut sessions map[int]&TlsConn) {
	mut conn := sessions[fd] or { return }

	if !conn.established {
		// Handshake was waiting to write; advance it. If still not done, the step
		// re-arms the right readiness; if done, it falls through with nothing parked.
		tls_handshake_step(mut conn, epoll_fd, fd, active_conns, mut sessions)
		return
	}

	if conn.write_buf.len == 0 {
		tls_set_out(mut conn, epoll_fd, fd, false) // spurious — stop watching writability
		return
	}

	for conn.write_off < conn.write_buf.len {
		n := conn.sess.write_from(unsafe { &u8(conn.write_buf.data) + conn.write_off },
			conn.write_buf.len - conn.write_off)
		if n > 0 {
			conn.write_off += n
			continue
		}
		if n == tls.want || n == tls.want_write {
			return // still blocked — wait for the next EPOLLOUT
		}
		close_tls(epoll_fd, fd, active_conns, mut sessions) // fatal
		return
	}
	// Fully flushed — keep-alive; drop the parked state and stop watching writability.
	unsafe { conn.write_buf.free() }
	conn.write_buf = []u8{}
	conn.write_off = 0
	conn.write_deadline = 0
	tls_set_out(mut conn, epoll_fd, fd, false)
}

// tls_send_or_park encrypts and sends the whole response, or parks the remainder
// for EPOLLOUT. Takes ownership of `resp` (frees it when fully sent or parked).
@[manualfree]
fn tls_send_or_park(epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut sessions map[int]&TlsConn, mut conn TlsConn, resp []u8) {
	mut sent := 0
	for sent < resp.len {
		n := conn.sess.write_from(unsafe { &u8(resp.data) + sent }, resp.len - sent)
		if n > 0 {
			sent += n
			continue
		}
		if n == tls.want || n == tls.want_write {
			tls_park_write(mut conn, resp, sent, limits.write_timeout_ms) // ownership → parked
			tls_set_out(mut conn, epoll_fd, fd, true)
			return
		}
		unsafe { resp.free() }
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return
	}
	unsafe { resp.free() }
	tls_set_out(mut conn, epoll_fd, fd, false) // keep-alive; not waiting on writability
}

fn tls_save_read(mut conn TlsConn, buf []u8, read_timeout_ms int) {
	conn.read_buf = buf
	if read_timeout_ms > 0 && conn.read_deadline == 0 {
		conn.read_deadline = time.sys_mono_now() + u64(read_timeout_ms) * 1_000_000
	}
}

fn tls_park_write(mut conn TlsConn, resp []u8, sent int, write_timeout_ms int) {
	conn.write_buf = resp
	conn.write_off = sent
	if write_timeout_ms > 0 {
		conn.write_deadline = time.sys_mono_now() + u64(write_timeout_ms) * 1_000_000
	}
}

// sweep_timeouts_tls closes TLS connections whose read/write deadline passed.
// (No 408 is sent: encrypting a reply onto a stalled socket would itself block;
// dropping the connection is the honest action.)
@[manualfree]
fn sweep_timeouts_tls(epoll_fd int, active_conns &core.Counter, mut sessions map[int]&TlsConn) {
	now := time.sys_mono_now()
	mut expired := []int{}
	for fd, conn in sessions {
		if conn.read_deadline > 0 && now > conn.read_deadline {
			expired << fd
		} else if conn.write_deadline > 0 && now > conn.write_deadline {
			expired << fd
		}
	}
	for fd in expired {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
	}
}

@[manualfree]
fn close_tls(epoll_fd int, fd int, active_conns &core.Counter, mut sessions map[int]&TlsConn) {
	if mut c := sessions[fd] {
		unsafe {
			if c.read_buf.len > 0 {
				c.read_buf.free()
			}
			if c.write_buf.len > 0 {
				c.write_buf.free()
			}
		}
		c.sess.free()
		sessions.delete(fd)
	}
	release_conn(epoll_fd, fd, active_conns)
}
