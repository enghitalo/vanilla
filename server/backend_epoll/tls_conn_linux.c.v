module backend_epoll

// TLS connection state machine (epoll worker side). The plaintext path is
// untouched and uses a separate worker — this code only runs for HTTPS
// connections, so it adds zero cost to the plain hot path.
//
// Mirrors the plain state machine (conn_state.c.v) over a TLS session:
//   • handshake   — driven across epoll edges; WANT_READ waits on EPOLLIN,
//     WANT_WRITE arms EPOLLOUT (a handshake flight can fill the send buffer);
//   • pipelining  — every edge reads to the end of the burst and answers every
//     complete request in order, batching the responses into one send; a
//     request split across TLS records / round-trips is buffered per-fd in
//     `read_buf` and resumed on the next EPOLLIN;
//   • EPOLLOUT writes  — a response that can't be flushed (TLS WANT_WRITE) is
//     parked in `write_buf` and drained on EPOLLOUT (mbedTLS is re-called with
//     the same arguments until it accepts them). Nothing is read or served
//     while it is parked; reading resumes once it drains;
//   • file bodies — on a kTLS connection a handler may hand its body off with
//     core.queue_file: the batch goes out with MSG_MORE, so the kernel keeps
//     the record holding the headers open, and sendfile(2) streams the file
//     into it with no userspace copy (the kernel encrypts it like any send).
//     The file is sent before the next pipelined request is answered, and one
//     that cannot go out yet parks like a response; a step that closes gets
//     one best-effort send of it before the close. A userspace-TLS
//     connection never takes a file (sendfile writes plaintext): the hand-off
//     is closed for it, so its handler appends the bytes;
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
// One full TLS record of plaintext (2^14). Responses to pipelined requests
// are appended into one buffer and sent together; once it holds this much it
// is sent before the next request is served: mbedTLS encrypts at most one
// record per write, so below it batching packs small responses into one
// record and one syscall, and above it there is nothing left to save. It also
// caps how far a read that fills the read buffer grows it (a pipelined burst
// is then read a record at a time, not a few hundred bytes at a time).
const tls_record_bytes = 16 * 1024

// TlsFlush is how a send of a whole response batch ended (tls_flush).
enum TlsFlush {
	sent   // all of it went out: the caller may reuse the buffer
	parked // the rest waits for EPOLLOUT in write_buf, which now owns the buffer
	failed // fatal: the caller closes (the buffer is still its own)
}

struct TlsConn {
mut:
	sess           tls.Session
	established    bool
	ktls           bool // kTLS engaged: reads/writes are PLAIN recv/send, kernel does AES-GCM
	watching_out   bool // currently subscribed to EPOLLOUT (avoid redundant epoll_ctl)
	read_buf       []u8 // per-conn request buffer: a partial across edges (len>0) or an empty pooled buffer reused next request (len==0, cap>0)
	resp_buf       []u8 // per-conn response buffer, pooled across requests (reset to len 0, reused)
	write_buf      []u8 // response remaining to be flushed (mbedTLS retries same data); a parked file keeps its sent batch here
	write_off      int
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read — from accept for the first one (bounds a silent connect + the handshake)
	write_deadline u64 // monotonic ns; >0 while a response is parked
	idle_deadline  u64 // monotonic ns; >0 while waiting for the first plaintext byte of a request: keep-alive idle, or a new connection when read_timeout_ms is 0
	// File body to stream with sendfile(2) after the batch (kTLS only, handed
	// off with core.queue_file). file_fd is BORROWED (the asset table owns it)
	// and never closed here; the kernel advances file_off as bytes go out.
	file_fd        int = -1
	file_off       i64
	file_remaining i64
	no_sendfile    bool // this kTLS socket refused sendfile(2): its files go out as bytes
}

// parked reports whether a response owns the write side: bytes waiting in
// write_buf, or a file body not fully sent.
@[inline]
fn (c &TlsConn) parked() bool {
	return c.write_buf.len > 0 || c.file_remaining > 0
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
// record). `more` adds MSG_MORE: the kernel keeps the record open for what is sent
// next (a file body, see tls_write_chunk) instead of closing it with this send.
// Returns the byte count (>0), tls.want_write on EAGAIN (park on EPOLLOUT),
// or tls.closed on a fatal error — the same sentinels Session.write_from returns, so
// the call sites branch uniformly. MSG_NOSIGNAL avoids SIGPIPE; MSG_WAITALL must
// NEVER be used on a kTLS socket (the TLS ULP rejects it).
@[inline]
fn ktls_send(fd int, ptr &u8, len int, more bool) int {
	flags := if more { C.MSG_NOSIGNAL | C.MSG_MORE } else { C.MSG_NOSIGNAL }
	r := C.send(fd, ptr, usize(len), flags)
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

// handle_readable_fd_tls runs on a readable edge, and when reads resume after
// a parked response drained (handle_writable_fd_tls). It drives the handshake,
// then reads to the end of the burst and answers every complete request.
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
	if !conn.ktls {
		conn.sess.mark_readable() // this edge may have brought bytes (see vtls_mark_readable)
	}

	// 1) Drive the handshake (spans multiple readiness events).
	if !conn.established {
		if !tls_handshake_step(mut conn, epoll_fd, fd, active_conns, mut sessions) {
			return
		}
		// established — fall through: a request may already be buffered by TLS.
	}

	// 2) A response parked on WANT_WRITE (its bytes, or a file body behind
	// them) owns the write side until it drains: mbedTLS must be re-called
	// with the same data, and on kTLS a new response would interleave with it.
	// Read nothing and serve nothing meanwhile: the bytes wait in the socket
	// (or in mbedTLS), and handle_writable_fd_tls resumes here once the parked
	// response is out.
	if conn.parked() {
		return
	}

	// 3) Read to the end of the burst, answering every complete request as it
	// arrives. Edge-triggered: bytes not read now raise no new edge, so a burst
	// must be drained. Reuse the per-conn buffers (moved out here, handed back
	// on every exit): read_buf holds a partial, or requests left unserved
	// behind a parked response, or is empty and pooled; resp_buf is the pooled
	// response buffer, which collects every response of the burst.
	mut buf := []u8{}
	if conn.read_buf.cap > 0 {
		unsafe {
			buf = conn.read_buf // move (preserves buffered bytes; empty otherwise)
		}
		conn.read_buf = []u8{}
	} else {
		buf = []u8{len: 0, cap: 256}
		// Both buffers live and die with this connection, so a growth must free
		// the block it outgrew: under -gc none it would leak otherwise, once
		// per connection. Safe: the handler only ever sees views of buf, and
		// V keeps the old block of resp if the handler took a slice of it.
		unsafe { buf.flags.set(.noslices) }
	}
	mut resp := []u8{}
	if conn.resp_buf.cap > 0 {
		unsafe {
			resp = conn.resp_buf // move out of the pool (allocated below on first use)
		}
		conn.resp_buf = []u8{}
	}
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		tls_max_request_bytes
	}
	// The TLS worker has no watch reactor: register is a stub that arms nothing,
	// so a handler that calls event_loop.watch_fd and suspends is dropped below.
	mut event_loop := core.EventLoop{
		client_fd: fd
		loop_fd:   epoll_fd
		register:  core.reject_register
	}
	mut sent := false // a response went out in this call: a request boundary (idle)
	mut drained := false // kTLS: a short recv emptied the socket (userspace: vtls_read tracks it)
	mut filled := false // the last read filled the buffer: the burst may be larger
	for {
		// Answer every complete request buffered, in order. Bytes left from an
		// earlier call come first: after a parked response drained, no edge
		// reports them again.
		mut pos := 0
		for pos < buf.len {
			// _idx twin: plain int, no per-request !int boxing. >=0 complete, -1
			// incomplete, < -1 a framing/limit error (the TLS path drops on any error).
			total := request_parser.frame_request_length_lim_idx(buf_view(buf, pos,
				buf.len - pos), limits.max_header_bytes, limits.max_body_bytes)
			if total == -1 {
				break
			}
			if total < -1 {
				tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp) // malformed/too-large → drop
				return
			}
			// Request complete: its read deadline (for the first request, the one
			// armed at accept) is over.
			conn.read_deadline = 0
			if resp.cap == 0 {
				resp = []u8{len: 0, cap: 4096}
				unsafe { resp.flags.set(.noslices) } // see buf above
			}
			// sendfile(2) writes plaintext, which only a kTLS socket encrypts: the
			// file hand-off is open for a kTLS connection whose socket takes it,
			// closed for a userspace-TLS one (its handler appends the bytes).
			core.set_queue_file_allowed(conn.ktls && !conn.no_sendfile)
			step := handler(buf_view(buf, pos, total), mut resp, fd, state, mut event_loop)
			pos += total
			// The sendfile slot is thread-local: drain it after EVERY step, as
			// the plain worker does, or a region left queued would be taken after
			// the next .done on this worker, for any connection. On .done and
			// .close it is this response's body, sent after resp with sendfile(2)
			// (only a kTLS connection can queue one): by the flush below, or by
			// the one best-effort write before the close, bounded by the socket
			// send buffer like the rest of that response (the plain worker
			// instead sends all of it before closing). On .suspend it is
			// dropped with the connection.
			if qf := core.take_queued_file() {
				if step != .suspend {
					conn.file_fd = qf.file_fd
					conn.file_off = qf.off
					conn.file_remaining = qf.len
				}
			}
			match step {
				.done {}
				.close {
					// Flush-then-close: best-effort synchronous write of everything
					// appended (the responses before it, then the handler's
					// response) and of the file queued behind it, then drop the
					// session. A send that cannot complete now (want/want_write) is
					// abandoned — the connection is closing.
					tls_write_all_best_effort(mut conn, fd, mut resp)
					tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp)
					return
				}
				.suspend {
					// Parking is not supported over TLS (no reactor on this worker; see
					// core.reject_register): nothing was armed, so nothing leaks — drop the
					// connection rather than strand a request that can never be resumed.
					// Loud on purpose: a handler that works on plaintext and silently
					// RSTs over HTTPS is otherwise undiagnosable from the server side.
					eprintln('[tls] handler returned .suspend but the TLS worker has no watch reactor; dropping the connection')
					tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp)
					return
				}
			}
			// A queued file is sent right away, before the next request is
			// answered: sendfile streams it after the batch, so nothing may be
			// appended behind it. Hence whenever a handler runs, and when the
			// burst's last flush runs, no file is pending.
			if resp.len >= tls_record_bytes || conn.file_remaining > 0 {
				match tls_flush(mut conn, epoll_fd, fd, limits.write_timeout_ms, mut resp) {
					.sent {
						unsafe {
							resp.len = 0
						}
						sent = true
					}
					.parked {
						// Stop here: what is left (requests not answered yet, a
						// partial) waits in read_buf and is served when reads
						// resume. No read deadline meanwhile: the parked response
						// runs on write_timeout_ms, and a slow download must not
						// reap the requests queued behind it.
						tls_compact(mut buf, pos)
						conn.read_buf = buf
						return
					}
					.failed {
						tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp)
						return
					}
				}
			}
		}
		tls_compact(mut buf, pos)
		if buf.len > req_cap {
			tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp) // the pending request is too large
			return
		}
		if drained {
			break
		}
		if buf.len == buf.cap || (filled && buf.cap < tls_record_bytes) {
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
			break // the burst is drained
		}
		if n <= 0 {
			// Closed or fatal. A want_write lands here too: a TLS 1.3 server's
			// mbedtls_ssl_read writes only an alert ahead of a fatal error (no
			// renegotiation, no post-handshake message it accepts). Answers the
			// peer already has coming are still sent, best effort (a client may
			// pipeline and then half-close).
			tls_write_all_best_effort(mut conn, fd, mut resp)
			tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp)
			return
		}
		unsafe {
			buf.len += n
		}
		filled = n == spare
		// kTLS: a recv that came back short emptied the socket, and a record
		// arriving later raises a new edge, so skip the EAGAIN recv. (Userspace
		// mbedTLS asks for exact lengths, so vtls_read applies this rule to its
		// own read-ahead instead.)
		if conn.ktls && !filled {
			drained = true
		}
		// First plaintext byte of a request: the idle phase is over. If the
		// request stays incomplete, its read deadline is armed below.
		conn.idle_deadline = 0
	}

	// 4) The burst is drained: send what it answered. What is left in buf is
	// at most one partial request.
	if resp.len > 0 {
		match tls_flush(mut conn, epoll_fd, fd, limits.write_timeout_ms, mut resp) {
			.sent {
				unsafe {
					resp.len = 0
				}
				sent = true
			}
			.parked {
				conn.read_buf = buf // a partial waits for the resume (see above)
				return
			}
			.failed {
				tls_drop(epoll_fd, fd, active_conns, mut sessions, mut conn, buf, resp)
				return
			}
		}
	}
	conn.read_buf = buf
	conn.resp_buf = resp // back to the per-conn pool (len 0)
	if buf.len > 0 {
		// A partial request: its own read deadline, armed once and never
		// refreshed by progress (for the first request, the one armed at accept
		// is still running). A pipelined partial never inherits the clock of the
		// request before it: completing that one cleared it.
		if limits.read_timeout_ms > 0 && conn.read_deadline == 0 {
			conn.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
		}
	} else if sent {
		tls_arm_idle(mut conn, idle_ms) // every response is out and nothing is buffered
	}
	tls_set_out(mut conn, epoll_fd, fd, false) // keep-alive; not waiting on writability
}

// tls_write_chunk writes one chunk over the session — kTLS plaintext send or
// userspace mbedtls — returning the byte count or the tls.want/want_write/
// closed sentinels, so every write loop branches uniformly. On kTLS, while a
// file body is pending the chunk goes out with MSG_MORE: the record holding
// the headers stays open and the file's first bytes join it, instead of the
// headers leaving as a small record of their own.
@[inline]
fn tls_write_chunk(mut conn TlsConn, fd int, ptr &u8, len int) int {
	return if conn.ktls {
		ktls_send(fd, ptr, len, conn.file_remaining > 0)
	} else {
		conn.sess.write_from(ptr, len)
	}
}

// tls_send_best_effort synchronously writes as much of `buf` as the TLS
// session will take right now, and reports whether all of it went out. Only
// for a connection about to close, where a partial send is acceptable.
fn tls_send_best_effort(mut conn TlsConn, fd int, buf []u8) bool {
	mut off := 0
	for off < buf.len {
		n := tls_write_chunk(mut conn, fd, unsafe { &u8(buf.data) + off }, buf.len - off)
		if n <= 0 {
			return false
		}
		off += n
	}
	return true
}

// tls_write_all_best_effort is the one write before a close: as much of
// `resp`, then of the file a .close step queued behind it (kTLS, sendfile(2)
// as in tls_flush), as the session will take right now. What it cannot send
// now is dropped with the connection. A socket that refuses sendfile(2) gets
// the rest of the file as bytes in `resp` (tls_file_to_bytes). A file body
// cut short ends with the fatal alert: the batch ahead of it went out with
// MSG_MORE, and the alert pushes the record that left open, which the close
// would discard with the answers in it (see tls_drain_file).
fn tls_write_all_best_effort(mut conn TlsConn, fd int, mut resp []u8) {
	with_file := conn.file_remaining > 0
	for tls_send_best_effort(mut conn, fd, resp) {
		if conn.file_remaining <= 0 {
			return // all of it went out
		}
		r := tls_drain_file(fd, mut conn)
		if r == 1 || r == -1 {
			return // sent, or failed after tls_drain_file's alert
		}
		if r == 0 {
			break // the socket is full
		}
		// -2: `resp` is all sent, so it takes the rest of the file as bytes.
		unsafe {
			resp.len = 0
		}
		if !tls_file_to_bytes(mut conn, fd, mut resp) {
			return // short: sent what was read, then the alert
		}
	}
	if with_file {
		conn.sess.ktls_abort()
	}
}

// handle_writable_fd_tls resumes work blocked on writability: a handshake that
// wanted to write, or a parked response. An EPOLLOUT on an fd with no session
// is the connection's birth (accept registered it with EPOLLOUT, see
// accept_events): create the session, arm the accept-time deadline and switch
// the fd back to EPOLLIN. The caller still runs the EPOLLIN half of the same
// event, which starts the handshake if the ClientHello came with the connect.
// Returns true when reads must resume (the caller runs handle_readable_fd_tls
// even without EPOLLIN): a parked response just drained, or the handshake
// just completed. Bytes that arrived meanwhile raised their edge already (and
// were left unread), so no new one is coming for them.
@[direct_array_access; manualfree]
fn handle_writable_fd_tls(epoll_fd int, fd int, limits core.Limits, idle_ms int, active_conns &core.Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) bool {
	// One lookup, nil on a miss. Not `sessions[fd] or {}`: on a miss that
	// allocates its "key does not exist" error, once per connection — a leak
	// under -gc none, and every connection's birth is a miss.
	mut conn := unsafe { sessions[fd] }
	if conn == unsafe { nil } {
		mut nc := tls_open_conn(cfg, epoll_fd, fd, limits, idle_ms, active_conns, mut sessions) or {
			return false
		}
		tls_set_out(mut nc, epoll_fd, fd, false) // birth edge consumed — EPOLLIN only
		return false
	}

	if !conn.established {
		// Handshake was waiting to write; advance it. If still not done, the step
		// re-arms the right readiness; if done, a request may already be waiting.
		return tls_handshake_step(mut conn, epoll_fd, fd, active_conns, mut sessions)
	}

	if !conn.parked() {
		tls_set_out(mut conn, epoll_fd, fd, false) // spurious — stop watching writability
		return false
	}

	// Finish the parked bytes, then the file body behind them (kTLS). A socket
	// that refuses sendfile(2) gets the rest of the file as bytes in
	// write_buf, sent by the next pass.
	for {
		for conn.write_off < conn.write_buf.len {
			n := tls_write_chunk(mut conn, fd, unsafe { &u8(conn.write_buf.data) + conn.write_off },
				conn.write_buf.len - conn.write_off)
			if n > 0 {
				conn.write_off += n
				continue
			}
			if n == tls.want || n == tls.want_write {
				return false
			}
			close_tls(epoll_fd, fd, active_conns, mut sessions) // fatal
			return false
		}
		if conn.file_remaining <= 0 {
			break
		}
		r := tls_drain_file(fd, mut conn)
		if r == 1 {
			break
		}
		if r == 0 {
			return false // still parked mid-file
		}
		if r == -2 {
			// write_buf is all sent: it takes the rest of the file.
			unsafe {
				conn.write_buf.len = 0
			}
			conn.write_off = 0
			if tls_file_to_bytes(mut conn, fd, mut conn.write_buf) {
				continue
			}
		}
		close_tls(epoll_fd, fd, active_conns, mut sessions) // fatal, or the file shrank
		return false
	}
	// Fully flushed — keep-alive; drop the parked state and stop watching
	// writability. write_buf is the batch's resp buffer (tls_park_write), and
	// the pool stays empty while it is parked: it goes back to the pool for
	// the next request instead of being freed and allocated again.
	if conn.resp_buf.cap == 0 {
		unsafe {
			conn.write_buf.len = 0
		}
		conn.resp_buf = conn.write_buf
	} else {
		unsafe { conn.write_buf.free() }
	}
	conn.write_buf = []u8{}
	conn.write_off = 0
	conn.write_deadline = 0
	tls_arm_idle(mut conn, idle_ms)
	tls_set_out(mut conn, epoll_fd, fd, false)
	return true
}

// tls_flush sends the whole response batch, then the file body queued behind
// it (kTLS, tls_drain_file), or parks the unsent remainder on EPOLLOUT
// (write_buf then owns `resp`). It never closes: on .failed the caller does,
// and `resp` is still its own.
@[manualfree]
fn tls_flush(mut conn TlsConn, epoll_fd int, fd int, write_timeout_ms int, mut resp []u8) TlsFlush {
	mut sent := 0
	for {
		for sent < resp.len {
			n := tls_write_chunk(mut conn, fd, unsafe { &u8(resp.data) + sent }, resp.len - sent)
			if n > 0 {
				sent += n
				continue
			}
			if n == tls.want || n == tls.want_write {
				tls_park_write(mut conn, resp, sent, write_timeout_ms) // ownership → parked
				tls_set_out(mut conn, epoll_fd, fd, true)
				return .parked
			}
			return .failed
		}
		if conn.file_remaining <= 0 {
			return .sent
		}
		match tls_drain_file(fd, mut conn) {
			1 {
				return .sent
			}
			0 {
				// The socket filled mid-file. write_buf takes `resp`, all of it
				// sent, so a parked file follows the parked-response rules
				// unchanged: ownership, the write deadline, freed on close.
				tls_park_write(mut conn, resp, resp.len, write_timeout_ms)
				tls_set_out(mut conn, epoll_fd, fd, true)
				return .parked
			}
			-2 {
				// The socket refuses sendfile(2). `resp` is all sent, so it takes
				// the rest of the file as bytes, sent by the next pass without
				// MSG_MORE, which also closes the record the batch left open.
				unsafe {
					resp.len = 0
				}
				sent = 0
				if !tls_file_to_bytes(mut conn, fd, mut resp) {
					return .failed
				}
			}
			else {
				return .failed
			}
		}
	}
	return .sent
}

// tls_drain_file streams the connection's file body into the kTLS socket with
// sendfile(2), advancing file_off/file_remaining (drain_file's twin). Returns:
//    1  fully sent (file_remaining == 0, file_fd reset)
//    0  EAGAIN: the rest goes on the next writable edge
//   -2  the socket refuses sendfile(2) (EINVAL, EOPNOTSUPP, ENOSYS: a kernel
//       that cannot splice into kTLS): the caller sends the rest as bytes
//   -1  a hard error, or EOF: the file shrank under a Content-Length already
//       on the wire, so the caller must close. The fatal alert goes first
//       (ktls_abort): it pushes the record the MSG_MORE batch left open, so
//       the answers ahead of this file, and its head, are not lost with it
fn tls_drain_file(fd int, mut conn TlsConn) int {
	for conn.file_remaining > 0 {
		want := if conn.file_remaining > sm_sendfile_chunk {
			usize(sm_sendfile_chunk)
		} else {
			usize(conn.file_remaining)
		}
		sent := C.sendfile(fd, conn.file_fd, &conn.file_off, want)
		if sent > 0 {
			conn.file_remaining -= i64(sent)
			continue
		}
		if sent < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				return 0
			}
			if C.errno == C.EINVAL || C.errno == C.EOPNOTSUPP || C.errno == C.ENOSYS {
				return -2
			}
		}
		conn.sess.ktls_abort()
		return -1
	}
	conn.file_fd = -1 // borrowed — never closed here
	return 1
}

// tls_file_to_bytes reads the rest of the connection's file body into the
// empty `buf` (core.append_file_region) and clears it, for a kTLS socket that
// refused sendfile(2); no_sendfile then closes the hand-off for this
// connection, so its later files come from the handler as bytes. Returns
// false on a short read (the file shrank under a Content-Length already on
// the wire): the bytes it did read are sent first, best effort, as
// sendfile(2) would have sent them before its EOF, then the fatal alert that
// pushes the record left open (see tls_drain_file); the caller closes.
fn tls_file_to_bytes(mut conn TlsConn, fd int, mut buf []u8) bool {
	want := conn.file_remaining
	got := core.append_file_region(mut buf, conn.file_fd, conn.file_off, want)
	conn.file_fd = -1
	conn.file_remaining = 0
	conn.no_sendfile = true
	if got != want {
		tls_send_best_effort(mut conn, fd, buf)
		conn.sess.ktls_abort()
		return false
	}
	return true
}

// tls_drop hands back the buffers handle_readable_fd_tls moved out of conn,
// then closes the connection: close_tls frees them with the session.
@[inline]
fn tls_drop(epoll_fd int, fd int, active_conns &core.Counter, mut sessions map[int]&TlsConn, mut conn TlsConn, buf []u8, resp []u8) {
	conn.read_buf = buf
	conn.resp_buf = resp
	close_tls(epoll_fd, fd, active_conns, mut sessions)
}

// tls_compact drops the first `pos` bytes of `buf` (the requests just
// answered), moving what is left (a partial, or requests not answered yet)
// to the front.
@[direct_array_access; inline]
fn tls_compact(mut buf []u8, pos int) {
	if pos <= 0 {
		return
	}
	left := buf.len - pos
	if left > 0 {
		unsafe { C.memmove(buf.data, &u8(buf.data) + pos, usize(left)) }
	}
	unsafe {
		buf.len = left
	}
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
			// (len 0, cap > 0), so free on capacity, not length. So may
			// write_buf: a file parked behind an empty batch leaves it at len 0.
			if c.read_buf.cap > 0 {
				c.read_buf.free()
			}
			if c.resp_buf.cap > 0 {
				c.resp_buf.free()
			}
			if c.write_buf.cap > 0 {
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
