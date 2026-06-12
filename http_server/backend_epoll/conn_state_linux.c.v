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
//     drained on EPOLLOUT (write_timeout guarded), never truncated.
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

// recv/send were inherited from http_server.c.v while this lived in that module;
// now in backend_epoll they must be declared here.
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.memmove(__dest voidptr, __src voidptr, __n usize) voidptr

const sm_max_request_bytes = 8 * 1024 * 1024
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
		for st.conns.len < new_len {
			st.conns << &ConnState(unsafe { nil })
		}
	}
	if unsafe { st.conns[fd] == nil } {
		st.conns[fd] = &ConnState{
			read_buf:  []u8{len: 0, cap: read_buf_cap}
			write_buf: []u8{len: 0, cap: write_buf_cap}
		}
	}
	return st.conns[fd]
}

// handle_readable_plain drains the socket into the connection's persistent
// read buffer, answers EVERY complete request in it (pipelining), compacts
// the leftover, and flushes all responses in one batched send.
@[direct_array_access; manualfree]
fn handle_readable_plain(request_handler fn ([]u8, int, mut []u8) !, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut st PlainState) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	mut cs := state_for(mut st, fd)

	// Drain this edge into the persistent buffer (edge-triggered: read to EAGAIN).
	req_cap := if limits.max_request_bytes > 0 {
		limits.max_request_bytes
	} else {
		sm_max_request_bytes
	}
	for {
		if cs.read_buf.len == cs.read_buf.cap {
			unsafe { cs.read_buf.grow_cap(cs.read_buf.cap) }
		}
		spare := cs.read_buf.cap - cs.read_buf.len
		n := C.recv(fd, unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }, usize(spare),
			0)
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
		if cs.read_buf.len > req_cap {
			response.send_status_413_response(fd)
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
	}

	// Answer every complete pipelined request in the buffer.
	mut pos := 0
	for pos < cs.read_buf.len {
		total := request_parser.frame_request_length_lim(cs.read_buf[pos..], limits.max_header_bytes,
			limits.max_body_bytes) or {
			flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs) // drain what was answered
			match err.code() {
				413 { response.send_status_413_response(fd) }
				431 { response.send_status_431_response(fd) }
				else { response.send_bad_request_response(fd) }
			}
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		if total < 0 {
			break // incomplete — wait for the next edge
		}
		req := cs.read_buf[pos..pos + total] // zero-copy view into the read buffer
		request_handler(req, fd, mut cs.write_buf) or {
			cs.write_buf << response.tiny_bad_request_response
			flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
			close_conn(epoll_fd, fd, active_conns, mut st)
			return
		}
		pos += total
	}

	// Compact leftover partial bytes to the buffer start (keeps capacity).
	leftover := cs.read_buf.len - pos
	if pos > 0 {
		if leftover > 0 {
			unsafe {
				C.memmove(cs.read_buf.data, &u8(cs.read_buf.data) + pos, usize(leftover))
			}
		}
		unsafe {
			cs.read_buf.len = leftover
		}
	}

	// Read-timeout bookkeeping: armed once when a request is mid-read,
	// cleared when the buffer holds no partial request.
	if leftover > 0 {
		if limits.read_timeout_ms > 0 && cs.read_deadline == 0 {
			cs.read_deadline = time.sys_mono_now() + u64(limits.read_timeout_ms) * 1_000_000
			st.parked++
		}
	} else if cs.read_deadline != 0 {
		cs.read_deadline = 0
		st.parked--
	}

	// One send for the whole batch of responses.
	if cs.write_buf.len > cs.write_off {
		flush_batch(epoll_fd, fd, limits, active_conns, mut st, mut cs)
	}
}

// flush_batch writes all pending response bytes, or parks the remainder for
// EPOLLOUT. The write buffer is reset (capacity kept) once fully sent.
@[manualfree]
fn flush_batch(epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState) {
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off }, usize(cs.write_buf.len - cs.write_off),
			C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			if limits.write_timeout_ms > 0 && cs.write_deadline == 0 {
				cs.write_deadline = time.sys_mono_now() +
					u64(limits.write_timeout_ms) * 1_000_000
				st.parked++
			}
			epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLOUT | C.EPOLLET))
			return
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return
	}
	cs.write_buf.clear() // len = 0, capacity kept for the next batch
	cs.write_off = 0
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
}

// handle_writable_plain drains a parked batch when the socket is writable.
@[direct_array_access; manualfree]
fn handle_writable_plain(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) {
	if fd >= st.conns.len {
		return
	}
	mut cs := st.conns[fd]
	if unsafe { cs == nil } {
		return
	}
	if cs.write_off >= cs.write_buf.len {
		// Spurious wake — nothing parked; stop watching writability.
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET))
		return
	}
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off }, usize(cs.write_buf.len - cs.write_off),
			C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return
	}
	cs.write_buf.clear()
	cs.write_off = 0
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET)) // stop watching writability
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
// the slot no longer references it.
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
			st.conns[fd] = &ConnState(unsafe { nil })
		}
	}
	release_conn(epoll_fd, fd, active_conns)
}
