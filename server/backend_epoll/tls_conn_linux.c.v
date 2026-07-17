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
import core
import epoll
import http1.request_parser
import tls
import sync.stdatomic
import time

#include <sys/epoll.h>

const tls_max_request_bytes = 8 * 1024 * 1024

struct TlsConn {
mut:
	sess           tls.Session
	established    bool
	ktls           bool // kTLS engaged: reads/writes are PLAIN recv/send, kernel does AES-GCM
	watching_out   bool // currently subscribed to EPOLLOUT (avoid redundant epoll_ctl)
	read_buf       []u8 // per-conn request buffer: a partial across edges (len>0) or an empty pooled buffer reused next request (len==0, cap>0)
	resp_buf       []u8 // per-conn response buffer, pooled across requests (reset to len 0, reused)
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
		epoll.mod_fd_in_epoll(epoll_fd, fd, (u32(C.EPOLLIN) | u32(C.EPOLLOUT) | u32(C.EPOLLET)))
	} else {
		epoll.mod_fd_in_epoll(epoll_fd, fd, (u32(C.EPOLLIN) | u32(C.EPOLLET)))
	}
}

// ktls_send writes plaintext over a kTLS socket (the kernel encrypts it into a TLS
// record). Returns the byte count (>0), tls.want_write on EAGAIN (park on EPOLLOUT),
// or tls.closed on a fatal error — the same sentinels Session.write_from returns, so
// the call sites branch uniformly. MSG_NOSIGNAL avoids SIGPIPE; MSG_WAITALL must
// NEVER be used on a kTLS socket (the TLS ULP rejects it).
@[inline]
fn ktls_send(fd int, ptr &u8, len int) int {
	r := C.send(fd, ptr, usize(len), C.MSG_NOSIGNAL)
	if r < 0 {
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			return tls.want_write
		}
		return tls.closed
	}
	return int(r)
}

// ktls_recv reads PLAINTEXT from a kTLS socket (the kernel already decrypted the
// record). Returns the byte count (>0), tls.want on EAGAIN (wait for EPOLLIN), or
// tls.closed on EOF/error — the same sentinels Session.read_into returns, so the
// call site branches uniformly. A non-application-data record (e.g. a peer alert)
// surfaces as an error here and maps to tls.closed, which is the right action for
// the request/response profile; tickets are disabled so no KeyUpdate arrives.
@[inline]
fn ktls_recv(fd int, ptr &u8, len int) int {
	r := C.recv(fd, ptr, usize(len), 0)
	if r < 0 {
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			return tls.want
		}
		return tls.closed
	}
	if r == 0 {
		return tls.closed
	}
	return int(r)
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
	// Hand record crypto to the kernel (kTLS). On success, subsequent reads/writes
	// are plain recv()/send() syscalls and the kernel does AES-128-GCM — no userspace
	// crypto and no PSA key-store mutex on the hot path. This fires exactly once, at
	// handshake completion, before any application data — the correct handoff point.
	// false => stay on the userspace mbedtls path (clean fallback); but if a setsockopt
	// failed AFTER the ULP attached, the socket is half-converted, so close.
	conn.ktls = conn.sess.enable_ktls(fd)
	if !conn.ktls && conn.sess.ktls_failed() {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return false
	}
	tls_set_out(mut conn, epoll_fd, fd, false) // handshake done — back to reading
	return true
}

@[direct_array_access; manualfree]
fn handle_readable_fd_tls(handler core.Handler, state voidptr, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) {
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

	// 2) Read one complete request over TLS. Reuse the per-conn read buffer: a
	// partial from a prior edge (len>0) or an empty buffer pooled from the last
	// completed request (len==0, cap>0). Allocate only on this conn's first use.
	mut buf := []u8{}
	if conn.read_buf.cap > 0 {
		unsafe {
			buf = conn.read_buf // move (preserves a partial; empty otherwise)
		}
		conn.read_buf = []u8{}
	} else {
		buf = []u8{len: 0, cap: 256}
	}

	for {
		if buf.len == buf.cap {
			unsafe { buf.grow_cap(buf.cap) }
		}
		spare := buf.cap - buf.len
		// kTLS: read PLAINTEXT straight from the socket (kernel already decrypted).
		// Otherwise decrypt in userspace via mbedtls. Both yield the same sentinels.
		n := if conn.ktls {
			ktls_recv(fd, unsafe { &u8(buf.data) + buf.len }, spare)
		} else {
			conn.sess.read_into(unsafe { &u8(buf.data) + buf.len }, spare)
		}
		if n == tls.want {
			if buf.len == 0 {
				conn.read_buf = buf // nothing buffered yet — return to the pool, no deadline
				return
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
		unsafe {
			buf.len += n
		}
		req_cap := if limits.max_request_bytes > 0 {
			limits.max_request_bytes
		} else {
			tls_max_request_bytes
		}
		if buf.len > req_cap {
			unsafe { buf.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions)
			return
		}
		// _idx twin: plain int, no per-request !int boxing. >=0 complete, -1
		// incomplete, < -1 a framing/limit error (the TLS path drops on any error).
		total := request_parser.frame_request_length_lim_idx(buf, limits.max_header_bytes,
			limits.max_body_bytes)
		if total >= 0 {
			if buf.len > total {
				buf.trim(total)
			}
			break
		}
		if total < -1 {
			unsafe { buf.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions) // malformed/too-large → drop
			return
		}
		// total == -1: incomplete — keep draining this burst
	}

	// Request complete — clear the read deadline.
	conn.read_deadline = 0

	// Per-connection response buffer, pooled across requests (reset to len 0 and
	// reused; allocated on first use). The handler appends raw response bytes.
	mut resp := []u8{}
	if conn.resp_buf.cap > 0 {
		unsafe {
			resp = conn.resp_buf // move out of the pool
		}
		conn.resp_buf = []u8{}
	} else {
		resp = []u8{len: 0, cap: 4096}
	}
	// The TLS worker has no watch reactor: register is a stub that arms nothing,
	// so a handler that calls event_loop.watch_fd and suspends is dropped below.
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		register:  core.reject_register
	}
	step := handler(buf, mut resp, fd, state, mut event_loop)
	unsafe {
		buf.len = 0
	}
	conn.read_buf = buf // pool the read buffer's capacity for the next request
	match step {
		.done {
			tls_send_or_park(epoll_fd, fd, limits, active_conns, mut sessions, mut conn, resp)
		}
		.close {
			// Flush-then-close: best-effort synchronous write of whatever the
			// handler appended (e.g. its error response), then drop the session.
			// A send that cannot complete now (want/want_write) is abandoned —
			// the connection is closing anyway.
			tls_write_all_best_effort(mut conn, fd, resp)
			unsafe { resp.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions)
		}
		.suspend {
			// Parking is not supported over TLS (no reactor on this worker; see
			// core.reject_register): nothing was armed, so nothing leaks — drop the
			// connection rather than strand a request that can never be resumed.
			// Loud on purpose: a handler that works on plaintext and silently
			// RSTs over HTTPS is otherwise undiagnosable from the server side.
			eprintln('[tls] handler returned .suspend but the TLS worker has no watch reactor; dropping the connection')
			unsafe { resp.free() }
			close_tls(epoll_fd, fd, active_conns, mut sessions)
		}
	}
}

// tls_write_chunk writes one chunk over the session — kTLS plaintext send or
// userspace mbedtls — returning the byte count or the tls.want/want_write/
// closed sentinels, so every write loop branches uniformly.
@[inline]
fn tls_write_chunk(mut conn TlsConn, fd int, ptr &u8, len int) int {
	return if conn.ktls { ktls_send(fd, ptr, len) } else { conn.sess.write_from(ptr, len) }
}

// tls_write_all_best_effort synchronously writes as much of `resp` as the TLS
// session will take right now — used only on the .close path, where a partial
// send is acceptable (the connection is being dropped).
fn tls_write_all_best_effort(mut conn TlsConn, fd int, resp []u8) {
	mut off := 0
	for off < resp.len {
		n := tls_write_chunk(mut conn, fd, unsafe { &u8(resp.data) + off }, resp.len - off)
		if n <= 0 {
			return
		}
		off += n
	}
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
		n := tls_write_chunk(mut conn, fd, unsafe { &u8(conn.write_buf.data) + conn.write_off },
			conn.write_buf.len - conn.write_off)
		if n > 0 {
			conn.write_off += n
			continue
		}
		if n == tls.want || n == tls.want_write {
			return
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
		n := tls_write_chunk(mut conn, fd, unsafe { &u8(resp.data) + sent }, resp.len - sent)
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
	mut done := unsafe { resp }
	unsafe {
		done.len = 0
	}
	conn.resp_buf = done // return to the per-conn pool instead of freeing
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
			// read_buf / resp_buf are pooled and may be empty-but-allocated
			// (len 0, cap > 0), so free on capacity, not length.
			if c.read_buf.cap > 0 {
				c.read_buf.free()
			}
			if c.resp_buf.cap > 0 {
				c.resp_buf.free()
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
