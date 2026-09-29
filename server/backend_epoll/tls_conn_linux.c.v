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
//   • timeouts    — per-conn read/write/idle deadlines, swept by the worker.
//     The first one starts at accept (the EPOLLOUT birth edge, see
//     handle_writable_fd_tls), so a peer that never sends a byte, or stalls
//     mid-handshake, is reaped like any other. Every expiry closes silently.
//
// Per-fd state lives in a per-worker `map[int]&TlsConn`; the worker is
// single-threaded, so no locking.
import core
import epoll
import http1_1.request_parser
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
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read — from accept for the first one (bounds a silent connect + the handshake)
	write_deadline u64 // monotonic ns; >0 while a response is parked
	idle_deadline  u64 // monotonic ns; >0 while waiting for the first plaintext byte of a request: keep-alive idle, or a new connection when read_timeout_ms is 0
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
fn handle_readable_fd_tls(handler core.Handler, state voidptr, epoll_fd int, fd int, limits core.Limits, idle_ms int, counter &core.Counter, active_conns &core.Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	// nil = no session yet (see handle_writable_fd_tls for why not `or {}`).
	mut conn := unsafe { sessions[fd] }
	if conn == unsafe { nil } {
		conn = tls_open_conn(cfg, epoll_fd, fd, limits, idle_ms, active_conns, mut sessions) or {
			return
		}
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
				// No plaintext yet (a record fragment, or a non-application
				// record): return the buffer to the pool. This is not a first
				// byte, so an armed idle/accept deadline keeps running.
				conn.read_buf = buf
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
		// First plaintext byte of a request: the idle phase is over. If the
		// request stays incomplete, tls_save_read arms its read deadline.
		conn.idle_deadline = 0
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

	// Request complete — clear the read deadline (for the first request, the
	// one armed at accept).
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
			tls_send_or_park(epoll_fd, fd, limits, idle_ms, active_conns, mut sessions, mut
				conn, resp)
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
// wanted to write, or a parked response. An EPOLLOUT on an fd with no session
// is the connection's birth (accept registered it with EPOLLOUT, see
// accept_events): create the session, arm the accept-time deadline and switch
// the fd back to EPOLLIN. The caller still runs the EPOLLIN half of the same
// event, which starts the handshake if the ClientHello came with the connect.
@[direct_array_access; manualfree]
fn handle_writable_fd_tls(epoll_fd int, fd int, limits core.Limits, idle_ms int, active_conns &core.Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) {
	// One lookup, nil on a miss. Not `sessions[fd] or {}`: on a miss that
	// allocates its "key does not exist" error, once per connection — a leak
	// under -gc none, and every connection's birth is a miss.
	mut conn := unsafe { sessions[fd] }
	if conn == unsafe { nil } {
		mut nc := tls_open_conn(cfg, epoll_fd, fd, limits, idle_ms, active_conns, mut sessions) or {
			return
		}
		tls_set_out(mut nc, epoll_fd, fd, false) // birth edge consumed — EPOLLIN only
		return
	}

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
	tls_arm_idle(mut conn, idle_ms)
	tls_set_out(mut conn, epoll_fd, fd, false)
}

// tls_send_or_park encrypts and sends the whole response, or parks the remainder
// for EPOLLOUT. Takes ownership of `resp` (frees it when fully sent or parked).
@[manualfree]
fn tls_send_or_park(epoll_fd int, fd int, limits core.Limits, idle_ms int, active_conns &core.Counter, mut sessions map[int]&TlsConn, mut conn TlsConn, resp []u8) {
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
	tls_arm_idle(mut conn, idle_ms) // keep-alive: wait for the next request
	tls_set_out(mut conn, epoll_fd, fd, false) // keep-alive; not waiting on writability
}

// tls_open_conn creates fd's session and per-connection state, on the
// accept-time EPOLLOUT birth edge or, when accept registered no EPOLLOUT (no
// deadline starts at accept), lazily on the first EPOLLIN. It arms the
// accept-time deadline: READ when read_timeout_ms > 0 — it bounds the TCP
// silence, the whole handshake (WANT_WRITE flights included) and the first
// request, and progress never refreshes it — else IDLE (a connection that has
// sent nothing is idle; its first plaintext byte clears it). watching_out
// mirrors the mask the fd was registered with: were it false on an
// EPOLLOUT-registered fd, tls_set_out(false) would short-circuit and every
// later wake would report EPOLLOUT too. A session that cannot be created
// releases the connection and returns none.
fn tls_open_conn(cfg &tls.Config, epoll_fd int, fd int, limits core.Limits, idle_ms int, active_conns &core.Counter, mut sessions map[int]&TlsConn) ?&TlsConn {
	s := cfg.new_session(fd) or {
		release_conn(epoll_fd, fd, active_conns)
		return none
	}
	mut conn := &TlsConn{
		sess:         s
		watching_out: accept_events(limits) & u32(C.EPOLLOUT) != 0
	}
	if limits.read_timeout_ms > 0 {
		conn.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
	} else if idle_ms > 0 {
		conn.idle_deadline = time.sys_mono_now() + u64(idle_ms) * 1_000_000
	}
	sessions[fd] = conn
	return conn
}

// tls_arm_idle starts the keep-alive idle clock once a response has been fully
// handed to the kernel. Not while bytes of the next request are buffered: that
// partial is governed by its read deadline. idle_ms is the worker's resolved
// Limits.idle_ms() (0 = off).
@[inline]
fn tls_arm_idle(mut conn TlsConn, idle_ms int) {
	if idle_ms > 0 && conn.read_buf.len == 0 {
		conn.idle_deadline = time.sys_mono_now() + u64(idle_ms) * 1_000_000
	}
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

// sweep_timeouts_tls closes TLS connections whose read, write or idle deadline
// passed — silently in every phase (accept, handshake, request, parked
// response, keep-alive idle): no 408 is sent, since encrypting a reply onto a
// stalled socket would itself block and a peer that never spoke has nothing
// to parse; dropping the connection is the honest action. Rate-limited: it
// reads the clock once and walks the table only when `next_sweep` has come.
// `expired` is the worker's reusable scratch, so a sweep allocates nothing.
// Returns the next sweep time and the epoll_wait timeout until it (1..interval
// ms), so an idle worker wakes for it. Not a full interval after every batch:
// a batch that lands just before `next_sweep` would then push the walk to
// almost two intervals after the previous one.
@[manualfree]
fn sweep_timeouts_tls(epoll_fd int, active_conns &core.Counter, next_sweep u64, interval_ns u64, mut expired []int, mut sessions map[int]&TlsConn) (u64, int) {
	now := time.sys_mono_now()
	if now < next_sweep {
		return next_sweep, int((next_sweep - now + 999_999) / 1_000_000)
	}
	expired.clear()
	for fd, conn in sessions {
		if (conn.read_deadline > 0 && now > conn.read_deadline)
			|| (conn.write_deadline > 0 && now > conn.write_deadline)
			|| (conn.idle_deadline > 0 && now > conn.idle_deadline) {
			expired << fd
		}
	}
	for fd in expired {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
	}
	return now + interval_ns, int(interval_ns / 1_000_000)
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
		// The TlsConn itself: no caller touches it after close_tls. Freed, not
		// left to the GC, because the epoll build runs with -gc none and every
		// reaped connection (a silent connect included) allocated one.
		unsafe { free(c) }
	}
	release_conn(epoll_fd, fd, active_conns)
}
