// vtest build: linux
// core.Step.close: "whatever is in `res` is flushed, then the connection is
// closed" (vanilla#171), and so is every other "append, then close" the worker
// does itself. All the bytes must arrive, also when the socket cannot take
// them at once (EAGAIN), and then an orderly close, not a reset: a watch
// continuation's .close (single watch, two clients on one pipelined fd — also
// under backpressure — a
// client that sent more while the request was parked), a handler's (plain
// bytes, a core.queue_file region), a ConnHandler's, an error that ends a batch
// behind a large response, and a .suspend that armed no watch. While a close is
// pending nothing more is served, a read timeout does not cut a closing flush
// short, and a client that half-closes, even with a partial request buffered
// and a read timeout set, still gets everything.
//
// The responses that must survive backpressure are 512 KiB (the first flush
// gets at most ~80 KiB out on main), sent through a client socket whose
// SO_SNDBUF is pinned to 4 KiB, so the first send() returns EAGAIN long before
// they are out. Takeover is inert under tcc (#173): that check runs with gcc,
// as CI does. io_uring runs the checks for the paths this change touches on
// it (its resume arms, and the closing release that drains unread input): its
// rings leak across servers in one process (#153), so it keeps to five.
import os
import server
import core
import sync.stdatomic
import time
import vtest

#include <sys/socket.h>
#include <sys/timerfd.h>

fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int
fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int

const cf_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const cf_second_req = 'GET /second HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
// A bare LF ends the request line: the framer rejects it with a 400.
const cf_bad_req = 'GET /bad HTTP/1.1\nHost: x\r\n\r\n'.bytes()
const cf_ok_close = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'.bytes()
const cf_second = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nsecond'.bytes()
const cf_big_len = 512 * 1024
const cf_big_close_head = 'HTTP/1.1 200 OK\r\nContent-Length: 524288\r\nConnection: close\r\n\r\n'.bytes()
const cf_big_keep_head = 'HTTP/1.1 200 OK\r\nContent-Length: 524288\r\nConnection: keep-alive\r\n\r\n'.bytes()
const cf_upgrade_req = 'GET /up HTTP/1.1\r\nHost: x\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()
const cf_switching = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()

// cf_one_close is the one-connection script: a request, its response, then
// the server's close.
const cf_one_close = vtest.Script{
	rounds:   [vtest.Round{
		send: cf_req
	}]
	then_eof: true
}

// cf_small_sndbuf pins fd's send buffer to 4 KiB.
fn cf_small_sndbuf(fd int) {
	sz := i32(4096)
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_SNDBUF, &sz, u32(sizeof(i32)))
}

// cf_append_big appends a 512 KiB response: `head`, then the body.
fn cf_append_big(mut out []u8, head []u8) {
	out << head
	start := out.len
	unsafe {
		out.grow_len(cf_big_len)
		vmemset(&u8(out.data) + start, `a`, cf_big_len)
	}
}

// cf_assert_big returns an error unless connection c received exactly one
// `head` + 512 KiB response, then an orderly close. It returns instead of
// asserting so that the caller's defers run when it fails (docs/VTEST.md).
fn cf_assert_big(backend server.IOBackend, what string, c vtest.ConnResult, head []u8) ! {
	want := head.len + cf_big_len
	if c.connect_err != '' {
		return error(c.connect_err)
	}
	if c.unmet || c.raw.len != want || c.frames.len != 1 || c.frames[0].len != want {
		return error('${backend} ${what}: ${c.raw.len} of ${want} bytes in ${c.frames.len} responses before the close')
	}
	if !c.eof || c.reset {
		return error('${backend} ${what}: eof=${c.eof} reset=${c.reset}: no orderly close after the response')
	}
}

// --- a watch continuation's .close -------------------------------------------

// cf_park parks every request on a socketpair that is readable at once, so
// `cont` runs on the next loop pass. The payload is the write end, which the
// continuation closes with the read end.
fn cf_park(cont core.WakeFn) core.Handler {
	return fn [cont] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		mut sv := [2]i32{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) != 0 {
			return .close
		}
		b := [u8(`x`)]!
		C.write(int(sv[1]), &b[0], 1)
		event_loop.watch_fd(int(sv[0]), .readable, cont, voidptr(usize(u32(sv[1]))))
		return .suspend
	}
}

fn cf_answer_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	C.close(ready_fd)
	C.close(int(u32(usize(watch_payload))))
	out << cf_ok_close
	return .close
}

fn cf_answer_big_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	C.close(ready_fd)
	C.close(int(u32(usize(watch_payload))))
	cf_small_sndbuf(event_loop.client_fd)
	cf_append_big(mut out, cf_big_close_head)
	return .close
}

fn check_resume_close(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_park(cf_answer_close)
		workers:         1
	}, [cf_one_close])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: EOF before the continuation response: .close dropped it'
	assert c.frames.len == 1
	assert c.frames[0] == cf_ok_close
	assert c.eof && !c.reset
	assert out.inflight_after == 0
	assert out.active_after == 0
}

fn check_resume_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_park(cf_answer_big_close)
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'continuation', out.conns[0], cf_big_close_head)!
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

fn cf_shared(cont core.WakeFn) core.Handler {
	return fn [cont] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		mut sh := unsafe { &CfShared(worker_state) }
		event_loop.watch_fd_persistent(sh.rfd, .readable, cont, unsafe { nil })
		sh.parked++
		if sh.parked == 2 {
			b := [u8(`x`)]!
			C.write(sh.wfd, &b[0], 1)
		}
		return .suspend
	}
}

fn cf_shared_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // the first head consumes the byte; later heads get EAGAIN
	out << cf_ok_close
	return .close
}

// cf_shared_big_close answers each pipelined head with the 512 KiB response, so
// the first client is still closing (its flush parked) while the drain moves on
// to the second.
fn cf_shared_big_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	cf_small_sndbuf(event_loop.client_fd)
	cf_append_big(mut out, cf_big_close_head)
	return .close
}

fn check_pipelined_resume_close(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_shared(cf_shared_close)
		make_state:      cf_shared_state
		workers:         1 // both clients must park on the SAME worker's fd
	}, [cf_one_close, cf_one_close])!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert !c.unmet, '${backend}: client ${i}: EOF before its response: the pipelined .close dropped it'
		assert c.frames.len == 1
		assert c.frames[0] == cf_ok_close
		assert c.eof && !c.reset
	}
	assert out.inflight_after == 0
	assert out.active_after == 0
}

fn check_pipelined_resume_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_shared(cf_shared_big_close)
		make_state:      cf_shared_state
		workers:         1
	}, [cf_one_close, cf_one_close])!
	cf_assert_big(backend, 'pipelined client 0', out.conns[0], cf_big_close_head)!
	cf_assert_big(backend, 'pipelined client 1', out.conns[1], cf_big_close_head)!
	assert out.active_after == 0
}

// The client sends a second request while the first is parked: nobody reads it
// (a parked connection only peeks; io_uring arms no recv), so a close that does
// not drain it first is a reset. The handler parks for 100 ms and counts the
// park, so the test sends the second request only once the first is parked.
fn cf_delay_handler(parked &core.Counter) core.Handler {
	return fn [parked] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK)
		mut spec := [4]i64{} // itimerspec: it_interval{sec, nsec}, it_value{sec, nsec}
		spec[3] = 100 * 1_000_000
		C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
		event_loop.watch_fd(tfd, .readable, cf_delay_close, unsafe { nil })
		stdatomic.add_i64(&parked.n, 1)
		return .suspend
	}
}

fn cf_delay_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	C.close(ready_fd)
	out << cf_ok_close
	return .close
}

fn cf_never(acc []u8) bool {
	return false
}

fn check_resume_close_after_request_during_park(backend server.IOBackend) ! {
	parked := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_delay_handler(parked)
		workers:         1
	})!
	defer {
		h.stop()
	}
	first := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: cf_req
			want: 0
		}]
	}])!
	for i := 0; stdatomic.load_i64(&parked.n) == 0; i++ {
		assert i < 5000, '${backend}: the first request never parked'
		time.sleep(time.millisecond)
	}
	out := h.send(first.group, cf_second_req, cf_never)! // until the server closes
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: ${c.frames.len} responses'
	assert c.frames[0] == cf_ok_close
	assert c.eof
	assert !c.reset, '${backend}: the close was a reset (the request sent during the park was left unread)'
}

// --- a handler's .close ----------------------------------------------------------

// /second answers keep-alive; anything else gets the 512 KiB response and .close.
fn cf_big_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req == cf_second_req {
		res << cf_second
		return .done
	}
	cf_small_sndbuf(client_fd)
	cf_append_big(mut res, cf_big_close_head)
	return .close
}

fn check_handler_close_backpressure(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_handler
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'handler', out.conns[0], cf_big_close_head)!
	assert out.active_after == 0
}

// cf_file is a 512 KiB file of `f` bytes, unlinked right away: the fd keeps it
// alive, and nothing is left behind whatever the check does.
fn cf_file(tag string) !os.File {
	path := os.join_path(os.temp_dir(), 'vanilla_close_flush_${tag}_${os.getpid()}.bin')
	os.write_file_array(path, []u8{len: cf_big_len, init: `f`})!
	f := os.open(path)!
	os.rm(path)!
	return f
}

// The body is a core.queue_file region (sent with sendfile(2) after the head),
// or, where queue_file refuses (io_uring, tcc builds), the same bytes read
// into `res`. Every accepted hand-off is counted.
fn cf_file_handler(file_fd int, head []u8, step core.Step, accepted &core.Counter) core.Handler {
	return fn [file_fd, head, step, accepted] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		cf_small_sndbuf(client_fd)
		res << head
		if core.queue_file(file_fd, 0, cf_big_len) {
			stdatomic.add_i64(&accepted.n, 1)
		} else {
			core.append_file_region(mut res, file_fd, 0, cf_big_len)
		}
		return step
	}
}

// cf_handoffs_wanted is the number of queue_file hand-offs the worker must
// accept for `n` handler calls: the epoll plain worker takes them, except in a
// tcc build, where the slot is compiled inert.
fn cf_handoffs_wanted(backend server.IOBackend, n i64) i64 {
	$if tinyc {
		return 0
	}
	return if backend == .epoll { n } else { 0 }
}

fn check_handler_close_file_backpressure(backend server.IOBackend) ! {
	mut f := cf_file('close')!
	defer {
		f.close()
	}
	accepted := &core.Counter{}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_file_handler(f.fd, cf_big_close_head, .close, accepted)
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'handler file region', out.conns[0], cf_big_close_head)!
	c := out.conns[0]
	assert c.frames[0][cf_big_close_head.len..] == []u8{len: cf_big_len, init: `f`}
	assert stdatomic.load_i64(&accepted.n) == cf_handoffs_wanted(backend, 1)
	assert out.active_after == 0
}

// With read_timeout_ms set, the request's read deadline must not cut the
// closing flush short: only the write deadline bounds it.
fn check_handler_close_with_read_timeout(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 50 // the sweep runs every 25 ms; the reply takes longer
		}
	}, [cf_one_close])!
	cf_assert_big(backend, 'handler .close under a read timeout', out.conns[0], cf_big_close_head)!
	assert out.active_after == 0
}

// A request that arrives while the close is pending is not answered: after
// the head of the 512 KiB response, the client sends /second; it must get the
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
	cf_assert_big(backend, 'request after .close', out.conns[0], cf_big_close_head)!
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
	cf_assert_big(backend, 'half-closed peer', out.conns[0], cf_big_close_head)!
	assert out.active_after == 0
}

// --- the worker's own "append, then close" ----------------------------------------

// A request the framer rejects ends the batch with a 400 behind a pipelined
// 512 KiB response whose body is a queue_file region: the whole response, then
// the 400 (after the body, not inside it), then the close.
fn check_error_close_behind_large_response(backend server.IOBackend) ! {
	mut f := cf_file('error')!
	defer {
		f.close()
	}
	accepted := &core.Counter{}
	mut burst := []u8{cap: cf_req.len + cf_bad_req.len}
	burst << cf_req
	burst << cf_bad_req
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_file_handler(f.fd, cf_big_keep_head, .done, accepted)
		workers:         1
	}, [
		vtest.Script{
			rounds:   [vtest.Round{
				send: burst
				want: 2
			}]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: EOF after ${c.raw.len} bytes: the 400 close cut the response short'
	assert c.frames.len == 2
	assert c.frames[0].len == cf_big_keep_head.len + cf_big_len
	assert c.frames[0][cf_big_keep_head.len..] == []u8{len: cf_big_len, init: `f`}, '${backend}: the body is not the file (the 400 landed inside it?)'
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 400')
	assert c.eof && !c.reset
	assert stdatomic.load_i64(&accepted.n) == cf_handoffs_wanted(backend, 1)
	assert out.active_after == 0
}

// A handler that returns .suspend without arming a watch is answered with what
// it appended, then closed: all of it.
fn cf_suspend_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	cf_small_sndbuf(client_fd)
	cf_append_big(mut res, cf_big_close_head)
	return .suspend
}

fn check_suspend_without_watch_flushes(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_suspend_handler
		workers:         1
	}, [cf_one_close])!
	cf_assert_big(backend, 'suspend without a watch', out.conns[0], cf_big_close_head)!
	assert out.active_after == 0
}

// A client sends a request plus the start of another, then half-closes, and
// reads the 512 KiB keep-alive response slowly. The partial request can never
// complete, so its read deadline must not cut the reply short.
fn cf_big_keep_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	cf_small_sndbuf(client_fd)
	cf_append_big(mut res, cf_big_keep_head)
	return .done
}

fn check_half_close_with_partial_request(backend server.IOBackend) ! {
	mut burst := []u8{cap: cf_req.len + 8}
	burst << cf_req
	burst << 'GET /pa'.bytes()
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         cf_big_keep_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 50 // the sweep runs every 25 ms; the reply takes longer
		}
	}, [
		vtest.Script{
			rounds:   [vtest.Round{
				send: burst
			}]
			shut_wr:  true
			then_eof: true
		},
	])!
	cf_assert_big(backend, 'half-close with a partial request', out.conns[0], cf_big_keep_head)!
	assert out.active_after == 0
}

// --- a ConnHandler's .close ------------------------------------------------------

// After the upgrade, any byte gets the 512 KiB blob and .close.
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
	cf_append_big(mut out, cf_big_close_head)
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
	want := cf_switching.len + cf_big_close_head.len + cf_big_len
	assert c.connect_err == '', c.connect_err
	assert c.raw.len == want, '${backend} ConnHandler: ${c.raw.len} of ${want} bytes before the close'
	assert c.eof && !c.reset
	assert out.active_after == 0
}

// --- epoll -------------------------------------------------------------------------

fn test_epoll_resume_close() ! {
	check_resume_close(.epoll)!
}

fn test_epoll_resume_close_backpressure() ! {
	check_resume_close_backpressure(.epoll)!
}

fn test_epoll_pipelined_resume_close() ! {
	check_pipelined_resume_close(.epoll)!
}

fn test_epoll_pipelined_resume_close_backpressure() ! {
	check_pipelined_resume_close_backpressure(.epoll)!
}

fn test_epoll_resume_close_after_request_during_park() ! {
	check_resume_close_after_request_during_park(.epoll)!
}

fn test_epoll_handler_close_backpressure() ! {
	check_handler_close_backpressure(.epoll)!
}

fn test_epoll_handler_close_with_read_timeout() ! {
	check_handler_close_with_read_timeout(.epoll)!
}

fn test_epoll_handler_close_file_backpressure() ! {
	check_handler_close_file_backpressure(.epoll)!
}

fn test_epoll_close_serves_nothing_more() ! {
	check_close_serves_nothing_more(.epoll)!
}

fn test_epoll_close_half_closed_peer() ! {
	check_close_half_closed_peer(.epoll)!
}

fn test_epoll_error_close_behind_large_response() ! {
	check_error_close_behind_large_response(.epoll)!
}

fn test_epoll_suspend_without_watch_flushes() ! {
	check_suspend_without_watch_flushes(.epoll)!
}

fn test_epoll_half_close_with_partial_request() ! {
	check_half_close_with_partial_request(.epoll)!
}

fn test_epoll_takeover_close_backpressure() ! {
	$if tinyc {
		eprintln('[test] takeover is inert under tcc; skipping')
		return
	}
	check_takeover_close_backpressure(.epoll)!
}

// --- io_uring ----------------------------------------------------------------------

fn iou_skip() bool {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring_setup blocked (sandboxed runner or leaked rings, #153); skipping')
		return true
	}
	return false
}

fn test_iouring_resume_close() ! {
	if iou_skip() {
		return
	}
	check_resume_close(.io_uring)!
}

fn test_iouring_resume_close_backpressure() ! {
	if iou_skip() {
		return
	}
	check_resume_close_backpressure(.io_uring)!
}

fn test_iouring_pipelined_resume_close() ! {
	if iou_skip() {
		return
	}
	check_pipelined_resume_close(.io_uring)!
}

fn test_iouring_resume_close_after_request_during_park() ! {
	if iou_skip() {
		return
	}
	check_resume_close_after_request_during_park(.io_uring)!
}

fn test_iouring_close_serves_nothing_more() ! {
	if iou_skip() {
		return
	}
	check_close_serves_nothing_more(.io_uring)!
}
