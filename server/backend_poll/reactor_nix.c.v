module backend_poll

// Pure-POSIX level-triggered poll(2) reactor — the portability floor for the
// OSes that have nothing better (QNX before ionotify, VxWorks, any Unix), per
// issue #122 step 4. On Linux it is compiled only under `-d vanilla_poll`
// (the import lives in server/run_poll_d_vanilla_poll.c.v), so the whole
// vtest behaviour suite can exercise this reactor in CI at zero cost to
// normal builds.
//
// DELIBERATELY NOT A DEFAULT: poll(2) is O(nfds) per wake, and every worker
// polls the ONE shared listener (no SO_REUSEPORT here — the floor cannot
// assume it), so accept wake-order across workers is kernel-defined (herd
// skew). Same request semantics as the epoll backend — pipelining, split
// framing, limits (400/413/431), Expect: 100-continue, streamed large-body
// drain, half-close, read/write timeouts, graceful shutdown drain — minus
// the extras: no watch reactor (`.suspend` drops the connection, like
// Windows/IOCP), no sendfile/queue_buf hand-offs (never enabled, so
// `core.queue_file` returns false and handlers append bytes instead), no TLS.
import core
import socket
import poll
import time
import sync.stdatomic
import http1_1.request_parser
import http1_1.response

#include <errno.h>
#include <string.h>
#include <sys/socket.h>

fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.memmove(__dest voidptr, __src voidptr, __n usize) voidptr

const pl_max_request_bytes = 8 * 1024 * 1024
const pl_max_pending_write = 8 * 1024 * 1024
const pl_stream_body_above = 1024 * 1024
const pl_read_buf_cap = 8 * 1024
const pl_write_buf_cap = 16 * 1024

// MSG_NOSIGNAL doesn't exist on the BSDs/macOS (SIGPIPE is suppressed per
// socket via SO_NOSIGPIPE in socket.accept_client instead).
const msg_nosignal = $if linux { C.MSG_NOSIGNAL } $else { 0 }

// Per-connection state — the poll twin of the epoll backend's ConnState,
// minus the watch/sendfile fields. Level-triggered poll derives interest from
// this state each iteration (write pending ⇒ POLLOUT), so there is no
// explicit park/re-arm step.
struct PollConn {
mut:
	fd                int = -1
	read_buf          []u8
	write_buf         []u8
	write_off         int
	read_deadline     u64 // monotonic ns; >0 while a request is mid-read
	write_deadline    u64 // monotonic ns; >0 while a batch is pending
	body_drain        i64 // >0 while a streamed large body is being discarded
	close_after_flush bool
	sent_100          bool
}

struct WorkerState {
mut:
	conns      []&PollConn        // live connections (dense — index is NOT the fd)
	free_conns []&PollConn        // retired states, buffers kept (same pooling as epoll)
	pfds       []C.vanilla_pollfd // rebuilt each iteration: [listener?] + conns
	parked     int                // connections with an armed deadline (gates the sweep)
	accepting  bool = true
}

fn (mut w WorkerState) conn_for(fd int) &PollConn {
	mut cs := if w.free_conns.len > 0 {
		w.free_conns.pop()
	} else {
		&PollConn{
			read_buf:  []u8{len: 0, cap: pl_read_buf_cap}
			write_buf: []u8{len: 0, cap: pl_write_buf_cap}
		}
	}
	cs.fd = fd
	w.conns << cs
	return cs
}

// close_conn_at closes w.conns[i] and recycles its state (swap-remove keeps
// the table dense; iteration order is per-worker private, so it may change).
fn (mut w WorkerState) close_conn_at(i int, active_conns &core.Counter) {
	mut cs := w.conns[i]
	if cs.read_deadline != 0 {
		w.parked--
	}
	if cs.write_deadline != 0 {
		w.parked--
	}
	socket.close_socket(cs.fd)
	stdatomic.add_i64(&active_conns.n, -1)
	unsafe {
		cs.read_buf.len = 0
		cs.write_buf.len = 0
	}
	cs.fd = -1
	cs.write_off = 0
	cs.read_deadline = 0
	cs.write_deadline = 0
	cs.body_drain = 0
	cs.close_after_flush = false
	cs.sent_100 = false
	w.conns.delete(i)
	w.free_conns << cs
}

// buf_view — the same non-owning window as the epoll backend's (see the
// rationale in server/backend_epoll/conn_state_linux.c.v).
@[inline]
fn buf_view(buf []u8, start int, length int) []u8 {
	mut v := unsafe { buf }
	unsafe {
		v.data = &u8(buf.data) + start
		v.len = length
		v.cap = length
		v.flags.clear(.managed)
	}
	return v
}

@[direct_array_access; inline]
fn compact_read_buf(mut cs PollConn, pos int) {
	if pos <= 0 {
		return
	}
	leftover := cs.read_buf.len - pos
	if leftover > 0 {
		unsafe { C.memmove(cs.read_buf.data, &u8(cs.read_buf.data) + pos, usize(leftover)) }
	}
	unsafe {
		cs.read_buf.len = leftover
	}
}

// flush_pending sends buffered response bytes. Returns:
//   1  fully drained
//   0  partial — POLLOUT will resume it (write deadline armed once)
//  -1  hard error — caller must close
fn flush_pending(mut w WorkerState, mut cs PollConn, limits core.Limits) int {
	for cs.write_off < cs.write_buf.len {
		n := C.send(cs.fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), msg_nosignal)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			if limits.write_timeout_ms > 0 && cs.write_deadline == 0 {
				cs.write_deadline = time.sys_mono_now() + u64(limits.write_timeout_ms) * 1_000_000
				w.parked++
			}
			return 0
		}
		return -1
	}
	cs.write_buf.clear()
	cs.write_off = 0
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		w.parked--
	}
	return 1
}

// update_read_deadline — armed once while a request is mid-read (partial
// bytes buffered or a body mid-drain), cleared when idle. Same total-time
// semantics as every other backend.
@[inline]
fn update_read_deadline(limits core.Limits, mut w WorkerState, mut cs PollConn) {
	if cs.read_buf.len > 0 || cs.body_drain > 0 {
		if limits.read_timeout_ms > 0 && cs.read_deadline == 0 {
			cs.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			w.parked++
		}
	} else if cs.read_deadline != 0 {
		cs.read_deadline = 0
		w.parked--
	}
}

// drain_requests answers every complete buffered request into write_buf.
// Mirrors the epoll drain minus the watch runtime: `.suspend` cannot park
// (no reactor on the portability floor), so it drops the connection — the
// Windows/IOCP precedent. Returns false if the connection must close NOW
// (framing error / .close / flood); the caller closes it after flushing.
@[direct_array_access]
fn drain_requests(h core.Handler, mut w WorkerState, mut cs PollConn, limits core.Limits, state voidptr) bool {
	mut pos := 0
	mut event_loop := core.EventLoop{
		client_fd: cs.fd
		register:  core.reject_register
	}
	mut alive := true
	for pos < cs.read_buf.len {
		total := request_parser.frame_request_length_lim_idx(buf_view(cs.read_buf, pos,
			cs.read_buf.len - pos), limits.max_header_bytes, limits.max_body_bytes)
		if total == -1 {
			break // incomplete — wait for more bytes
		}
		if total < -1 {
			match -total {
				413 { cs.write_buf << response.status_413_response }
				431 { cs.write_buf << response.status_431_response }
				else { cs.write_buf << response.tiny_bad_request_response }
			}

			alive = false
			pos = cs.read_buf.len // closing; discard the rest of the burst
			break
		}
		req := buf_view(cs.read_buf, pos, total)
		step := h(req, mut cs.write_buf, cs.fd, state, mut event_loop)
		pos += total
		match step {
			.done {}
			.suspend {
				eprintln('[poll] handler returned .suspend but the poll backend has no watch reactor; dropping the connection')
				alive = false
			}
			.close {
				alive = false
			}
		}

		if !alive {
			break
		}
		if cs.write_buf.len - cs.write_off > pl_max_pending_write {
			alive = false // peer pipelines without reading responses
			break
		}
	}
	compact_read_buf(mut cs, pos)
	return alive
}

// start_body_drain — the streamed large-body path (drain-then-respond),
// mirroring the epoll backend: answer from the complete HEAD, hold the
// response, discard the body as it arrives. Returns 1 drained/started,
// 2 must-close, 0 head incomplete (grow + recv more).
fn start_body_drain(h core.Handler, mut cs PollConn, limits core.Limits, state voidptr, total int) int {
	head_len := request_parser.frame_head_len(cs.read_buf)
	if head_len <= 0 || head_len > cs.read_buf.len {
		return 0
	}
	content_length := total - head_len
	if limits.max_body_bytes > 0 && content_length > limits.max_body_bytes {
		cs.write_buf << response.status_413_response
		return 2
	}
	head := buf_view(cs.read_buf, 0, head_len)
	mut event_loop := core.EventLoop{
		client_fd: cs.fd
		register:  core.reject_register
	}
	if h(head, mut cs.write_buf, cs.fd, state, mut event_loop) != .done {
		cs.write_buf << response.tiny_bad_request_response
		return 2
	}
	body_in_buf := cs.read_buf.len - head_len
	cs.body_drain = i64(content_length) - i64(body_in_buf)
	if cs.body_drain < 0 {
		cs.body_drain = 0
	}
	unsafe {
		cs.read_buf.len = 0
	}
	return 1
}

// serve_readable drains the socket, answers complete requests (pipelining),
// and leaves any response bytes pending (the caller flushes). Returns false
// if the connection was closed.
@[direct_array_access]
fn serve_readable(h core.Handler, mut w WorkerState, i int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, state voidptr) bool {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}
	mut cs := w.conns[i]
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		pl_max_request_bytes
	}
	mut must_close := false
	for {
		// Streamed large body: consume + discard (head already answered).
		if cs.body_drain > 0 {
			want := if cs.body_drain < i64(cs.read_buf.cap) {
				int(cs.body_drain)
			} else {
				cs.read_buf.cap
			}
			dn := C.recv(cs.fd, cs.read_buf.data, usize(want), 0)
			if dn < 0 {
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
					break
				}
				w.close_conn_at(i, active_conns)
				return false
			}
			if dn == 0 {
				w.close_conn_at(i, active_conns)
				return false
			}
			cs.body_drain -= dn
			continue
		}
		if cs.read_buf.len == cs.read_buf.cap {
			target := request_parser.frame_expected_total(cs.read_buf)
			if target > pl_stream_body_above && target <= req_cap {
				match start_body_drain(h, mut cs, limits, state, target) {
					1 { continue } // draining started; keep consuming the body
					2 { must_close = true }
					else {} // head incomplete — fall through to grow
				}

				if must_close {
					break
				}
			}
			if target > cs.read_buf.cap && target <= req_cap {
				unsafe { cs.read_buf.grow_cap(target - cs.read_buf.cap) }
			} else {
				unsafe { cs.read_buf.grow_cap(cs.read_buf.cap) }
			}
		}
		spare := cs.read_buf.cap - cs.read_buf.len
		n := C.recv(cs.fd, unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }, usize(spare), 0)
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break
			}
			w.close_conn_at(i, active_conns)
			return false
		}
		if n == 0 {
			// Half-close (EOF). A pending response is still owed on the open write
			// half (RFC 9112 §9.6); with nothing pending, close now.
			if cs.body_drain == 0 && cs.write_buf.len > cs.write_off {
				cs.close_after_flush = true
				break
			}
			w.close_conn_at(i, active_conns)
			return false
		}
		unsafe {
			cs.read_buf.len += n
		}
		if !drain_requests(h, mut w, mut cs, limits, state) {
			must_close = true
			break
		}
		if cs.read_buf.len > req_cap {
			cs.write_buf << response.status_413_response
			must_close = true
			break
		}
		// Expect: 100-continue — prompt exactly once per mid-read request.
		if cs.read_buf.len == 0 {
			if cs.sent_100 {
				cs.sent_100 = false
			}
		} else if !cs.sent_100 && cs.body_drain == 0 {
			head_len := request_parser.frame_head_len(cs.read_buf)
			if head_len > 0 && request_parser.head_expects_100_continue(cs.read_buf, head_len) {
				cs.write_buf << response.status_100_continue_response
				cs.sent_100 = true
			}
		}
	}
	update_read_deadline(limits, mut w, mut cs)
	// End-of-burst flush — held while a streamed body is still draining.
	if cs.body_drain == 0 && cs.write_buf.len > cs.write_off {
		match flush_pending(mut w, mut cs, limits) {
			-1 {
				w.close_conn_at(i, active_conns)
				return false
			}
			0 {
				// Parked on POLLOUT. A must-close (framing error / .close) or
				// half-closed connection finishes closing once the batch drains.
				if must_close {
					cs.close_after_flush = true
				}
				return true
			}
			else {}
		}
	}
	if must_close || cs.close_after_flush {
		w.close_conn_at(i, active_conns)
		return false
	}
	return true
}

// handle_writable resumes a parked batch. Returns false if the connection
// was closed.
@[direct_array_access]
fn handle_writable(mut w WorkerState, i int, limits core.Limits, active_conns &core.Counter) bool {
	mut cs := w.conns[i]
	if cs.body_drain > 0 {
		// Drain-then-respond gate: never emit a held head-response mid-body.
		return true
	}
	match flush_pending(mut w, mut cs, limits) {
		-1 {
			w.close_conn_at(i, active_conns)
			return false
		}
		0 {
			return true // still parked
		}
		else {}
	}

	if cs.close_after_flush {
		w.close_conn_at(i, active_conns)
		return false
	}
	return true
}

@[direct_array_access]
fn sweep_timeouts(mut w WorkerState, active_conns &core.Counter) {
	now := time.sys_mono_now()
	mut i := 0
	for i < w.conns.len {
		cs := w.conns[i]
		if cs.read_deadline > 0 && now > cs.read_deadline {
			response.send_status_408_response(cs.fd)
			w.close_conn_at(i, active_conns)
			continue // swap-remove: re-check index i
		}
		if cs.write_deadline > 0 && now > cs.write_deadline {
			w.close_conn_at(i, active_conns)
			continue
		}
		i++
	}
}

// poll_worker is one shared-nothing worker loop: every worker polls the ONE
// shared listener plus its own accepted connections, level-triggered.
@[direct_array_access]
fn poll_worker(listener int, handler core.Handler, make_state fn () voidptr, limits core.Limits, counter &core.Counter, active_conns &core.Counter) {
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	mut w := WorkerState{}
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	for {
		// Rebuild the pollfd set from connection state — O(nfds), the floor's
		// documented cost (poll(2) itself is O(nfds) anyway). Interest derives
		// from state: write pending ⇒ POLLOUT, everything ⇒ POLLIN.
		w.pfds.clear()
		if w.accepting {
			w.pfds << C.vanilla_pollfd{
				fd:     listener
				events: poll.pollin
			}
		}
		for cs in w.conns {
			mut ev := poll.pollin
			if cs.write_off < cs.write_buf.len && cs.body_drain == 0 {
				ev |= poll.pollout
			}
			w.pfds << C.vanilla_pollfd{
				fd:     cs.fd
				events: ev
			}
		}
		if w.pfds.len == 0 {
			// Listener gone (shutdown) and no live connections: this worker is
			// done — exiting beats spinning on an empty poll set.
			return
		}
		wait_ms := if sweep_on && w.parked > 0 { 250 } else { -1 }
		num := poll.wait(&w.pfds[0], u64(w.pfds.len), wait_ms)
		if num < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'poll')
			return
		}
		mut idx := 0
		if w.accepting {
			rl := w.pfds[0].revents
			if rl & (poll.pollnval | poll.pollhup | poll.pollerr) != 0 {
				// Server.shutdown() closed the shared listener — poll flags the
				// dead fd on EVERY worker (the portability floor's wake: no CQE
				// or edge semantics needed). Stop accepting; drain what's live.
				w.accepting = false
			} else if rl & poll.pollin != 0 {
				// EAGAIN-tolerant accept burst: every worker may wake for the
				// same connection (shared listener, herd) — whoever accepts
				// first wins, the rest see EAGAIN and move on.
				for {
					client_fd := socket.accept_client(listener)
					if client_fd < 0 {
						break // EAGAIN/EWOULDBLOCK or a racing worker won
					}
					if limits.max_connections > 0
						&& stdatomic.load_i64(&active_conns.n) >= i64(limits.max_connections) {
						socket.close_socket(client_fd)
						continue
					}
					socket.set_tcp_nodelay(client_fd)
					w.conn_for(client_fd)
					stdatomic.add_i64(&active_conns.n, 1)
				}
			}
			idx = 1
		}
		// Serve connections. close_conn_at swap-removes from w.conns, so walk
		// the SNAPSHOT in w.pfds and re-locate each fd (O(n) per event — the
		// floor trades this for zero bookkeeping; conns is dense and small).
		for pi in idx .. w.pfds.len {
			rev := w.pfds[pi].revents
			if rev == 0 {
				continue
			}
			fd := w.pfds[pi].fd
			mut ci := -1
			for j, cs in w.conns {
				if cs.fd == fd {
					ci = j
					break
				}
			}
			if ci < 0 {
				continue // closed earlier in this batch
			}
			if rev & (poll.pollnval | poll.pollerr) != 0 {
				w.close_conn_at(ci, active_conns)
				continue
			}
			if rev & poll.pollout != 0 {
				if !handle_writable(mut w, ci, limits, active_conns) {
					continue
				}
			}
			// POLLHUP with readable data still pending must be drained (the
			// half-close path in serve_readable handles the EOF); a bare HUP
			// closes there via recv == 0.
			if rev & (poll.pollin | poll.pollhup) != 0 {
				serve_readable(handler, mut w, ci, limits, counter, active_conns, state)
			}
		}
		if sweep_on && w.parked > 0 {
			sweep_timeouts(mut w, active_conns)
		}
	}
}

// run_poll_backend spawns the workers (all sharing the one listener) and
// fires after_server_start, mirroring the other backends' facades.
pub fn run_poll_backend(socket_fd int, handler core.Handler, make_state fn () voidptr, after_server_start core.AfterStartFn, limits core.Limits, inflight []&core.Counter, active_conns &core.Counter, mut threads []thread) {
	if socket_fd < 0 {
		eprintln('[poll] invalid listener fd')
		return
	}
	for i in 0 .. threads.len {
		threads[i] = spawn poll_worker(socket_fd, handler, make_state, limits, inflight[i],
			active_conns)
	}
	println('listening (poll backend, portability floor — O(nfds), not a throughput default)')
	if after_server_start != unsafe { nil } {
		after_server_start()
	}
	for {
		time.sleep(time.second)
	}
}
