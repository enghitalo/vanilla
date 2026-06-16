module backend_epoll

// Plain (non-TLS) connection state machine for the epoll worker.
//
// Shared-nothing hot path modeled on the fastest HTTP/1.1 servers
// (see docs/PERF_GAP_ANALYSIS.md):
//   • persistent per-connection buffers — every connection owns a reused read
//     buffer (8 KiB) and write buffer (16 KiB) for its whole lifetime; no
//     per-event allocation, no per-request free;
//   • flat fd-indexed state table — O(1) lookup, no hashing;
//   • HTTP/1.1 pipelining — one EPOLLIN burst may carry many requests; every
//     complete request is parsed and answered into the write buffer, leftover
//     partial bytes are compacted to the front, and the whole batch goes out
//     in ONE send;
//   • backpressure — a batch that can't be sent in one go is parked and
//     drained on EPOLLOUT (write_timeout guarded), never truncated; a peer
//     that pipelines requests without reading responses is closed once its
//     pending batch exceeds sm_max_pending_write.
import http_server.core
import http_server.epoll
import http_server.http1_1.request_parser
import http_server.http1_1.response
import sync.stdatomic
import time

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <unistd.h>

// recv/send were inherited from http_server.c.v while this lived in that module;
// now in backend_epoll they must be declared here.
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.memmove(__dest voidptr, __src voidptr, __n usize) voidptr

// sendfile(2): copy bytes from a file fd straight to the socket inside the
// kernel (no userspace bounce). With a non-NULL offset the kernel advances it
// and leaves the file's own position untouched, so ONE shared fd is safe to
// send from many connections/threads at once. pread is the userspace fallback
// used when a pipelined response must follow the file body in byte order.
fn C.sendfile(out_fd int, in_fd int, offset &i64, count usize) isize
fn C.pread(fd int, buf voidptr, count usize, offset i64) isize

// Boehm's no-scan (atomic) allocator: blocks it returns are never traced for
// pointers. GC_realloc preserves that kind, so a buffer stays no-scan as it grows.
fn C.GC_malloc_atomic(n usize) voidptr
fn C.GC_realloc(ptr voidptr, n usize) voidptr

// noscan_alloc returns a []u8 whose backing store the GC never scans. A large
// per-connection buffer (a multi-MB upload's read_buf, a multi-hundred-KB static
// asset's write_buf) as a *scanned* GC block makes Boehm's mark phase + its
// stop-the-world pauses dominate at high keep-alive connection counts — the
// "cliff" that capped upload and static throughput. Allocating the backing
// atomic removes those bytes from every GC scan. Works on any V (no dependency
// on the post-0.5.1 `.noscan_data` ArrayFlag); with `-gc none` there is no GC to
// scan, so a plain allocation is already untraced.
@[inline]
fn noscan_alloc(cap int) []u8 {
	mut a := []u8{}
	$if gcboehm ? {
		unsafe {
			a.data = C.GC_malloc_atomic(usize(cap))
			a.cap = cap
			a.len = 0
			a.element_size = 1
		}
	} $else {
		a = []u8{len: 0, cap: cap}
	}
	return a
}

// noscan_grow resizes a noscan_alloc'd buffer to `newcap` while keeping it
// no-scan (GC_realloc preserves the atomic kind and copies the old contents).
@[inline]
fn noscan_grow(mut a []u8, newcap int) {
	$if gcboehm ? {
		unsafe {
			a.data = C.GC_realloc(a.data, usize(newcap))
			a.cap = newcap
		}
	} $else {
		a.ensure_cap(newcap)
	}
}

const sm_max_request_bytes = 8 * 1024 * 1024
// Bound a single sendfile(2) call so one connection can't monopolize the worker;
// the remainder streams on the next writable edge.
const sm_sendfile_chunk = 1024 * 1024
// Write-side cap: close a connection whose peer pipelines requests but never
// drains responses (otherwise write_buf would grow without bound).
const sm_max_pending_write = 8 * 1024 * 1024
const read_buf_cap = 8 * 1024
const write_buf_cap = 16 * 1024
const conn_table_min = 1024

// ConnState is allocated once per connection (on its first event) and reused
// until the connection closes. The buffers keep their capacity across
// requests: read_buf accumulates request bytes across edges, write_buf
// accumulates response bytes until they are flushed in one send.
struct ConnState {
mut:
	read_buf       []u8 // persistent request buffer; len = bytes buffered
	write_buf      []u8 // persistent response buffer; [write_off..len) pending
	write_off      int
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read (read_timeout)
	write_deadline u64 // monotonic ns; >0 while a batch is parked (write_timeout)
	// Deferred file body to stream with sendfile(2) AFTER write_buf drains (a
	// handler appended its headers to write_buf and handed the body off via
	// core.queue_file). file_fd is BORROWED (the asset table owns it) and is
	// never closed here; file_off is advanced by the kernel as bytes go out.
	file_fd        int = -1
	file_off       i64
	file_remaining i64
}

// PlainState is the per-worker connection table. `parked` counts connections
// with an armed deadline, so the worker only pays for timeout sweeps when
// something is actually mid-transfer.
pub struct PlainState {
mut:
	conns  []&ConnState
	parked int
}

pub fn new_plain_state() PlainState {
	return PlainState{
		conns: []&ConnState{len: conn_table_min, init: unsafe { nil }}
	}
}

// state_for returns the connection state for fd, creating it (with its
// persistent buffers) on first use. The table grows by doubling, so fd
// indexing stays O(1) with no hashing.
@[direct_array_access]
fn state_for(mut st PlainState, fd int) &ConnState {
	if fd >= st.conns.len {
		mut new_len := st.conns.len
		for new_len <= fd {
			new_len *= 2
		}
		mut grown := []&ConnState{len: new_len, init: unsafe { nil }}
		for i in 0 .. st.conns.len {
			grown[i] = st.conns[i]
		}
		st.conns = grown
	}
	if unsafe { st.conns[fd] == nil } {
		// Both buffers are allocated NO-SCAN (see noscan_alloc): a large read_buf
		// (multi-MB upload) or write_buf (large static asset) as a scanned GC block
		// is what made Boehm's mark + stop-the-world dominate at high conn counts.
		// read_buf stays no-scan across growth (it grows only via noscan_grow in
		// the recv path). write_buf stays no-scan while a response fits its current
		// capacity; large bodies that don't fit should be streamed via core's
		// borrowed-send paths (queue_file / queue_buffer) rather than grown.
		mut cs := &ConnState{
			read_buf:  noscan_alloc(read_buf_cap)
			write_buf: noscan_alloc(write_buf_cap)
		}
		st.conns[fd] = cs
	}
	return st.conns[fd]
}

// handle_readable_plain drains the socket into the connection's persistent
// read buffer, answers EVERY complete request as it goes (pipelining), and
// flushes all accumulated responses in one batched send at the end of the
// burst. Returns early (connection closed) on any fatal condition.
@[direct_array_access; manualfree]
fn handle_readable_plain(request_handler core.RequestHandler, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	mut cs := state_for(mut st, fd)
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}

	// Edge-triggered: read to EAGAIN. Parse after every recv so the request
	// cap applies to a single (partial) request, not to the whole burst.
	for {
		if cs.read_buf.len == cs.read_buf.cap {
			// Pre-size to the exact message length when Content-Length is already
			// known (one allocation), instead of doubling toward it. A 20 MiB
			// upload otherwise grows 8K→16K→…→32M: ~12 reallocs, tens of MB of
			// memcpy, and a buffer that overshoots the body by up to 2×. A hostile
			// or chunked/unknown length (target -1 or > req_cap) falls back to
			// doubling, so the existing req_cap/413 guard still trips normally.
			target := request_parser.frame_expected_total(cs.read_buf)
			if target > cs.read_buf.cap && target <= req_cap {
				noscan_grow(mut cs.read_buf, target)
			} else {
				noscan_grow(mut cs.read_buf, cs.read_buf.cap * 2)
			}
		}
		spare := cs.read_buf.cap - cs.read_buf.len
		n := C.recv(fd, unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }, usize(spare), 0)
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break // burst fully drained
			}
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		if n == 0 {
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		unsafe {
			cs.read_buf.len += n
		}
		// Answer every complete request currently buffered; false ⇒ closed.
		if !drain_requests(request_handler, epoll_fd, fd, limits, active_conns, mut st, mut cs) {
			return
		}
		// After draining, read_buf holds at most one partial request.
		if cs.read_buf.len > req_cap {
			cs.write_buf << response.status_413_response
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return
		}
	}

	// Read-timeout bookkeeping: armed once when a request is mid-read,
	// cleared when the buffer holds no partial request.
	if cs.read_buf.len > 0 {
		if limits.read_timeout_ms > 0 && cs.read_deadline == 0 {
			cs.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			st.parked++
		}
	} else if cs.read_deadline != 0 {
		cs.read_deadline = 0
		st.parked--
	}

	// One send for the whole batch of responses (plus any deferred file body).
	if cs.write_buf.len > cs.write_off || cs.file_remaining > 0 {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
}

// drain_requests parses and answers every complete request in read_buf,
// appending responses to write_buf, then compacts the leftover partial bytes
// to the buffer front. Returns false if the connection was closed.
@[direct_array_access; manualfree]
fn drain_requests(request_handler core.RequestHandler, epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState) bool {
	mut pos := 0
	for pos < cs.read_buf.len {
		total := request_parser.frame_request_length_lim(cs.read_buf[pos..],
			limits.max_header_bytes, limits.max_body_bytes) or {
			// Append the canned error so it lands AFTER the responses already
			// batched for this burst, then flush and close.
			match err.code() {
				413 { cs.write_buf << response.status_413_response }
				431 { cs.write_buf << response.status_431_response }
				else { cs.write_buf << response.tiny_bad_request_response }
			}

			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
		if total < 0 {
			break // incomplete — wait for more bytes
		}
		req := cs.read_buf[pos..pos + total] // zero-copy view into the read buffer
		// A file deferred by an earlier request in this batch must be emitted (as
		// bytes, in order) BEFORE this next response is appended. This converts
		// the rare "pipelined response after a sendfile body" case to a buffered
		// copy of whatever file bytes remain — order preserved, sendfile skipped.
		if cs.file_remaining > 0 {
			append_file_region(mut cs.write_buf, cs.file_fd, cs.file_off, cs.file_remaining)
			cs.file_fd = -1
			cs.file_remaining = 0
		}
		request_handler(req, fd, mut cs.write_buf) or {
			cs.write_buf << response.tiny_bad_request_response
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
		// The handler may have appended headers to write_buf and handed its body
		// off for sendfile(2). Remember it; it streams after write_buf drains.
		if qf := core.take_queued_file() {
			cs.file_fd = qf.file_fd
			cs.file_off = qf.off
			cs.file_remaining = qf.len
		}
		pos += total
		// Peer pipelines requests but never reads responses: bail out before
		// the pending batch grows without bound.
		if cs.write_buf.len - cs.write_off > sm_max_pending_write {
			if flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) {
				close_conn(epoll_fd, fd, active_conns, mut st)
			}
			return false
		}
	}

	// Compact leftover partial bytes to the buffer start (keeps capacity).
	if pos > 0 {
		leftover := cs.read_buf.len - pos
		if leftover > 0 {
			unsafe {
				C.memmove(cs.read_buf.data, &u8(cs.read_buf.data) + pos, usize(leftover))
			}
		}
		unsafe {
			cs.read_buf.len = leftover
		}
	}
	return true
}

// park_write arms the write deadline (once) and subscribes the fd to EPOLLOUT so
// a batch that couldn't fully drain is resumed on the next writable edge.
@[inline]
fn park_write(epoll_fd int, fd int, limits core.Limits, mut st PlainState, mut cs ConnState) {
	if limits.write_timeout_ms > 0 && cs.write_deadline == 0 {
		cs.write_deadline = time.sys_mono_now() + u64(limits.write_timeout_ms) * 1_000_000
		st.parked++
	}
	epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLOUT | C.EPOLLET))
}

// append_file_region reads [off, off+len) from a borrowed file fd into `buf`.
// Used to materialize a deferred sendfile body into the response buffer when a
// pipelined response must follow it in order, and as the userspace fallback on
// backends/OSes that can't sendfile.
@[manualfree]
fn append_file_region(mut buf []u8, file_fd int, off i64, length i64) {
	if length <= 0 {
		return
	}
	start := buf.len
	unsafe { buf.grow_len(int(length)) }
	mut got := i64(0)
	for got < length {
		n := C.pread(file_fd, unsafe { &u8(buf.data) + start + int(got) }, usize(length - got),

			off + got)
		if n <= 0 {
			break // short read (file truncated mid-flight) — send what we got
		}
		got += i64(n)
	}
	if got < length {
		unsafe {
			buf.len = start + int(got)
		}
	}
}

// drain_file streams the connection's deferred file body to the socket with
// sendfile(2), advancing file_off/file_remaining. Returns:
//   1  fully sent (file_remaining == 0)
//   0  partial — EAGAIN, more to send on the next writable edge
//  -1  hard error — caller must close the connection
@[inline]
fn drain_file(fd int, mut cs ConnState) int {
	for cs.file_remaining > 0 {
		want := if cs.file_remaining > sm_sendfile_chunk {
			usize(sm_sendfile_chunk)
		} else {
			usize(cs.file_remaining)
		}
		sent := C.sendfile(fd, cs.file_fd, &cs.file_off, want)
		if sent > 0 {
			cs.file_remaining -= i64(sent)
			continue
		}
		if sent < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return 0
		}
		return -1 // sent == 0 (unexpected EOF) or a hard error
	}
	return 1
}

// flush_batch writes all pending response bytes then streams any deferred file
// body with sendfile(2), or parks the remainder for EPOLLOUT. The write buffer
// is reset (capacity kept) once everything is sent. Returns false if the
// connection was closed (callers must not touch it).
@[manualfree]
fn flush_batch(epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState) bool {
	// Phase 1: the buffered response bytes (status line, headers, small bodies).
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			park_write(epoll_fd, fd, limits, mut st, mut cs)
			return true // parked, still alive
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return false
	}
	// Phase 2: stream the deferred file body straight from the page cache.
	if cs.file_remaining > 0 {
		match drain_file(fd, mut cs) {
			0 {
				park_write(epoll_fd, fd, limits, mut st, mut cs)
				return true // parked mid-file, still alive
			}
			-1 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return false
			}
			else {}
		}
	}
	cs.write_buf.clear() // len = 0, capacity kept for the next batch
	cs.write_off = 0
	cs.file_fd = -1 // borrowed — never closed here
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	return true
}

// handle_writable_plain drains a parked batch when the socket is writable.
// Returns false if the connection was closed (the worker must then skip any
// further events for this fd in the current batch).
@[direct_array_access; manualfree]
fn handle_writable_plain(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) bool {
	if fd >= st.conns.len {
		return false
	}
	mut cs := st.conns[fd]
	if unsafe { cs == nil } {
		// EPOLLOUT is only armed after state exists; nil means a close raced
		// this event in the same batch.
		return false
	}
	if cs.write_off >= cs.write_buf.len && cs.file_remaining <= 0 {
		// Spurious wake — nothing parked; stop watching writability.
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET))
		return true
	}
	// Phase 1: finish the buffered bytes.
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return true // still parked
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return false
	}
	// Phase 2: finish the deferred file body.
	if cs.file_remaining > 0 {
		match drain_file(fd, mut cs) {
			0 {
				return true
			} // still parked mid-file
			-1 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return false
			}
			else {}
		}
	}
	cs.write_buf.clear()
	cs.write_off = 0
	cs.file_fd = -1 // borrowed — never closed here
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET)) // stop watching writability
	return true
}

// sweep_timeouts closes connections whose read/write deadline has passed.
// Called from the worker only when something is parked and a timeout is set,
// so it costs nothing on an idle/fast server.
@[direct_array_access; manualfree]
fn sweep_timeouts(epoll_fd int, active_conns &core.Counter, mut st PlainState) {
	now := time.sys_mono_now()
	for fd in 0 .. st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs == nil } {
			continue
		}
		if cs.read_deadline > 0 && now > cs.read_deadline {
			response.send_status_408_response(fd) // couldn't finish the request in time
			close_conn(epoll_fd, fd, active_conns, mut st)
		} else if cs.write_deadline > 0 && now > cs.write_deadline {
			close_conn(epoll_fd, fd, active_conns, mut st)
		}
	}
}

// close_conn frees the connection's buffers, clears its table slot and
// releases the fd. The ConnState struct itself is reclaimed by the GC once
// the slot no longer references it. NOT idempotent (release_conn always
// runs): every close site must make sure it is the only one closing — the
// bool returns of flush_batch / drain_requests / handle_writable_plain exist
// exactly for that.
@[direct_array_access; manualfree]
fn close_conn(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) {
	if fd < st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs != nil } {
			if cs.read_deadline != 0 {
				st.parked--
			}
			if cs.write_deadline != 0 {
				st.parked--
			}
			unsafe {
				cs.read_buf.free()
				cs.write_buf.free()
			}
			st.conns[fd] = unsafe { nil }
		}
	}
	release_conn(epoll_fd, fd, active_conns)
}
