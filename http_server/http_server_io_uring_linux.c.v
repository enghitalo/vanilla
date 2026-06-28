module http_server

import io_uring
import http1_1.response
import http1_1.request_parser
import socket
import http_server.core
import sync.stdatomic
import os
import time

#include <errno.h>
#include <string.h>
#include <sched.h>
#include <sys/socket.h>

fn C.perror(s &u8)
fn C.sleep(seconds u32) u32
fn C.close(fd int) int
fn C.shutdown(sockfd int, how int) int
fn C.memmove(dest voidptr, src voidptr, n usize) voidptr
fn C.sched_setaffinity(pid int, cpusetsize usize, mask &u64) int

// Default ceiling on a single buffered request (headers+body) when the server
// configures no max_request_bytes. Mirrors the epoll backend (sm_max_request_bytes).
const iou_max_request_bytes = 8 * 1024 * 1024
// A request body larger than this is STREAMED, not buffered: the head is answered
// on its own and the body is drained off the socket into the fixed read buffer and
// discarded (see start_iou_body_drain). Keeps a multi-MB upload at O(read_buf_cap)
// memory instead of holding the whole body per connection. Mirrors the epoll
// backend's sm_stream_body_above; handlers on this path must answer by the declared
// Content-Length (request_parser.HttpRequest.content_length()), since no body is
// passed to them — the /upload profile is exactly this shape.
const iou_stream_body_above = 1024 * 1024
// Close a peer that pipelines requests but never drains responses, before its
// response batch grows without bound.
const iou_max_pending_write = 8 * 1024 * 1024
// How often the worker wakes to sweep stale connections when a read timeout is
// configured (ns). Zero cost when no timeout is set — the loop blocks instead.
const iou_sweep_interval_ns = i64(250 * 1_000_000)

// iou_release decrements the global connection count (only when max_connections
// accounting is active) and returns the connection to its pool. pool_release is
// idempotent (clears owner), so this is safe to call more than once for the same
// connection and the counter stays exact: the decrement is guarded by the same
// owner!=nil check, so it fires exactly once per accepted connection.
@[inline]
fn iou_release(worker &io_uring.Worker, mut conn io_uring.Connection, active_conns &core.Counter, track bool) {
	if track && unsafe { conn.owner != nil } {
		stdatomic.add_i64(&active_conns.n, -1)
	}
	io_uring.pool_release_from_ptr(worker, mut conn)
}

// iou_arm_recv posts the next recv and maintains the read deadline: armed while a
// partial request is buffered (read_buf.len > 0), cleared on an idle keep-alive
// wait (read_buf empty) so idle connections are never reaped mid-keep-alive.
// All deadline logic is gated on read_timeout_ms > 0, so the default path pays
// nothing (no clock read, no shared state). Returns false if the SQ is full.
@[inline]
fn iou_arm_recv(worker &io_uring.Worker, mut conn io_uring.Connection, limits Limits) bool {
	if limits.read_timeout_ms > 0 {
		if conn.read_buf.len > 0 {
			if conn.read_deadline == 0 {
				conn.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			}
		} else {
			conn.read_deadline = 0
		}
	}
	return io_uring.prepare_recv(&worker.ring, mut conn)
}

// iou_arm_send posts a send and arms the write deadline: the whole response batch
// must finish draining within write_timeout_ms of the FIRST send (armed once, not
// refreshed on each partial-send remainder — so a peer that stops reading
// mid-response is reaped). Cleared when the batch fully drains. Gated on
// write_timeout_ms > 0, so the default path pays nothing. Returns false if the SQ
// is full.
@[inline]
fn iou_arm_send(worker &io_uring.Worker, mut conn io_uring.Connection, data &u8, data_len usize, limits Limits) bool {
	if limits.write_timeout_ms > 0 && conn.write_deadline == 0 {
		conn.write_deadline = time.sys_mono_now() + u64(limits.write_timeout_ms) * 1_000_000
	}
	return io_uring.prepare_send(&worker.ring, mut conn, data, data_len)
}

// iou_arm_drain_recv posts the next length-clamped discard-recv while a large
// upload body is being streamed (conn.body_drain > 0). It keeps a read deadline
// armed (gated on read_timeout_ms) so a peer that stalls mid-body is still reaped
// — body_drain, not read_buf.len, is the "mid-read" signal here. Returns false if
// the SQ is full.
@[inline]
fn iou_arm_drain_recv(worker &io_uring.Worker, mut conn io_uring.Connection, limits Limits) bool {
	if limits.read_timeout_ms > 0 && conn.read_deadline == 0 {
		conn.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
	}
	return io_uring.prepare_recv_n(&worker.ring, mut conn, usize(conn.body_drain))
}

// iou_flush_response arms the batched send for everything still pending in
// response_buffer ([bytes_sent..len)), drops any read deadline (we are sending,
// not read-stalled) and counts the in-flight response so Server.shutdown() drains
// it. Used by every send site (normal completion, large-body drain completion, and
// the head-only error path), so they cannot drift apart. Returns false if the SQ
// is full.
@[inline]
fn iou_flush_response(worker &io_uring.Worker, mut conn io_uring.Connection, limits Limits) bool {
	conn.read_deadline = 0
	posted := iou_arm_send(worker, mut conn, unsafe {
		&u8(conn.response_buffer.data) + conn.bytes_sent
	}, usize(conn.response_buffer.len - conn.bytes_sent), limits)
	// Count the in-flight response ONLY once the send is actually queued. If the SQ
	// is full (posted == false) no send CQE will ever arrive, so a pre-increment
	// would leak into worker.inflight and make Server.shutdown() wait out its whole
	// grace period. (A full SQ still leaves the connection without an in-flight op —
	// a pre-existing limitation shared by every prepare_* call site, reachable only
	// on a degraded ring; the counter, at least, now stays exact.)
	if posted && unsafe { worker.inflight != nil } {
		stdatomic.add_i64(&worker.inflight.n, 1)
	}
	return posted
}

// maybe_pin_worker pins the calling worker thread to `cpu` when VANILLA_PIN_CPUS
// is set. Opt-in: pinning warms caches and stops migration on dedicated
// hardware, but can hurt on a shared box (a co-located load generator competing
// for the same core), so it is off by default. Failure (offline CPU, cgroup
// cpuset restriction) is non-fatal — the thread just stays schedulable anywhere.
fn maybe_pin_worker(cpu int) {
	if cpu < 0 || cpu >= 1024 || os.getenv('VANILLA_PIN_CPUS') == '' {
		return
	}
	mut set := [16]u64{} // CPU_SETSIZE/64 words → up to 1024 CPUs
	set[cpu / 64] |= u64(1) << u32(cpu % 64)
	C.sched_setaffinity(0, usize(sizeof(set)), &set[0])
}

// --- io_uring CQE handlers -------------------------------------------------
//
// Every handler only QUEUES SQEs (via the prepare_* helpers); nothing submits.
// The single io_uring_submit_and_wait at the top of the worker loop flushes
// everything queued during the previous drain. Each connection has exactly one
// op in flight at a time (recv → send → recv …), so its buffers are never
// touched by two operations concurrently.

fn handle_io_uring_accept(worker &io_uring.Worker, cqe &C.io_uring_cqe, limits Limits, active_conns &core.Counter) {
	res := cqe.res
	if res >= 0 {
		fd := res
		track := limits.max_connections > 0
		// Enforce max_connections at accept (mirrors the epoll backend): refuse
		// once the global count is at the cap. The counter is touched only when a
		// cap is set, so the default path stays shared-nothing.
		if track && stdatomic.load_i64(&active_conns.n) >= i64(limits.max_connections) {
			C.close(fd)
		} else {
			// Disable Nagle so small responses are not delayed (missing before).
			socket.set_tcp_nodelay(fd)
			mut nc := io_uring.pool_acquire_from_ptr(worker, fd)
			if unsafe { nc != nil } {
				if track {
					stdatomic.add_i64(&active_conns.n, 1)
				}
				if !iou_arm_recv(worker, mut *nc, limits) {
					iou_release(worker, mut *nc, active_conns, track)
				}
			} else {
				C.close(fd) // pool exhausted
			}
		}
	}
	// Graceful shutdown: once Server.shutdown() has set the draining flag (and
	// shut the listener, which is what completed this accept with an error), do
	// NOT re-arm — re-arming on a dead socket would spin. With no armed accept the
	// worker simply stops taking new connections and lets the in-flight ones drain.
	if unsafe { worker.draining != nil } && stdatomic.load_i64(&worker.draining.n) != 0 {
		return
	}
	// Multishot accept delivers one CQE per connection with F_MORE set while it
	// stays armed; re-arm only once F_MORE is clear (multishot ended) or on
	// error. This branch also covers single-shot accept, where F_MORE is never
	// set, so we re-arm after every accept.
	if (cqe.flags & io_uring.ioring_cqe_f_more) == 0 {
		io_uring.prepare_accept(&worker.ring, worker.socket_fd, worker.use_multishot)
	}
}

fn handle_io_uring_read(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn (req []u8, fd int, mut out []u8) !, limits Limits, active_conns &core.Counter) {
	track := limits.max_connections > 0
	res := cqe.res
	c_ptr := io_uring.decode_connection_ptr(C.io_uring_cqe_get_data64(cqe))
	if unsafe { c_ptr == nil } {
		return
	}
	mut conn := unsafe { &io_uring.Connection(c_ptr) }
	if res <= 0 {
		// res == 0: peer closed (EOF, incl. the half-close from a timeout sweep).
		// res < 0: recv error (e.g. -ECONNRESET, -ECANCELED).
		iou_release(worker, mut *conn, active_conns, track)
		return
	}
	// Streaming-drain: these `res` bytes are a large upload's body being consumed
	// off the socket and DISCARDED — the head was already answered and its response
	// is held in response_buffer. prepare_recv_n clamped the recv to the body
	// remainder, so res never includes the next pipelined request.
	if conn.body_drain > 0 {
		conn.body_drain -= res
		if conn.body_drain > 0 {
			iou_arm_drain_recv(worker, mut *conn, limits) // more body to consume
		} else {
			// Whole body drained — now send the response prepared from the head.
			iou_flush_response(worker, mut *conn, limits)
		}
		return
	}
	unsafe {
		conn.read_buf.len += res
	}
	// Answer every complete request now buffered (pipelining), appending each
	// raw response to response_buffer and compacting the partial leftover.
	drain_iou_requests(mut conn, handler, limits)
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		iou_max_request_bytes
	}
	// Enforce the single-request ceiling on a leftover partial that never frames
	// (mirrors the epoll backend's req_cap check).
	if !conn.close_after_send && conn.read_buf.len > req_cap {
		conn.response_buffer << response.status_413_response
		conn.close_after_send = true
	}
	if conn.response_buffer.len > conn.bytes_sent {
		// One batched send for every response produced this burst (arms the write
		// deadline, counts the in-flight response for graceful shutdown).
		iou_flush_response(worker, mut *conn, limits)
		return
	}
	// Nothing complete yet. A body too large to be worth buffering is STREAMED:
	// answer it from the head alone, then drain+discard the body. This keeps memory
	// at O(read_buf_cap) instead of growing read_buf into a multi-MB block and
	// ping-ponging recv→CQE→re-arm thousands of times for a 20 MiB upload.
	total := request_parser.frame_expected_total(conn.read_buf)
	if total > iou_stream_body_above && total <= req_cap {
		if start_iou_body_drain(mut conn, handler, total) {
			if conn.close_after_send || conn.body_drain == 0 {
				// Handler errored on the head (send the error, then close), or the
				// whole body happened to be buffered already — either way send now.
				iou_flush_response(worker, mut *conn, limits)
			} else {
				iou_arm_drain_recv(worker, mut *conn, limits) // start draining the body
			}
			return
		}
		// Head not fully buffered yet → fall through to normal buffering.
	}
	// Read more into the same buffer (arming the read deadline since a partial
	// request is now buffered). When the body length is already known
	// (Content-Length), pre-size read_buf to the exact message length in ONE
	// allocation; otherwise prepare_recv doubles toward it.
	if conn.read_buf.len == conn.read_buf.cap && total > conn.read_buf.cap && total <= req_cap {
		unsafe { conn.read_buf.grow_cap(total - conn.read_buf.cap) }
	}
	iou_arm_recv(worker, mut *conn, limits)
}

// buf_view returns a non-owning []u8 window into buf[start..start+length] with the
// `.managed` flag cleared, so V skips the per-slice slice-aliasing bookkeeping
// (mark_buffer_has_slices + header/flag churn) that the native `buf[a..b]` operator
// runs unconditionally. read_buf is manually managed here (grown via grow_cap,
// compacted via memmove, len reset — never `delete`d with a live slice), so that
// bookkeeping is pure waste: callgrind showed the native slices as ~23% of the
// io_uring worker's pipelined instructions (builtin__array_slice), absent from the
// epoll backend, which already frames with this same helper. Mirrors
// backend_epoll/conn_state_linux.c.v:buf_view.
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

// drain_iou_requests parses and answers every complete request in read_buf,
// appending responses to response_buffer, then compacts the leftover partial
// bytes to the front. On a framing error, an oversized payload, or a handler
// error it appends the canned response and sets close_after_send so the worker
// releases the connection once that final batch has been flushed.
@[direct_array_access; manualfree]
fn drain_iou_requests(mut conn io_uring.Connection, handler fn (req []u8, fd int, mut out []u8) !, limits Limits) {
	mut pos := 0
	for pos < conn.read_buf.len {
		// _idx twin: plain int, no per-request !int boxing. The error sentinel is
		// the negated HTTP status, so `-total` recovers the old err.code() value.
		total := request_parser.frame_request_length_lim_idx(buf_view(conn.read_buf, pos,
			conn.read_buf.len - pos), limits.max_header_bytes, limits.max_body_bytes)
		if total == -1 {
			break // incomplete — wait for more bytes
		}
		if total < -1 {
			match -total {
				413 { conn.response_buffer << response.status_413_response }
				431 { conn.response_buffer << response.status_431_response }
				else { conn.response_buffer << response.tiny_bad_request_response }
			}

			conn.close_after_send = true
			return
		}
		req := buf_view(conn.read_buf, pos, total) // zero-copy, non-marking view (no array_slice)
		handler(req, conn.fd, mut conn.response_buffer) or {
			conn.response_buffer << response.tiny_bad_request_response
			conn.close_after_send = true
			return
		}
		pos += total
		// Peer pipelines requests but never reads responses: bail before the
		// pending batch grows without bound.
		if conn.response_buffer.len - conn.bytes_sent > iou_max_pending_write {
			conn.close_after_send = true
			return
		}
	}
	// Compact the leftover partial request to the buffer start (keeps capacity).
	if pos > 0 {
		leftover := conn.read_buf.len - pos
		if leftover > 0 {
			unsafe {
				C.memmove(conn.read_buf.data, &u8(conn.read_buf.data) + pos, usize(leftover))
			}
		}
		unsafe {
			conn.read_buf.len = leftover
		}
	}
}

// start_iou_body_drain answers a large-body request from its HEAD alone and puts
// the connection into streaming-drain mode for the body (consumed and discarded by
// the conn.body_drain branch in handle_io_uring_read). The handler is given only
// the head — no body is buffered — so such handlers must answer by the declared
// Content-Length (request_parser.HttpRequest.content_length()); the /upload profile
// is exactly this shape. The prepared response is HELD in response_buffer and sent
// once the body has fully drained. The io_uring counterpart of the epoll backend's
// start_body_drain. Returns true when the large body is now being handled — drain
// armed (body_drain > 0), the head-only handler errored (close_after_send), or the
// whole body was already buffered (body_drain == 0) — and false when the head is
// not yet fully buffered (the caller keeps buffering normally).
@[direct_array_access]
fn start_iou_body_drain(mut conn io_uring.Connection, handler fn (req []u8, fd int, mut out []u8) !, total int) bool {
	head_len := request_parser.frame_head_len(conn.read_buf)
	if head_len <= 0 || head_len > conn.read_buf.len {
		return false // head not complete in the buffer yet — keep buffering
	}
	head := buf_view(conn.read_buf, 0, head_len) // zero-copy, non-marking view; handler consumes it now
	handler(head, conn.fd, mut conn.response_buffer) or {
		conn.response_buffer << response.tiny_bad_request_response
		conn.close_after_send = true
		unsafe {
			conn.read_buf.len = 0
		}
		return true
	}
	// Body bytes already received after the head count toward the drain. Detection
	// runs before read_buf ever grows past its base cap, so body_in_buf is always
	// < content_length (the request is still incomplete) — no next-request bytes
	// are present to be lost.
	body_in_buf := conn.read_buf.len - head_len
	conn.body_drain = i64(total - head_len) - i64(body_in_buf)
	if conn.body_drain < 0 {
		conn.body_drain = 0
	}
	unsafe {
		conn.read_buf.len = 0 // head + buffered body consumed; reuse buffer to drain
	}
	return true
}

fn handle_io_uring_write(worker &io_uring.Worker, cqe &C.io_uring_cqe, limits Limits, active_conns &core.Counter) {
	track := limits.max_connections > 0
	res := cqe.res
	c_ptr := io_uring.decode_connection_ptr(C.io_uring_cqe_get_data64(cqe))
	if unsafe { c_ptr == nil } {
		return
	}
	mut conn := unsafe { &io_uring.Connection(c_ptr) }
	if res <= 0 {
		// 0 on a non-empty send (or <0) means the peer is gone — drop it. The
		// response was in flight, so settle the drain counter before releasing.
		if unsafe { worker.inflight != nil } {
			stdatomic.add_i64(&worker.inflight.n, -1)
		}
		iou_release(worker, mut *conn, active_conns, track)
		return
	}
	conn.bytes_sent += res
	if conn.bytes_sent < conn.response_buffer.len {
		// Partial send — resume from the offset. iou_arm_send keeps the existing
		// write deadline (armed on the first send), so the whole batch must drain
		// within write_timeout_ms regardless of how many partial sends it takes.
		// Still in flight — the inflight count stays held until the batch finishes.
		iou_arm_send(worker, mut *conn, unsafe {
			&u8(conn.response_buffer.data) + conn.bytes_sent
		}, usize(conn.response_buffer.len - conn.bytes_sent), limits)
		return
	}
	// Whole batch sent — the write is no longer outstanding; release the drain hold.
	conn.write_deadline = 0
	if unsafe { worker.inflight != nil } {
		stdatomic.add_i64(&worker.inflight.n, -1)
	}
	if conn.close_after_send {
		iou_release(worker, mut *conn, active_conns, track)
		return
	}
	conn.response_buffer.clear() // len = 0, capacity kept for the next batch
	conn.bytes_sent = 0
	// Keep-alive: read the next request. read_buf still holds any pipelined
	// leftover; iou_arm_recv re-arms the read deadline iff that leftover is a
	// partial request, and leaves an idle keep-alive wait deadline-free.
	iou_arm_recv(worker, mut *conn, limits)
}

fn dispatch_io_uring_cqe(worker &io_uring.Worker, cqe &C.io_uring_cqe, handler fn (req []u8, fd int, mut out []u8) !, limits Limits, active_conns &core.Counter) {
	op := io_uring.decode_op_type(C.io_uring_cqe_get_data64(cqe))
	match op {
		io_uring.op_accept { handle_io_uring_accept(worker, cqe, limits, active_conns) }
		io_uring.op_read { handle_io_uring_read(worker, cqe, handler, limits, active_conns) }
		io_uring.op_write { handle_io_uring_write(worker, cqe, limits, active_conns) }
		else {}
	}
}

// iou_sweep_timeouts half-closes every connection whose read OR write deadline
// has passed. It calls shutdown(2) (NOT close): the connection still has its
// single recv/send in flight, so closing here would free the pool slot while a
// completion is still pending — and a fresh accept could reuse that slot under
// the stale CQE. shutdown makes the in-flight op complete with an error/EOF, and
// handle_io_uring_read/write then frees the slot the normal way, after its CQE is
// drained. Scanned only when a read or write timeout is configured.
@[direct_array_access]
fn iou_sweep_timeouts(worker &io_uring.Worker) {
	mut w := unsafe { &io_uring.Worker(worker) }
	now := time.sys_mono_now()
	for i in 0 .. w.conns.len {
		mut c := unsafe { &w.conns[i] }
		if unsafe { c.owner == nil } {
			continue // free slot
		}
		// A connection has at most one direction in flight at a time, so the two
		// deadlines never both fire on the same slot; clear whichever did so we
		// don't shut it down again before its CQE lands.
		if c.read_deadline > 0 && now > c.read_deadline {
			C.shutdown(c.fd, C.SHUT_RDWR)
			c.read_deadline = 0
		} else if c.write_deadline > 0 && now > c.write_deadline {
			C.shutdown(c.fd, C.SHUT_RDWR)
			c.write_deadline = 0
		}
	}
}

// io_uring_worker_main is the spawned worker entry point. The ENTIRE ring
// lifecycle — create, register, submit and reap — happens on this one thread.
// SINGLE_ISSUER / DEFER_TASKRUN bind the ring to its issuing task, so setting it
// up on the main thread and driving it here would make every submit_and_wait
// fail; doing it all here keeps the ring single-owner (and matches how every
// thread-per-core io_uring server sets up).
fn io_uring_worker_main(listener int, cpu_id int, handler fn (req []u8, fd int, mut out []u8) !, limits Limits, active_conns &core.Counter, inflight &core.Counter, draining &core.Counter) {
	maybe_pin_worker(cpu_id)
	mut worker := &io_uring.Worker{}
	worker.cpu_id = cpu_id
	worker.socket_fd = listener
	// Graceful-shutdown plumbing: this worker's own in-flight counter and the
	// shared draining flag (see Server.shutdown / handle_io_uring_accept).
	worker.inflight = inflight
	worker.draining = draining
	io_uring.pool_init(mut worker)

	ring_entries := iou_init_ring(&worker.ring) or {
		eprintln('Failed to initialize io_uring for worker ${cpu_id}: ${err.msg()}')
		exit(1)
	}
	if ring_entries < io_uring.default_ring_entries {
		// Fell back to a smaller ring (likely a tight RLIMIT_MEMLOCK). The
		// connection pool is still sized for default_ring_entries, so under a
		// burst the SQ can fill and accept re-arming can be skipped — surface it
		// instead of silently degrading.
		eprintln('io_uring worker ${cpu_id}: using ${ring_entries} SQ entries (fell back from ${io_uring.default_ring_entries})')
	}
	// Multishot accept needs kernel 5.19+; on older kernels stay single-shot
	// (the re-arm in handle_io_uring_accept covers it). Detected per worker at
	// startup — one uname() call, off the hot path.
	worker.use_multishot = iou_multishot_accept_supported()
	// Skip the per-enter fget/fput on the ring fd.
	C.io_uring_register_ring_fd(&worker.ring)

	io_uring_worker_loop(worker, handler, limits, active_conns)
}

@[direct_array_access]
fn io_uring_worker_loop(worker &io_uring.Worker, handler fn (req []u8, fd int, mut out []u8) !, limits Limits, active_conns &core.Counter) {
	io_uring.prepare_accept(&worker.ring, worker.socket_fd, worker.use_multishot)

	// Only arm the periodic timeout wake when a read or write timeout is
	// configured; otherwise the loop blocks indefinitely (zero cost on the
	// default path).
	sweep_on := limits.read_timeout_ms > 0 || limits.write_timeout_ms > 0
	mut ts := C.__kernel_timespec{
		tv_sec:  0
		tv_nsec: iou_sweep_interval_ns
	}

	mut cqes := unsafe { [io_uring.drain_batch]&C.io_uring_cqe{} }
	for {
		// ONE syscall per loop iteration: flush every SQE queued during the last
		// drain and block until at least one completion is ready (or, when a read
		// timeout is set, until the sweep interval elapses → -ETIME).
		mut ret := 0
		if sweep_on {
			mut first := &C.io_uring_cqe(unsafe { nil })
			ret = C.io_uring_submit_and_wait_timeout(&worker.ring, &first, 1, &ts, unsafe { nil })
		} else {
			ret = C.io_uring_submit_and_wait(&worker.ring, 1)
		}
		if ret < 0 {
			if ret == -C.EINTR || ret == -C.ETIME {
				// EINTR: retry. ETIME: no completion this interval — fall through
				// to the (empty) drain and then the sweep.
			} else {
				C.perror(c'io_uring_submit_and_wait')
				break
			}
		}
		// Batch-drain the CQ: copy out ready CQEs, dispatch (which only queues
		// new SQEs), then acknowledge the whole batch with one cq_advance.
		for {
			n := C.io_uring_peek_batch_cqe(&worker.ring, &cqes[0], u32(io_uring.drain_batch))
			if n == 0 {
				break
			}
			for i in 0 .. int(n) {
				dispatch_io_uring_cqe(worker, cqes[i], handler, limits, active_conns)
			}
			C.io_uring_cq_advance(&worker.ring, n)
			if int(n) < io_uring.drain_batch {
				break
			}
			// A full batch may mean more are ready: flush the SQEs queued so far
			// to free SQ slots before draining the rest (keeps the SQ from ever
			// overflowing, regardless of how many completions piled up).
			C.io_uring_submit(&worker.ring)
		}
		if sweep_on {
			iou_sweep_timeouts(worker)
		}
	}
}

// iou_init_ring sets the ring up with the best available flag combo, trying in
// order: SINGLE_ISSUER|DEFER_TASKRUN (kernel 6.0+, the recommended setup),
// SINGLE_ISSUER|COOP_TASKRUN (5.19+), then plain flags. For each combo it walks
// the SQ size down from default_ring_entries so a host with a tight
// RLIMIT_MEMLOCK still gets a working ring. SQPOLL is intentionally never used.
// Returns the negotiated SQ entry count; errors only if every entry/flag
// combination fails.
fn iou_init_ring(ring &C.io_uring) !u32 {
	entry_candidates := [u32(io_uring.default_ring_entries), u32(8192), u32(4096), u32(2048),
		u32(1024), u32(512), u32(256)]
	for entries in entry_candidates {
		mut p := C.io_uring_params{}
		p.flags = io_uring.setup_single_issuer | io_uring.setup_defer_taskrun
		if C.io_uring_queue_init_params(entries, ring, &p) == 0 {
			return entries
		}

		p = C.io_uring_params{}
		p.flags = io_uring.setup_single_issuer | io_uring.setup_coop_taskrun
		if C.io_uring_queue_init_params(entries, ring, &p) == 0 {
			return entries
		}

		p = C.io_uring_params{}
		if C.io_uring_queue_init_params(entries, ring, &p) == 0 {
			return entries
		}
	}
	return error('io_uring_queue_init_params failed for all ring entry/flag combinations')
}

// iou_multishot_accept_supported reports whether the running kernel supports
// multishot accept (IORING_OP_ACCEPT + IORING_ACCEPT_MULTISHOT, kernel 5.19+).
// There is NO params.features bit for it and no way to probe the multishot
// *flavour* of accept (plain accept has been a supported opcode since 5.5), so
// the kernel release is the only reliable signal. Requesting multishot on an
// older kernel makes every accept SQE fail with -EINVAL, and the re-arm in
// handle_io_uring_accept would respin it forever, so this gate must be correct.
fn iou_multishot_accept_supported() bool {
	return iou_release_supports_multishot(os.uname().release)
}

// iou_release_supports_multishot parses a `uname -r` release string
// ("6.8.0-41-generic") and returns true for kernel >= 5.19. Split out so it can
// be unit-tested without a live kernel. A backported kernel that reports an
// older release simply falls back to single-shot accept: correct, only slower.
fn iou_release_supports_multishot(release string) bool {
	parts := release.split('.')
	if parts.len < 2 {
		return false
	}
	major := parts[0].int()
	minor := parts[1].int()
	return major > 5 || (major == 5 && minor >= 19)
}

// run_io_uring_backend spawns one shared-nothing worker per core, each owning
// its own ring + SO_REUSEPORT listener + connection pool.
//
// Limits parity with the epoll backend: max_request_bytes/header/body (413/431),
// max_connections (refused at accept), read_timeout_ms (slowloris: a partial
// request that stalls is half-closed by the per-worker sweep) and write_timeout_ms
// (a peer that stops reading mid-response is half-closed the same way) are all
// enforced.
//
// Graceful shutdown: Server.shutdown() sets the shared draining flag and
// shutdown(2)s every listener in server.listener_fds (created up front in
// new_server, one SO_REUSEPORT socket per worker), then waits for the per-worker
// inflight counters to drain. The accept handler stops re-arming once draining,
// so every worker quits accepting and the process can exit cleanly.
pub fn run_io_uring_backend(server Server, mut threads []thread) {
	// on_worker_start (clientless background watches) is an epoll-reactor feature;
	// new_server rejects it for io_uring at config time. Assert defensively so a
	// future refactor (or a Server built directly, bypassing new_server) fails loud
	// instead of silently dropping the hook.
	if server.on_worker_start != unsafe { nil } {
		panic('on_worker_start is not supported on the io_uring backend')
	}
	num_workers := max_thread_pool_size

	for i in 0 .. num_workers {
		// One SO_REUSEPORT listener per worker, all created in new_server so
		// Server.shutdown() can stop them all (worker 0 reuses socket_fd). The
		// kernel load-balances accepts across them; none is left un-accepted.
		// (Listeners aren't ring-bound, so they live on the main thread — only the
		// ring itself must stay on its worker thread.)
		listener := server.listener_fds[i]
		if listener < 0 {
			eprintln('Failed to create listener for worker ${i}')
			exit(1)
		}
		threads[i] = spawn io_uring_worker_main(listener, i, server.request_handler, server.limits,
			server.active_conns, server.inflight[i], server.draining)
	}

	println('listening on http://localhost:${server.port}/ (io_uring)')

	// Keep main thread alive.
	for {
		C.sleep(1)
	}
}
