// Windows-specific HTTP server implementation using I/O completion ports —
// the counterpart of backend_epoll (Linux) and async_darwin.c.v (macOS).
//
// Same shared-nothing thread-per-core model as the epoll backend, adapted to
// COMPLETION semantics (IOCP tells you an operation finished, not that a fd is
// ready):
//   • one IOCP port per worker thread — a connection is handed to one worker
//     at accept and never leaves it, so per-connection state needs no locks;
//   • persistent per-connection read/write buffers, pooled on a per-worker
//     free list (zero allocation per request, buffers reused across
//     connections);
//   • exactly ONE overlapped operation in flight per connection (recv OR
//     send, never both), so the buffers are never reallocated or appended to
//     while the kernel holds a pointer into them;
//   • HTTP/1.1 keep-alive + pipelining — every complete request buffered by a
//     recv completion is answered into the write buffer, and the whole batch
//     goes out in a single WSASend;
//   • large-body streaming drain — a body past win_stream_body_above is
//     answered from its head and then consumed off the socket in O(buffer)
//     memory, with the response HELD until the drain completes
//     (drain-then-respond, same ordering contract as the epoll backend);
//   • limits: max_connections (refused at accept), max_header/max_body (parser
//     sentinels → 431/413), max_request_bytes (413), read/write timeouts
//     (deadline sweep driven by the GetQueuedCompletionStatus timeout).
//
// The handler contract is core.Handler, unchanged. This worker has no watch
// reactor yet (IOCP is completion-based; watching arbitrary readiness like
// epoll needs an AFD-style poll bridge), so `.suspend` DROPS the connection —
// see core.reject_register.
//
// Known headroom: completions dequeue ONE per GetQueuedCompletionStatus call.
// GetQueuedCompletionStatusEx would batch them (the epoll worker's amortized
// epoll_wait equivalent), but tcc's kernel32 export table lacks it
// (vlang/v#27792) — switch to batch dequeue once that lands, or load it via
// GetProcAddress if profiles demand it sooner.
module http_server

import iocp
import socket
import time
import sync.stdatomic
import http_server.core
import http1_1.request_parser
import http1_1.response

// Backend selection
pub enum IOBackend {
	iocp = 0 // Windows only
}

#include <winsock2.h>
#include <windows.h>

// C.WSAGetLastError / C.memmove come from builtin's program-wide decls.

const win_read_buf_cap = 8 * 1024
const win_write_buf_cap = 16 * 1024
const win_max_request_bytes = 8 * 1024 * 1024
// Write-side cap: close a connection whose peer pipelines requests but never
// drains responses (otherwise write_buf would grow without bound).
const win_max_pending_write = 8 * 1024 * 1024
// A request whose framed size exceeds this is STREAMED, not buffered: the head
// is answered and the body is drained (recv'd into the fixed buffer and
// discarded) instead of growing read_buf into a multi-MB block.
const win_stream_body_above = 1024 * 1024
// Deadline sweep cadence while something is parked (mirrors the epoll worker's
// 250 ms timeout wait).
const win_sweep_interval_ns = u64(250) * 1_000_000

// Accept-loop errno values that mean the LISTENER itself is gone (closed by
// shutdown()/test teardown), as opposed to a per-connection failure.
const wsaeintr = 10004 // WSAEINTR: blocking accept canceled
const wsaeinval = 10022 // WSAEINVAL: socket no longer listening
const wsaenotsock = 10038 // WSAENOTSOCK: listener handle already closed

const op_read = 0
const op_write = 1

// WinOp is one overlapped operation's kernel-visible context. The OVERLAPPED
// must stay the FIRST field: a completion's lpOverlapped pointer IS the WinOp,
// recovered with a plain cast. Two of these are embedded in every WinConn
// (one recv, one send) so posting an operation allocates nothing.
struct WinOp {
mut:
	ov     C.OVERLAPPED
	wsabuf C.WSABUF
	kind   int // op_read | op_write
	conn   &WinConn = unsafe { nil }
}

// WinConn is allocated once per connection (on hand-off from the accept loop)
// and reused until the connection closes; retired states keep their buffers on
// the worker's free list — the same pooling as the epoll backend's ConnState.
@[heap]
struct WinConn {
mut:
	fd        int = -1
	read_op   WinOp
	write_op  WinOp
	read_buf  []u8 // persistent request buffer; len = bytes buffered
	write_buf []u8 // persistent response buffer; [write_off..len) pending
	write_off int
	// >0 while a large request body is being streamed (drained + discarded):
	// the head was already answered, this many body bytes are still to be
	// consumed off the socket; the response is HELD until it reaches 0.
	body_drain i64
	// flush whatever is pending, then close (handler .close, 4xx canned
	// responses, over-cap batches).
	close_after bool
	// closesocket() was issued while an overlapped op was still outstanding
	// (deadline sweep): the state must stay alive until the canceled
	// completion drains through the port, then it is recycled.
	closing        bool
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read
	write_deadline u64 // monotonic ns; >0 while a send is in flight
	slot           int // index in WinState.conns, for O(1) swap-remove
}

// WinState is the per-worker connection registry: a compact live list (the
// deadline sweep iterates it; dispatch never does — completions carry their
// WinOp pointer) plus the ConnState-style free list. One per worker, no lock.
struct WinState {
mut:
	conns      []&WinConn
	free_conns []&WinConn
	parked     int // conns with an armed deadline — gates the sweep entirely
	last_sweep u64
}

// win_buf_view returns a non-owning []u8 window over buf[start..start+length]
// without slice-marking bookkeeping — same rationale as the epoll backend's
// buf_view (see conn_state_linux.c.v): read_buf is manually managed, the view
// is consumed before the next recv can move it.
@[inline]
fn win_buf_view(buf []u8, start int, length int) []u8 {
	mut v := unsafe { buf }
	unsafe {
		v.data = &u8(buf.data) + start
		v.len = length
		v.cap = length
		v.flags.clear(.managed)
	}
	return v
}

// win_conn_for takes a retired WinConn from the pool (buffers retained) or
// allocates a fresh one, registers it in the live list and stamps the fd.
fn win_conn_for(mut st WinState, fd int) &WinConn {
	if st.free_conns.len > 0 {
		mut pooled := st.free_conns.pop()
		pooled.fd = fd
		pooled.slot = st.conns.len
		st.conns << pooled
		return pooled
	}
	mut cs := &WinConn{
		read_buf:  []u8{len: 0, cap: win_read_buf_cap}
		write_buf: []u8{len: 0, cap: win_write_buf_cap}
		fd:        fd
		slot:      st.conns.len
	}
	// Same no-scan gating as the epoll ConnState (see conn_state_linux.c.v).
	$if vanilla_noscan ? {
		unsafe {
			cs.read_buf.flags.set(.noscan_data)
			cs.write_buf.flags.set(.noscan_data)
		}
	}
	// The op→conn back-pointers never change for the life of the allocation.
	cs.read_op.kind = op_read
	cs.read_op.conn = cs
	cs.write_op.kind = op_write
	cs.write_op.conn = cs
	st.conns << cs
	return cs
}

// win_clear_deadlines disarms both deadlines, keeping the parked count exact.
@[inline]
fn win_clear_deadlines(mut st WinState, mut cs WinConn) {
	if cs.read_deadline != 0 {
		cs.read_deadline = 0
		st.parked--
	}
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
}

// win_recycle removes a connection from the live list (swap-remove via the
// slot index) and returns its state to the pool, buffers retained. The socket
// is already closed by the caller.
@[direct_array_access]
fn win_recycle(mut st WinState, mut cs WinConn) {
	mut last := st.conns[st.conns.len - 1]
	st.conns[cs.slot] = last
	last.slot = cs.slot
	st.conns.delete_last()
	unsafe {
		cs.read_buf.len = 0
		cs.write_buf.len = 0
	}
	cs.write_off = 0
	cs.body_drain = 0
	cs.close_after = false
	cs.closing = false
	cs.read_deadline = 0
	cs.write_deadline = 0
	cs.fd = -1
	st.free_conns << cs
}

// win_close_conn tears a connection down when NO overlapped op is outstanding
// (i.e. from within its own completion handler): close the socket, release the
// accounting, recycle the state.
fn win_close_conn(mut st WinState, mut cs WinConn, active_conns &core.Counter) {
	win_clear_deadlines(mut st, mut cs)
	socket.close_socket(cs.fd)
	stdatomic.add_i64(&active_conns.n, -1)
	win_recycle(mut st, mut cs)
}

// win_kill_conn tears a connection down while an overlapped op IS outstanding
// (the deadline sweep): closesocket cancels the op; the canceled completion
// drains through the port and the worker loop recycles the state there.
fn win_kill_conn(mut st WinState, mut cs WinConn, active_conns &core.Counter) {
	win_clear_deadlines(mut st, mut cs)
	cs.closing = true
	socket.close_socket(cs.fd)
	stdatomic.add_i64(&active_conns.n, -1)
}

// win_sweep_timeouts closes connections whose read/write deadline has passed.
// Runs only when something is parked and a timeout is configured.
@[direct_array_access]
fn win_sweep_timeouts(now u64, mut st WinState, active_conns &core.Counter) {
	for i in 0 .. st.conns.len {
		mut cs := st.conns[i]
		if cs.closing {
			continue
		}
		if cs.read_deadline > 0 && now > cs.read_deadline {
			// Courtesy 408, BEST-EFFORT: the socket is non-blocking, so against
			// a full send buffer (peer stopped reading) this fails with
			// WSAEWOULDBLOCK instead of stalling the worker — the same EAGAIN
			// drop the epoll backend's non-blocking sockets give it.
			response.send_status_408_response(cs.fd)
			win_kill_conn(mut st, mut cs, active_conns)
		} else if cs.write_deadline > 0 && now > cs.write_deadline {
			win_kill_conn(mut st, mut cs, active_conns)
		}
	}
}

// win_post_recv arms the connection's single recv op. During a body drain the
// whole buffer is a scratch window capped at the bytes still to discard (never
// over-reading into a pipelined next request); otherwise the spare capacity
// after the buffered partial. Callers guarantee spare > 0 (win_arm_recv grows
// the buffer first).
fn win_post_recv(mut cs WinConn) bool {
	mut dst := unsafe { &u8(cs.read_buf.data) }
	mut window := cs.read_buf.cap
	if cs.body_drain == 0 {
		dst = unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }
		window = cs.read_buf.cap - cs.read_buf.len
	} else if cs.body_drain < i64(window) {
		window = int(cs.body_drain)
	}
	cs.read_op.wsabuf.buf = unsafe { &char(dst) }
	cs.read_op.wsabuf.len = u32(window)
	unsafe { vmemset(&cs.read_op.ov, 0, int(sizeof(C.OVERLAPPED))) }
	return iocp.post_recv(cs.fd, &cs.read_op.wsabuf, &cs.read_op.ov)
}

// win_post_send arms the connection's single send op over the pending
// [write_off..len) window and starts the write deadline (once per batch).
fn win_post_send(mut st WinState, mut cs WinConn, limits core.Limits) bool {
	if limits.write_timeout_ms > 0 && cs.write_deadline == 0 {
		cs.write_deadline = time.sys_mono_now() + u64(limits.write_timeout_ms) * 1_000_000
		st.parked++
	}
	cs.write_op.wsabuf.buf = unsafe { &char(&u8(cs.write_buf.data) + cs.write_off) }
	cs.write_op.wsabuf.len = u32(cs.write_buf.len - cs.write_off)
	unsafe { vmemset(&cs.write_op.ov, 0, int(sizeof(C.OVERLAPPED))) }
	return iocp.post_send(cs.fd, &cs.write_op.wsabuf, &cs.write_op.ov)
}

// win_update_read_deadline arms the read deadline ONCE while a request is
// mid-read (partial bytes buffered, or a large body mid-drain) and clears it
// when the buffer is idle — the same once-per-request semantics as the other
// backends (read_timeout_ms bounds the TOTAL time to receive a request).
@[inline]
fn win_update_read_deadline(limits core.Limits, mut st WinState, mut cs WinConn) {
	if cs.read_buf.len > 0 || cs.body_drain > 0 {
		if limits.read_timeout_ms > 0 && cs.read_deadline == 0 {
			cs.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			st.parked++
		}
	} else if cs.read_deadline != 0 {
		cs.read_deadline = 0
		st.parked--
	}
}

// win_compact_read_buf drops the first `pos` consumed bytes, keeping the
// leftover (partial / not-yet-answered) request at the buffer front.
@[direct_array_access; inline]
fn win_compact_read_buf(mut cs WinConn, pos int) {
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

// win_drain_requests answers every complete request currently buffered,
// appending each response to write_buf (the whole batch flushes in ONE send).
// Mirrors the epoll drain_requests minus the watch runtime: `.suspend` cannot
// park here (no reactor), so it drops the connection.
@[direct_array_access]
fn win_drain_requests(h core.Handler, mut cs WinConn, limits core.Limits, state voidptr) {
	mut pos := 0
	// ONE EventLoop handle per burst; register is the shared reject stub, so a
	// handler that suspends anyway is detected below and dropped.
	mut event_loop := core.EventLoop{
		client_fd: cs.fd
		register:  core.reject_register
	}
	for pos < cs.read_buf.len {
		total := request_parser.frame_request_length_lim_idx(win_buf_view(cs.read_buf, pos,
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

			cs.close_after = true
			pos = cs.read_buf.len // connection is closing; discard the rest
			break
		}
		req := win_buf_view(cs.read_buf, pos, total)
		step := h(req, mut cs.write_buf, cs.fd, state, mut event_loop)
		pos += total
		match step {
			.done {}
			.suspend {
				eprintln('[iocp] handler returned .suspend but the Windows/IOCP worker has no watch reactor yet; dropping the connection')
				cs.close_after = true
			}
			.close {
				cs.close_after = true
			}
		}

		if cs.close_after {
			break
		}
		// Peer pipelines without reading responses: bail before the batch is unbounded.
		if cs.write_buf.len - cs.write_off > win_max_pending_write {
			cs.close_after = true
			break
		}
	}
	win_compact_read_buf(mut cs, pos)
}

// win_start_body_drain answers a large-body request from its HEAD alone, then
// puts the connection into streaming-drain mode for the body. Such handlers
// must answer by Content-Length and complete synchronously. Returns 1 =
// draining started, 2 = answer 400 and close, 0 = head not complete yet.
@[direct_array_access]
fn win_start_body_drain(h core.Handler, mut cs WinConn, limits core.Limits, state voidptr, total int) int {
	head_len := request_parser.frame_head_len(cs.read_buf)
	if head_len <= 0 || head_len > cs.read_buf.len {
		return 0 // head not complete in the buffer yet — grow/recv more
	}
	content_length := total - head_len
	head := win_buf_view(cs.read_buf, 0, head_len)
	mut event_loop := core.EventLoop{
		client_fd: cs.fd
		register:  core.reject_register
	}
	if h(head, mut cs.write_buf, cs.fd, state, mut event_loop) != .done {
		// suspend/close on a streamed-body request is unsupported — answer 400
		// and drop rather than leave a half-drained connection.
		cs.write_buf << response.tiny_bad_request_response
		cs.close_after = true
		unsafe {
			cs.read_buf.len = 0
		}
		return 2
	}
	// DRAIN-THEN-RESPOND: the head response is buffered in write_buf but NOT
	// flushed here; win_advance holds it until body_drain reaches 0 so a client
	// that writes the whole request before reading is never desynced.
	body_in_buf := cs.read_buf.len - head_len
	cs.body_drain = i64(content_length) - i64(body_in_buf)
	if cs.body_drain < 0 {
		cs.body_drain = 0
	}
	unsafe {
		cs.read_buf.len = 0 // head (and any buffered body bytes) consumed
	}
	return 1
}

// win_arm_recv posts the connection's next receive, first doing the
// full-buffer management the epoll serve_conn does at its loop top: a framed
// size past the streaming threshold starts a body drain; a bounded larger
// request grows the buffer toward its exact size; an unknown size doubles.
// Never posts a zero-length window.
fn win_arm_recv(h core.Handler, mut st WinState, mut cs WinConn, limits core.Limits, active_conns &core.Counter, state voidptr) {
	if cs.body_drain == 0 && cs.read_buf.len == cs.read_buf.cap {
		req_cap := if limits.max_request_bytes > 0 {
			limits.max_request_bytes
		} else {
			win_max_request_bytes
		}
		target := request_parser.frame_expected_total(cs.read_buf)
		if target > win_stream_body_above && target <= req_cap {
			match win_start_body_drain(h, mut cs, limits, state, target) {
				1 {
					if cs.body_drain == 0 {
						// the whole body was already buffered — release the response
						win_advance(h, mut st, mut cs, limits, active_conns, state)
						return
					}
					// fall through: post the first drain recv below
				}
				2 {
					win_advance(h, mut st, mut cs, limits, active_conns, state) // flush the 400, then close
					return
				}
				else {} // head not complete yet → grow below
			}
		}
		if cs.body_drain == 0 && cs.read_buf.len == cs.read_buf.cap {
			if target > cs.read_buf.cap && target <= req_cap {
				unsafe { cs.read_buf.grow_cap(target - cs.read_buf.cap) }
			} else {
				unsafe { cs.read_buf.grow_cap(cs.read_buf.cap) }
			}
		}
	}
	win_update_read_deadline(limits, mut st, mut cs)
	if !win_post_recv(mut cs) {
		win_close_conn(mut st, mut cs, active_conns)
	}
}

// win_advance decides the connection's next overlapped op after a burst of
// request handling: flush the batched responses (ONE send per burst; held
// while a body drain is in progress), close if the burst ended the
// connection, or arm the next receive.
fn win_advance(h core.Handler, mut st WinState, mut cs WinConn, limits core.Limits, active_conns &core.Counter, state voidptr) {
	if cs.body_drain == 0 && cs.write_buf.len > cs.write_off {
		if !win_post_send(mut st, mut cs, limits) {
			win_close_conn(mut st, mut cs, active_conns)
		}
		return
	}
	if cs.close_after {
		win_close_conn(mut st, mut cs, active_conns)
		return
	}
	win_arm_recv(h, mut st, mut cs, limits, active_conns, state)
}

// win_on_recv handles a completed receive: streaming-drain accounting, or
// append + answer every complete request + advance.
fn win_on_recv(h core.Handler, mut st WinState, mut cs WinConn, n int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, state voidptr) {
	if n <= 0 {
		// 0 bytes on a stream recv = orderly close by the peer.
		win_close_conn(mut st, mut cs, active_conns)
		return
	}
	if cs.body_drain > 0 {
		// Streaming-drain: the bytes landed in the scratch window and are
		// discarded (the window was capped, so this never goes negative).
		cs.body_drain -= i64(n)
		win_advance(h, mut st, mut cs, limits, active_conns, state)
		return
	}
	// In-flight window for the graceful-shutdown drain (per-worker counter,
	// own cache line — uncontended).
	stdatomic.add_i64(&counter.n, 1)
	unsafe {
		cs.read_buf.len += n
	}
	win_drain_requests(h, mut cs, limits, state)
	if !cs.close_after {
		req_cap := if limits.max_request_bytes > 0 {
			limits.max_request_bytes
		} else {
			win_max_request_bytes
		}
		if cs.read_buf.len > req_cap {
			cs.write_buf << response.status_413_response
			cs.close_after = true
		}
	}
	stdatomic.add_i64(&counter.n, -1)
	win_advance(h, mut st, mut cs, limits, active_conns, state)
}

// win_on_send handles a completed send: advance past the sent bytes, repost
// the remainder of a partial completion, or reset the batch and continue.
fn win_on_send(h core.Handler, mut st WinState, mut cs WinConn, n int, limits core.Limits, active_conns &core.Counter, state voidptr) {
	if n <= 0 {
		win_close_conn(mut st, mut cs, active_conns)
		return
	}
	cs.write_off += n
	if cs.write_off < cs.write_buf.len {
		// Partial completion (rare — an overlapped stream send normally
		// completes whole): repost the remainder.
		if !win_post_send(mut st, mut cs, limits) {
			win_close_conn(mut st, mut cs, active_conns)
		}
		return
	}
	cs.write_buf.clear() // len = 0, capacity kept for the next batch
	cs.write_off = 0
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	if cs.close_after {
		win_close_conn(mut st, mut cs, active_conns)
		return
	}
	win_arm_recv(h, mut st, mut cs, limits, active_conns, state)
}

// win_worker is one worker thread's event loop: it owns an IOCP port, the
// connection table and the per-worker handler state, and processes one
// completion per iteration. Control messages (lpOverlapped == nil) are the
// accept hand-off (key = fd) and the shutdown wake (key = 0).
fn win_worker(port voidptr, h core.Handler, make_state fn () voidptr, limits core.Limits, counter &core.Counter, active_conns &core.Counter) {
	// Per-worker state, built ON this worker thread (thread-local, no lock);
	// every handler call on this worker receives it as worker_state.
	mut state := voidptr(unsafe { nil })
	if make_state != unsafe { nil } {
		state = make_state()
	}
	mut st := WinState{
		conns: []&WinConn{cap: 64}
	}
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	for {
		mut bytes := u32(0)
		mut key := usize(0)
		mut ovp := &C.OVERLAPPED(unsafe { nil })
		// Block until a completion arrives; wake every 250 ms only while a
		// deadline is armed, so an idle worker burns zero CPU.
		timeout := if sweep_on && st.parked > 0 { u32(250) } else { iocp.infinite }
		ok := iocp.wait(port, &bytes, &key, &ovp, timeout)
		if ovp == unsafe { nil } {
			if ok && key == 0 {
				break // shutdown wake
			}
			if ok && key != 0 {
				// Accept hand-off: build the state and post the first recv.
				mut cs := win_conn_for(mut st, int(key))
				win_arm_recv(h, mut st, mut cs, limits, active_conns, state)
			}
			// !ok with no overlapped = the timeout tick; fall through to sweep.
		} else {
			mut op := unsafe { &WinOp(ovp) }
			mut cs := op.conn
			if cs.closing {
				// The op this conn was killed under (deadline sweep) has
				// drained; the socket is already closed and un-counted.
				win_recycle(mut st, mut cs)
			} else if !ok {
				// Failed completion: peer reset / aborted op.
				win_close_conn(mut st, mut cs, active_conns)
			} else if op.kind == op_read {
				win_on_recv(h, mut st, mut cs, int(bytes), limits, counter, active_conns, state)
			} else {
				win_on_send(h, mut st, mut cs, int(bytes), limits, active_conns, state)
			}
		}
		if sweep_on && st.parked > 0 {
			now := time.sys_mono_now()
			if now - st.last_sweep >= win_sweep_interval_ns {
				st.last_sweep = now
				win_sweep_timeouts(now, mut st, active_conns)
			}
		}
	}
}

// win_accept_loop blocks in accept() on the main thread and distributes new
// connections round-robin to the worker ports: associate the socket with the
// worker's IOCP, then hand the fd over as a manual completion — the worker
// allocates all per-connection state itself, so nothing is shared.
fn win_accept_loop(socket_fd int, ports []voidptr, limits core.Limits, active_conns &core.Counter, draining &core.Counter) {
	mut next := 0
	for {
		client_fd := socket.accept_client(socket_fd)
		if client_fd < 0 {
			if stdatomic.load_i64(&draining.n) != 0 {
				break // graceful shutdown: the listener was closed on purpose
			}
			err := C.WSAGetLastError()
			if err == wsaenotsock || err == wsaeintr || err == wsaeinval {
				break // listener closed without draining (test teardown)
			}
			// Transient per-connection failure (e.g. WSAECONNRESET on a
			// half-open connection): keep accepting, but never spin hot.
			time.sleep(10 * time.millisecond)
			continue
		}
		// Enforce max_connections: refuse (close immediately) once at the cap.
		if limits.max_connections > 0
			&& stdatomic.load_i64(&active_conns.n) >= i64(limits.max_connections) {
			socket.close_socket(client_fd)
			continue
		}
		// Disable Nagle so small responses are not delayed.
		socket.set_tcp_nodelay(client_fd)
		port := ports[next]
		next = (next + 1) % ports.len
		if !iocp.associate(port, client_fd, usize(client_fd)) {
			eprintln('[iocp] failed to associate accepted socket: WSA ${C.WSAGetLastError()}')
			socket.close_socket(client_fd)
			continue
		}
		// Registered successfully — count it (released at close).
		stdatomic.add_i64(&active_conns.n, 1)
		if !iocp.post(port, 0, usize(client_fd), unsafe { nil }) {
			stdatomic.add_i64(&active_conns.n, -1)
			socket.close_socket(client_fd)
		}
	}
}

pub fn run_iocp_backend(server Server, mut threads []thread) {
	if server.socket_fd < 0 {
		return
	}
	// One IOCP port per worker (concurrency 1: a single thread services each),
	// mirroring the epoll backend's one-epoll-per-worker fan-out.
	n_workers := threads.len
	mut ports := []voidptr{len: n_workers, init: unsafe { nil }}
	for i in 0 .. n_workers {
		ports[i] = iocp.create_iocp(1) or {
			eprintln('[iocp] ${err}')
			for j in 0 .. i {
				iocp.close_handle(ports[j])
			}
			socket.close_socket(server.socket_fd)
			exit(1)
		}
	}
	// workers is the run-thread-OWNED copy of the spawn handles. The shutdown
	// epilogue below must join from THIS array, never from `threads`: callers
	// commonly spawn run() with a stack-allocated Server (the tests do), and
	// once shutdown() returns they may unwind — `threads` points into that
	// possibly-dead struct, while `workers` lives in this frame for as long as
	// the epilogue needs it.
	mut workers := []thread{len: n_workers, cap: n_workers}
	for i in 0 .. n_workers {
		counter := server.inflight[i] // this worker's own in-flight counter
		t := spawn win_worker(ports[i], server.handler, server.make_state, server.limits, counter,
			server.active_conns)
		threads[i] = t // caller-visible handle (same contract as the other backends)
		workers[i] = t
	}
	println('listening on http://localhost:${server.port}/ (IOCP)')
	// Server is accepting (listeners bound, workers spawned); fire the one-shot
	// lifecycle hook on this (main) thread right before we block in the accept
	// loop. Same contract as the epoll/io_uring/kqueue backends.
	if server.after_server_start != unsafe { nil } {
		server.after_server_start()
	}
	win_accept_loop(server.socket_fd, ports, server.limits, server.active_conns, server.draining)
	// The accept loop only returns when the listener is gone (graceful
	// shutdown or test teardown). Wake every worker out of its blocking wait
	// (key = 0 control message), join them, and release the ports — so a
	// process that starts and stops servers in-process (the test binaries do)
	// leaks neither threads nor port handles. Any completion queued BEFORE the
	// wake is still processed first (the port is FIFO); in-flight request
	// handling was already drained by Server.shutdown()'s counter wait.
	for i in 0 .. n_workers {
		iocp.post(ports[i], 0, 0, unsafe { nil })
	}
	for i in 0 .. n_workers {
		workers[i].wait()
	}
	for i in 0 .. n_workers {
		iocp.close_handle(ports[i])
	}
}

// run_selected_backend dispatches to the configured Windows backend. Defined
// per OS so the all-platform facade (http_server.c.v) needs no
// platform-specific backend import. Blocks in the accept loop.
fn run_selected_backend(server Server, mut threads []thread) {
	match server.io_multiplexing {
		.iocp {
			run_iocp_backend(server, mut threads)
		}
	}
}

pub fn (mut server Server) run() {
	run_selected_backend(server, mut server.threads)
}

// iou_backend_available: io_uring is Linux-only, so it is never available here.
// See the Linux definition (http_server_io_uring_linux.c.v) for the real probe.
pub fn iou_backend_available() bool {
	return false
}
