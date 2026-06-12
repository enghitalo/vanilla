module backend_epoll

// Plain (non-TLS) connection state machine for the epoll worker.
//
// Resolves two Phase-1 blockers without slowing the common case:
//   • cross-edge reads  — a request split across network round-trips is buffered
//     per-fd and resumed on the next EPOLLIN (no premature close);
//   • EPOLLOUT writes   — a response that can't be sent in one go is parked and
//     drained on EPOLLOUT (backpressure), instead of being truncated/closed.
//
// Per-fd state lives in a per-worker `map[int]&ConnState` created ONLY for
// connections that actually block mid-read or mid-write. The fast path (request
// complete in one burst + response sent in one go) creates no entry and pays
// only a `conns.len > 0` check — so the 510k baseline is preserved.
import http_server.core
import http_server.epoll
import http_server.http1_1.request_parser
import http_server.http1_1.response
import sync.stdatomic
import time

#include <errno.h>
#include <sys/socket.h>
#include <sys/epoll.h>

// recv/send were inherited from http_server.c.v while this lived in that module;
// now in backend_epoll they must be declared here.
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int

const sm_max_request_bytes = 8 * 1024 * 1024

// ConnState is only allocated for a connection that blocks mid-transfer.
struct ConnState {
mut:
	read_buf       []u8 // partial request accumulated across epoll edges
	write_buf      []u8 // response remaining to be sent
	write_off      int
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read (read_timeout)
	write_deadline u64 // monotonic ns; >0 while a response is parked (write_timeout)
}

@[direct_array_access; manualfree]
fn handle_readable_plain(request_handler fn ([]u8, int) ![]u8, epoll_fd int, fd int, limits core.Limits, counter &core.Counter, active_conns &core.Counter, mut conns map[int]&ConnState) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	// Resume a partial read from a previous edge (only if any state exists).
	mut buf := []u8{len: 0, cap: 256}
	if conns.len > 0 {
		if mut cs := conns[fd] {
			if cs.read_buf.len > 0 {
				unsafe {
					buf = cs.read_buf // take ownership (move, no copy)
				}
				cs.read_buf = []u8{}
			}
		}
	}

	for {
		if buf.len == buf.cap {
			unsafe { buf.grow_cap(buf.cap) }
		}
		spare := buf.cap - buf.len
		n := C.recv(fd, unsafe { &u8(buf.data) + buf.len }, usize(spare), 0)
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				if buf.len == 0 {
					unsafe { buf.free() }
					return
				}
				save_read(mut conns, fd, buf, limits.read_timeout_ms) // partial — resume on next EPOLLIN
				return
			}
			unsafe { buf.free() }
			close_conn(epoll_fd, fd, active_conns, mut conns)
			return
		}
		if n == 0 {
			unsafe { buf.free() }
			close_conn(epoll_fd, fd, active_conns, mut conns)
			return
		}
		unsafe {
			buf.len += n
		}
		req_cap := if limits.max_request_bytes > 0 {
			limits.max_request_bytes
		} else {
			sm_max_request_bytes
		}
		if buf.len > req_cap {
			unsafe { buf.free() }
			response.send_status_413_response(fd)
			close_conn(epoll_fd, fd, active_conns, mut conns)
			return
		}
		total := request_parser.frame_request_length_lim(buf, limits.max_header_bytes,
			limits.max_body_bytes) or {
			unsafe { buf.free() }
			match err.code() {
				413 { response.send_status_413_response(fd) }
				431 { response.send_status_431_response(fd) }
				else { response.send_bad_request_response(fd) }
			}

			close_conn(epoll_fd, fd, active_conns, mut conns)
			return
		}
		if total >= 0 {
			if buf.len > total {
				buf.trim(total) // pipelined trailing bytes dropped (documented)
			}
			break
		}
		// incomplete — keep draining this burst
	}

	// Request complete — clear any read deadline on this connection.
	if conns.len > 0 {
		if mut cs := conns[fd] {
			cs.read_deadline = 0
		}
	}

	resp := request_handler(buf, fd) or {
		unsafe { buf.free() }
		response.send_bad_request_response(fd)
		close_conn(epoll_fd, fd, active_conns, mut conns)
		return
	}
	unsafe { buf.free() }
	send_or_park(epoll_fd, fd, limits, active_conns, mut conns, resp)
}

// send_or_park writes the whole response, or parks the remainder for EPOLLOUT.
// Takes ownership of `resp` (frees it when fully sent or parked-then-drained).
@[manualfree]
fn send_or_park(epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut conns map[int]&ConnState, resp []u8) {
	mut sent := 0
	for sent < resp.len {
		n := C.send(fd, unsafe { &u8(resp.data) + sent }, usize(resp.len - sent), C.MSG_NOSIGNAL)
		if n > 0 {
			sent += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			park_write(mut conns, fd, resp, sent, limits.write_timeout_ms) // ownership → parked
			epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLOUT | C.EPOLLET))
			return
		}
		unsafe { resp.free() }
		close_conn(epoll_fd, fd, active_conns, mut conns)
		return
	}
	unsafe { resp.free() }
	cleanup_if_idle(mut conns, fd) // keep-alive; drop empty state
}

// handle_writable_plain drains a parked response when the socket is writable.
@[manualfree]
fn handle_writable_plain(epoll_fd int, fd int, active_conns &core.Counter, mut conns map[int]&ConnState) {
	mut cs := conns[fd] or { return }
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		close_conn(epoll_fd, fd, active_conns, mut conns)
		return
	}
	unsafe { cs.write_buf.free() }
	cs.write_buf = []u8{}
	cs.write_off = 0
	epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN | C.EPOLLET)) // stop watching writability
	cleanup_if_idle(mut conns, fd)
}

fn save_read(mut conns map[int]&ConnState, fd int, buf []u8, read_timeout_ms int) {
	mut cs := conns[fd] or {
		nc := &ConnState{}
		conns[fd] = nc
		nc
	}
	cs.read_buf = buf
	// Set the deadline once, from when reading began (don't extend per fragment).
	if read_timeout_ms > 0 && cs.read_deadline == 0 {
		cs.read_deadline = time.sys_mono_now() + u64(read_timeout_ms) * 1_000_000
	}
}

fn park_write(mut conns map[int]&ConnState, fd int, resp []u8, sent int, write_timeout_ms int) {
	mut cs := conns[fd] or {
		nc := &ConnState{}
		conns[fd] = nc
		nc
	}
	cs.write_buf = resp
	cs.write_off = sent
	if write_timeout_ms > 0 {
		cs.write_deadline = time.sys_mono_now() + u64(write_timeout_ms) * 1_000_000
	}
}

// sweep_timeouts closes connections whose read/write deadline has passed. Called
// from the worker only when there are pending connections and a timeout is set,
// so it costs nothing on an idle/fast server.
@[manualfree]
fn sweep_timeouts(epoll_fd int, active_conns &core.Counter, mut conns map[int]&ConnState) {
	now := time.sys_mono_now()
	mut expired := []int{}
	mut timed_out_read := map[int]bool{}
	for fd, cs in conns {
		if cs.read_deadline > 0 && now > cs.read_deadline {
			expired << fd
			timed_out_read[fd] = true
		} else if cs.write_deadline > 0 && now > cs.write_deadline {
			expired << fd
		}
	}
	for fd in expired {
		if fd in timed_out_read {
			response.send_status_408_response(fd) // couldn't finish the request in time
		}
		close_conn(epoll_fd, fd, active_conns, mut conns)
	}
}

@[manualfree]
fn close_conn(epoll_fd int, fd int, active_conns &core.Counter, mut conns map[int]&ConnState) {
	if cs := conns[fd] {
		unsafe {
			if cs.read_buf.len > 0 {
				cs.read_buf.free()
			}
			if cs.write_buf.len > 0 {
				cs.write_buf.free()
			}
		}
		conns.delete(fd)
	}
	release_conn(epoll_fd, fd, active_conns)
}

fn cleanup_if_idle(mut conns map[int]&ConnState, fd int) {
	if conns.len == 0 {
		return
	}
	if cs := conns[fd] {
		if cs.read_buf.len == 0 && cs.write_buf.len == 0 {
			conns.delete(fd)
		}
	}
}
