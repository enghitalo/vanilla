// core.Step.close: "whatever is in `res` is flushed, then the connection is
// closed" (vanilla#171). Every .close arm must deliver ALL the bytes before
// the close, also when the socket cannot take them at once (EAGAIN): a watch
// continuation's (single watch, and two clients on one pipelined fd), a
// handler's (plain bytes, and a core.queue_file region), and a ConnHandler's.
// While a close is pending nothing more is served, and a client that
// half-closes still gets everything.
//
// The responses that must survive backpressure are 6 MiB (under the 8 MiB
// pending-write cap), sent through a client socket whose SO_SNDBUF is pinned
// to 4 KiB, so the first send() returns EAGAIN long before they are out.
//
// Standalone and Linux-only, like epoll_timeouts_test.v (SOCK_NONBLOCK, the
// io_uring backend). Takeover is inert under tcc (#173): that check runs with
// gcc, as CI does.
import os
import server
import core
import vtest

$if linux {
	#include <sys/socket.h>
}

fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int

const cf_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const cf_second_req = 'GET /second HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const cf_ok_close = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'.bytes()
const cf_second = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nsecond'.bytes()
const cf_big_len = 6 * 1024 * 1024
const cf_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: 6291456\r\nConnection: close\r\n\r\n'.bytes()
const cf_upgrade_req = 'GET /up HTTP/1.1\r\nHost: x\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()
const cf_switching = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()

// cf_small_sndbuf pins fd's send buffer to 4 KiB.
fn cf_small_sndbuf(fd int) {
	sz := i32(4096)
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_SNDBUF, &sz, u32(sizeof(i32)))
}

// cf_append_big appends the 6 MiB response: head, then the body.
fn cf_append_big(mut out []u8) {
	out << cf_big_head
	start := out.len
	unsafe {
		out.grow_len(cf_big_len)
		vmemset(&u8(out.data) + start, `a`, cf_big_len)
	}
}

// cf_ready_pair returns a socketpair whose first end is readable at once, both
// ends packed into one payload word (low 32 bits, high 32 bits); nil on
// failure.
fn cf_ready_pair() voidptr {
	mut sv := [2]i32{}
	if C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) != 0 {
		return unsafe { nil }
	}
	b := [u8(`x`)]!
	C.write(int(sv[1]), &b[0], 1)
	return voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
}

fn cf_pair_lo(pair voidptr) int {
	return int(u32(u64(usize(pair)) & 0xffff_ffff))
}

fn cf_close_pair(pair voidptr) {
	C.close(cf_pair_lo(pair))
	C.close(int(u32(u64(usize(pair)) >> 32)))
}

// cf_one_close is the one-connection script: a request, its response, then
// the server's close.
const cf_one_close = vtest.Script{
	rounds:   [vtest.Round{
		send: cf_req
	}]
	then_eof: true
}

// cf_assert_big checks that connection c received exactly the head + 6 MiB
// response, then the close.
fn cf_assert_big(backend server.IOBackend, what string, c vtest.ConnResult) {
	want := cf_big_head.len + cf_big_len
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend} ${what}: EOF after ${c.raw.len} of ${want} bytes: the close did not wait for the parked flush'
	assert c.frames.len == 1, '${backend} ${what}: ${c.frames.len} responses'
	assert c.frames[0].len == want
	assert c.raw.len == want, '${backend} ${what}: ${c.raw.len - want} bytes past the response'
	assert c.eof
}

// --- a watch continuation's .close ---------------------------------------------

// The continuation runs once its socketpair is readable (at once) and answers
// with .close.
fn cf_park_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	pair := cf_ready_pair()
	if pair == unsafe { nil } {
		return .close
	}
	event_loop.watch_fd(cf_pair_lo(pair), .readable, cf_answer_close, pair)
	return .suspend
}

fn cf_answer_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	cf_close_pair(watch_payload)
	out << cf_ok_close
	return .close
}

fn check_resume_close(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_park_handler
		workers:         1
	}, [cf_one_close])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: EOF before the continuation response: .close dropped it'
	assert c.frames.len == 1
	assert c.frames[0] == cf_ok_close
	assert c.eof
	assert out.inflight_after == 0
	assert out.active_after == 0
}

// Two clients park on the worker's one socketpair (watch_fd_persistent), so
// the watch becomes a pipelined queue; the second parker makes it readable,
// and both continuations run in one drain.
struct CfShared {
mut:
	rfd    int
	wfd    int
	parked int
}

fn cf_shared_state() voidptr {
	mut sv := [2]i32{}
	C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0])
	return &CfShared{
		rfd: int(sv[0])
		wfd: int(sv[1])
	}
}

fn cf_shared_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut sh := unsafe { &CfShared(worker_state) }
	event_loop.watch_fd_persistent(sh.rfd, .readable, cf_shared_close, unsafe { nil })
	sh.parked++
	if sh.parked == 2 {
		b := [u8(`x`)]!
		C.write(sh.wfd, &b[0], 1)
	}
	return .suspend
}

fn cf_shared_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // the first head consumes the byte; later heads get EAGAIN
	out << cf_ok_close
	return .close
}

fn check_pipelined_resume_close(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_shared_handler
		make_state:      cf_shared_state
		workers:         1 // both clients must park on the SAME worker's fd
	}, [cf_one_close, cf_one_close])!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert !c.unmet, '${backend}: client ${i}: EOF before its response: the pipelined .close dropped it'
		assert c.frames.len == 1
		assert c.frames[0] == cf_ok_close
		assert c.eof
	}
	assert out.inflight_after == 0
	assert out.active_after == 0
}

fn cf_park_big_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	pair := cf_ready_pair()
	if pair == unsafe { nil } {
		return .close
	}
	event_loop.watch_fd(cf_pair_lo(pair), .readable, cf_answer_big_close, pair)
	return .suspend
}

fn cf_answer_big_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	cf_close_pair(watch_payload)
	cf_small_sndbuf(event_loop.client_fd)
	cf_append_big(mut out)
	return .close
}

fn check_resume_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_park_big_handler
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'continuation', out.conns[0])
	assert out.active_after == 0
}

// --- a handler's .close ----------------------------------------------------------

// cf_is_second reports whether req is cf_second_req.
fn cf_is_second(req []u8) bool {
	if req.len != cf_second_req.len {
		return false
	}
	for i in 0 .. req.len {
		if req[i] != cf_second_req[i] {
			return false
		}
	}
	return true
}

// /second answers keep-alive; anything else gets the 6 MiB response and .close.
fn cf_big_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if cf_is_second(req) {
		res << cf_second
		return .done
	}
	cf_small_sndbuf(client_fd)
	cf_append_big(mut res)
	return .close
}

fn check_handler_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_handler
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'handler', out.conns[0])
	assert out.active_after == 0
}

// The body is a core.queue_file region (sent with sendfile(2) after the head),
// or, where queue_file refuses (io_uring, tcc builds), the same bytes read
// into `res`.
fn cf_file_handler(file_fd int) core.Handler {
	return fn [file_fd] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		cf_small_sndbuf(client_fd)
		res << cf_big_head
		if !core.queue_file(file_fd, 0, cf_big_len) {
			core.append_file_region(mut res, file_fd, 0, cf_big_len)
		}
		return .close
	}
}

fn check_handler_close_file_backpressure(backend server.IOBackend) ! {
	path := os.join_path(os.temp_dir(), 'vanilla_close_flush_${os.getpid()}.bin')
	os.write_file_array(path, []u8{len: cf_big_len, init: `f`})!
	mut f := os.open(path)!
	defer {
		f.close()
		os.rm(path) or {}
	}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_file_handler(f.fd)
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'handler file region', out.conns[0])
	assert out.active_after == 0
}

// A request that arrives while the close is pending is not answered: after
// the head of the 6 MiB response, the client sends /second; it must get the
// response alone, then the close.
fn check_close_serves_nothing_more(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_handler
		workers:         1
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send:  cf_req
					until: vtest.headers_seen
				},
				vtest.Round{
					send: cf_second_req
					want: 0
				},
			]
			then_eof: true
		},
	])!
	cf_assert_big(backend, 'request after .close', out.conns[0])
	assert out.active_after == 0
}

// A client that half-closes (SHUT_WR) right after its request still reads: the
// EOF must not cut the pending close short (RFC 9112 §9.6).
fn check_close_half_closed_peer(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_handler
		workers:         1
	}, [
		vtest.Script{
			rounds:   [vtest.Round{
				send: cf_req
			}]
			shut_wr:  true
			then_eof: true
		},
	])!
	cf_assert_big(backend, 'half-closed peer', out.conns[0])
	assert out.active_after == 0
}

// --- a ConnHandler's .close --------------------------------------------------------

// After the upgrade, any byte gets the 6 MiB blob and .close.
fn cf_upgrade_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !core.queue_takeover(cf_blob_conn, unsafe { nil }) {
		res << cf_ok_close // not takeover-capable: the check then fails on the missing 101
		return .close
	}
	res << cf_switching
	return .done
}

fn cf_blob_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	if buf.len == 0 {
		return 0, core.Step.done
	}
	cf_small_sndbuf(client_fd)
	cf_append_big(mut out)
	return buf.len, core.Step.close
}

fn check_takeover_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_upgrade_handler
		workers:         1
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send:  cf_upgrade_req
					until: vtest.count('101 Switching Protocols', 1)
				},
				vtest.Round{
					send: 'x'.bytes()
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	want := cf_switching.len + cf_big_head.len + cf_big_len
	assert c.connect_err == '', c.connect_err
	assert c.raw.len == want, '${backend} ConnHandler: ${c.raw.len} of ${want} bytes before the close'
	assert c.eof
	assert out.active_after == 0
}

// --- epoll -------------------------------------------------------------------------

fn test_epoll_resume_close() ! {
	$if linux {
		check_resume_close(.epoll)!
	}
}

fn test_epoll_pipelined_resume_close() ! {
	$if linux {
		check_pipelined_resume_close(.epoll)!
	}
}

fn test_epoll_resume_close_backpressure() ! {
	$if linux {
		check_resume_close_backpressure(.epoll)!
	}
}

fn test_epoll_handler_close_backpressure() ! {
	$if linux {
		check_handler_close_backpressure(.epoll)!
	}
}

fn test_epoll_handler_close_file_backpressure() ! {
	$if linux {
		check_handler_close_file_backpressure(.epoll)!
	}
}

fn test_epoll_close_serves_nothing_more() ! {
	$if linux {
		check_close_serves_nothing_more(.epoll)!
	}
}

fn test_epoll_close_half_closed_peer() ! {
	$if linux {
		check_close_half_closed_peer(.epoll)!
	}
}

fn test_epoll_takeover_close_backpressure() ! {
	$if linux {
		$if tinyc {
			eprintln('[test] takeover is inert under tcc; skipping')
			return
		}
		check_takeover_close_backpressure(.epoll)!
	}
}

// --- io_uring ----------------------------------------------------------------------

fn iou_skip() bool {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return true
		}
	}
	return false
}

fn test_iouring_resume_close() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_resume_close(.io_uring)!
	}
}

fn test_iouring_pipelined_resume_close() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_pipelined_resume_close(.io_uring)!
	}
}

fn test_iouring_resume_close_backpressure() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_resume_close_backpressure(.io_uring)!
	}
}

fn test_iouring_handler_close_backpressure() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_handler_close_backpressure(.io_uring)!
	}
}

fn test_iouring_handler_close_file_backpressure() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_handler_close_file_backpressure(.io_uring)!
	}
}

fn test_iouring_close_serves_nothing_more() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_close_serves_nothing_more(.io_uring)!
	}
}

fn test_iouring_close_half_closed_peer() ! {
	$if linux {
		if iou_skip() {
			return
		}
		check_close_half_closed_peer(.io_uring)!
	}
}
