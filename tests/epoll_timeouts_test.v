// vtest build: linux
// Connection-reaping edge cases on the plain epoll worker that
// backend_behaviors_test.v does not cover: what the read/idle deadlines must
// NOT reap (a taken-over connection, also once a frame split across bursts
// completes; a parked request; a request streaming from a watch), a suspended
// request that can never resume (closed, not leaked), and the flows that keep
// a request open across edges (Expect: 100-continue, a streamed > 1 MiB
// upload) while those deadlines are armed. Plus a connect storm whose
// requests arrive with the connection — the accept-time EPOLLOUT birth edge
// must still serve the EPOLLIN half. Also: a pipelined request's own read
// deadline; no 408 inside a pending response, yet a stalled streamed upload
// still gets its 408, also after Expect: 100-continue; streams whose clients
// all vanish at once are released exactly once; an app's fd that a finished
// watch left registered is never adopted as a connection, nor spun on once
// it reads EOF (a pooled fd whose upstream went away); and a request that
// parks on its own client's writability leaves the connection serving.
// The checks that need no watch reactor or takeover also run on the poll
// backend (`-d vanilla_poll`), which shares the 408 / fresh-deadline rules.
//
// vtest contract (docs/VTEST.md): the only clocks are the server's Limits. A
// "pause longer than idle" is produced by a WITNESS connection the server
// itself reaps by a deadline at least as long as the idle budget: when
// fire(witness) returns, that much server time has passed while the
// connection under test sat still — no client sleeps, no stopwatch deadlines.
import os
import server
import core
import sync.stdatomic
import time
import vtest

$if linux {
	#include <sys/timerfd.h>
	#include <sys/socket.h>
}

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.clock() i64 // this process's CPU time, in CLOCKS_PER_SEC (1e6 on POSIX) units

const et_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const et_delay_req = 'GET /delay HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_delayed = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\ndelayed'.bytes()

// /stream answers a Content-Length body in et_ticks pieces, one per timer tick:
// the connection streams from a watch (flush, re-park) for et_ticks *
// et_tick_ms — several idle budgets — before the response completes.
const et_ticks = 6
const et_tick_ms = 150
const et_stream_req = 'GET /stream HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_stream_head = 'HTTP/1.1 200 OK\r\nContent-Length: 30\r\nConnection: keep-alive\r\n\r\n'.bytes() // 30 = et_ticks * et_tick.len
const et_tick = 'tick\n'.bytes()

const et_upgrade_req = 'GET /up HTTP/1.1\r\nHost: x\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n'.bytes()
const et_switching = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n'.bytes()

// /lines upgrades to a line protocol (et_line_conn): a frame is one line.
const et_lines_req = 'GET /lines HTTP/1.1\r\nHost: x\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n'.bytes()

const et_expect_head = 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()
const et_expect_body = 'hello'.bytes()

const et_upload_body_len = 2 * 1024 * 1024 // > the 1 MiB streaming threshold ⇒ drain path
const et_upload_chunk_len = 64 * 1024
const et_upload_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\nuploaded'.bytes()

// /big answers 7 MiB (under the 8 MiB pending-write cap): more than a peer
// that is not reading can take, so the rest stays parked in write_buf.
const et_big_len = 7 * 1024 * 1024
const et_big_req = 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: ${et_big_len}\r\nConnection: keep-alive\r\n\r\n'.bytes()
const et_big_fill = u8(`a`)

// /sock parks on a socketpair end (.writable), then steps to a timer while
// keeping that end open (and registered: its watch is level-triggered).
const et_sock_req = 'GET /sock HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// /pool parks on a pooled "upstream" (a socketpair end) for its reply, then
// answers and keeps that end open for the next request (a plain watch_fd: the
// examples/mesh and DB-pool pattern). The upstream then goes away.
const et_pool_req = 'GET /pool HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// EtPool is where /pool leaves its pooled end, for the check to inspect: its
// number and its socket's inode (a closed fd's number is soon reused).
struct EtPool {
mut:
	fd    i64 = -1
	inode i64
}

const et_pool = &EtPool{}

// /self parks on its own client socket becoming writable (the backpressure
// pattern), then answers.
const et_self_req = 'GET /self HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// /forever streams one byte per 1 ms timer tick and never ends (an SSE-style
// stream whose client simply goes away).
const et_forever_req = 'GET /forever HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_forever_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\nConnection: keep-alive\r\n\r\n'.bytes()

// A connection that never sends: completes only when the server closes it.
const et_silent = vtest.Script{
	rounds:   [
		vtest.Round{
			send: []u8{}
			want: 0
		},
	]
	then_eof: true
}

// A connection that is served once, then goes idle: completes only when the
// server's idle deadline closes it, at least idle_ms after its response.
const et_idle_witness = vtest.Script{
	rounds:   [
		vtest.Round{
			send: et_req
			want: 1
		},
	]
	then_eof: true
}

@[direct_array_access]
fn et_has_prefix(req []u8, prefix []u8) bool {
	if req.len < prefix.len {
		return false
	}
	for i in 0 .. prefix.len {
		if req[i] != prefix[i] {
			return false
		}
	}
	return true
}

const et_delay_prefix = 'GET /delay'.bytes()
const et_stream_prefix = 'GET /stream'.bytes()
const et_up_prefix = 'GET /up'.bytes()
const et_lines_prefix = 'GET /lines'.bytes()
const et_upload_prefix = 'POST /upload'.bytes()
const et_lost_prefix = 'GET /lost'.bytes()
const et_lost_req = 'GET /lost HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_big_prefix = 'GET /big'.bytes()
const et_sock_prefix = 'GET /sock'.bytes()
const et_forever_prefix = 'GET /forever'.bytes()
const et_self_prefix = 'GET /self'.bytes()
const et_pool_prefix = 'GET /pool'.bytes()

// et_timerfd arms a CLOCK_MONOTONIC timerfd that first fires after `ms`, then
// every `interval_ms` (0 = one-shot). itimerspec = {it_interval, it_value}.
fn et_timerfd(ms int, interval_ms int) int {
	tfd := C.timerfd_create(1, 0) // 1 = CLOCK_MONOTONIC
	if tfd < 0 {
		return tfd
	}
	mut spec := [4]i64{}
	spec[0] = i64(interval_ms / 1000)
	spec[1] = i64(interval_ms % 1000) * 1_000_000
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	return tfd
}

fn et_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if et_has_prefix(req, et_delay_prefix) {
		// Parked for 3x the 300 ms budgets used below.
		event_loop.watch_fd(et_timerfd(900, 0), .readable, et_delay_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_stream_prefix) {
		out << et_stream_head
		event_loop.watch_fd(et_timerfd(et_tick_ms, et_tick_ms), .readable, et_stream_tick,
			voidptr(usize(0)))
		return .suspend
	}
	if et_has_prefix(req, et_lines_prefix) {
		if !core.queue_takeover(et_line_conn, unsafe { nil }) {
			out << et_ok // not takeover-capable: the test then fails on the missing 101
			return .done
		}
		out << et_switching
		return .done
	}
	if et_has_prefix(req, et_up_prefix) {
		if !core.queue_takeover(et_echo_conn, unsafe { nil }) {
			out << et_ok // not takeover-capable: the test then fails on the missing 101
			return .done
		}
		out << et_switching
		return .done
	}
	if et_has_prefix(req, et_lost_prefix) {
		event_loop.watch_fd(et_timerfd(50, 0), .readable, et_lost_rearm, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_upload_prefix) {
		out << et_upload_ok // answered from the head; the body is drained unseen
		return .done
	}
	if et_has_prefix(req, et_forever_prefix) {
		out << et_forever_head
		event_loop.watch_fd(et_timerfd(1, 1), .readable, et_forever_tick, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_big_prefix) {
		out << et_big_head
		start := out.len
		unsafe {
			out.grow_len(et_big_len)
			vmemset(&out[start], et_big_fill, et_big_len)
		}
		return .done
	}
	if et_has_prefix(req, et_self_prefix) {
		event_loop.watch_fd(client_fd, .writable, et_self_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_pool_prefix) {
		mut sv := [2]i32{} // C ints: V int is 64-bit
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close // no response: the test fails on the missing frame
		}
		reply := [u8(`x`)]!
		C.write(int(sv[1]), &reply[0], 1) // the upstream's reply, ready at once
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .readable, et_pool_done, pair)
		return .suspend
	}
	if et_has_prefix(req, et_sock_prefix) {
		mut sv := [2]i32{} // C ints: V int is 64-bit
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close // no response: the test fails on the missing frame
		}
		// Both ends ride in the payload: low 32 bits, high 32 bits.
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .writable, et_sock_step, pair)
		return .suspend
	}
	out << et_ok
	return .done
}

// et_forever_tick appends one byte per tick and re-parks, forever. The timer
// is request-owned: the runtime closes it when the client goes away.
fn et_forever_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	out << u8(`x`)
	event_loop.watch_fd(ready_fd, .readable, et_forever_tick, unsafe { nil })
	return .suspend
}

// et_sock_step runs once the socketpair end is writable (at once). It steps
// the request to a timer and keeps that end OPEN (the app may use it again).
// The end stays registered for EPOLLOUT with no watch behind it until
// et_sock_done closes it: it is not a new connection.
fn et_sock_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	event_loop.watch_fd(et_timerfd(100, 0), .readable, et_sock_done, watch_payload)
	return .suspend
}

// et_sock_done answers once the timer fires, then closes the timer and both
// socketpair ends (the request owns them).
fn et_sock_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	pair := u64(usize(watch_payload))
	C.close(int(u32(pair & 0xffff_ffff)))
	C.close(int(u32(pair >> 32)))
	out << et_ok
	return .done
}

// et_pool_done reads the upstream's reply and answers, keeping the pooled end
// open (and registered: the watch is level-triggered) for reuse. Then the
// upstream closes its end, as one that reaps idle connections would: from
// now on the pooled end reads EOF, with no watch behind it.
fn et_pool_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	pair := u64(usize(watch_payload))
	C.close(int(u32(pair >> 32)))
	mut pool := unsafe { et_pool }
	stdatomic.store_i64(&pool.inode, i64(et_fd_inode(ready_fd)))
	stdatomic.store_i64(&pool.fd, i64(ready_fd))
	out << et_ok
	return .done
}

// et_fd_inode is the inode of what fd refers to now (0 if it is closed).
fn et_fd_inode(fd int) u64 {
	st := os.stat('/proc/self/fd/${fd}') or { return 0 }
	return st.inode
}

// et_self_done answers once the client socket is writable (at once).
fn et_self_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	out << et_ok
	return .done
}

fn et_delay_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	out << et_delayed
	return .done
}

// et_lost_rearm "re-parks" on an fd it just closed: the watch cannot be armed
// (epoll ADD fails), yet it returns .suspend. Nothing would ever resume the
// request, and it holds no deadline while suspended.
fn et_lost_rearm(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	event_loop.watch_fd(ready_fd, .readable, et_lost_rearm, unsafe { nil })
	return .suspend
}

// et_stream_tick appends one body piece per tick and re-parks (the SSE shape:
// append, .suspend ⇒ the runtime flushes, then re-parks) until the last piece.
// The tick count rides in watch_payload, so the stream allocates nothing.
fn et_stream_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // level-triggered: consume the expiration
	out << et_tick
	n := int(usize(watch_payload)) + 1
	if n >= et_ticks {
		C.close(ready_fd)
		return .done
	}
	event_loop.watch_fd(ready_fd, .readable, et_stream_tick, voidptr(usize(n)))
	return .suspend
}

// et_echo_conn is the taken-over protocol: echo every byte back.
fn et_echo_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	out << buf
	return buf.len, core.Step.done
}

// et_line_conn echoes every complete line and leaves a partial one buffered,
// so a frame can span bursts.
fn et_line_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	for i := buf.len - 1; i >= 0; i-- {
		if buf[i] == `\n` {
			out << buf[..i + 1]
			return i + 1, core.Step.done
		}
	}
	return 0, core.Step.done
}

fn et_concat(a []u8, b []u8) []u8 {
	mut out := []u8{cap: a.len + b.len}
	out << a
	out << b
	return out
}

fn et_never(acc []u8) bool {
	return false
}

// GcStorm forces a garbage collection every 20 ms until stopped. Each Boehm
// collection stops every thread with a signal, so each worker's blocking wait
// returns EINTR far more often than its sweep interval — the condition that
// once kept a quiet worker from ever sweeping (it retried a wait computed
// from a stale clock), so its silent connections were never reaped. (A no-op
// under -gc none.)
struct GcStorm {
mut:
	stop i64
}

fn gc_storm(mut s GcStorm) {
	for stdatomic.load_i64(&s.stop) == 0 {
		gc_collect()
		time.sleep(20 * time.millisecond)
	}
}

// check_reaped_under_gc_signals: a silent connection is still reaped when the
// worker's wait is interrupted (EINTR) every 20 ms — shorter than its 100 ms
// sweep interval (read_timeout_ms 400). then_eof: only the server can end it.
fn check_reaped_under_gc_signals(backend server.IOBackend) ! {
	mut storm := &GcStorm{}
	t := spawn gc_storm(mut storm)
	defer {
		stdatomic.store_i64(&storm.stop, 1)
		t.wait()
	}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 400
		}
	}, [et_silent])!
	assert out.conns[0].connect_err == '', out.conns[0].connect_err
	assert out.conns[0].eof, '${backend}: a silent connection must be reaped under EINTR storms'
}

// check_pipelined_expect_gets_its_100: A asks for 100-continue and gets it;
// A's body and the head of B (also Expect: 100-continue) then arrive in ONE
// write. A is answered, and B must be prompted with its own 100 — the 100
// already sent was A's, not B's.
fn check_pipelined_expect_gets_its_100(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 5000
		}
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_expect_head
					until: vtest.count('100 Continue', 1)
				},
				vtest.Round{
					send:  et_concat(et_expect_body, et_expect_head)
					until: vtest.count('100 Continue', 2)
				},
				vtest.Round{
					send: et_expect_body
					want: 2
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the pipelined Expect request was not prompted with its own 100: ${c.raw.bytestr()}'
	assert c.frames.len >= 2
}

// check_streamed_expect_uploads_get_their_100: two streamed (> 1 MiB)
// Expect: 100-continue uploads on one keep-alive connection. Each must be
// prompted with its own 100 — the first upload's 100 must not suppress the
// second's (it never passes the pipelined-request path that resets it).
fn check_streamed_expect_uploads_get_their_100(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes()
	body := []u8{len: et_upload_body_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  head
					until: vtest.count('100 Continue', 1)
				},
				vtest.Round{
					send:  body
					until: vtest.count('uploaded', 1)
				},
				vtest.Round{
					send:  head
					until: vtest.count('100 Continue', 2)
				},
				vtest.Round{
					send:  body
					until: vtest.count('uploaded', 2)
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the second streamed Expect upload was not prompted with its own 100: ${c.raw#[..300].bytestr()}'
}

// check_takeover_not_idle_reaped: a taken-over connection keeps only its
// mid-frame read deadline — sitting quiet between messages for longer than
// the idle budget must not close it. The silent witness is reaped by its
// accept-time deadline, which is at least as long as the idle budget.
fn check_takeover_not_idle_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_upgrade_req
					until: vtest.count('101 Switching Protocols', 1)
				},
			]
		},
	])!
	assert !up.conns[0].unmet, '${backend}: upgrade not answered: ${up.conns[0].raw.bytestr()}'
	witness := h.fire([et_silent])!
	assert witness.conns[0].eof, '${backend}: the silent witness must be reaped'
	again := h.send(up.group, 'ping-after-idle'.bytes(), vtest.count('ping-after-idle', 1))!
	c := again.conns[0]
	assert !c.eof, '${backend}: a taken-over connection must not be idle-reaped'
	assert !c.unmet, '${backend}: echo after the quiet period missing: ${c.raw.bytestr()}'
}

// check_takeover_quiet_after_partial_frame: a taken-over connection holds a
// read deadline only while a frame is partly buffered. Once the frame
// completes, the connection may sit quiet for longer than that budget. The
// partial frame goes out first, then a plain request on a second connection
// is answered: with workers: 1 the worker has read the partial by then (its
// event was queued first), so the frame really spans two bursts.
fn check_takeover_quiet_after_partial_frame(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_lines_req
					until: vtest.count('101 Switching Protocols', 1)
				},
			]
		},
	])!
	assert !up.conns[0].unmet, '${backend}: upgrade not answered: ${up.conns[0].raw.bytestr()}'
	h.send(up.group, 'par'.bytes(), et_always)!
	barrier := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_req
				},
			]
		},
	])!
	assert barrier.conns[0].frames.len == 1, '${backend}: barrier request not answered'
	line := h.send(up.group, 'tial\n'.bytes(), vtest.count('partial\n', 1))!
	assert !line.conns[0].eof && !line.conns[0].unmet, '${backend}: the split frame was not echoed: ${line.conns[0].raw.bytestr()}'
	// Server time passes: two silent witnesses, each reaped by its own 300 ms
	// accept-time deadline, so the partial frame's deadline has long passed.
	w1 := h.fire([et_silent])!
	assert w1.conns[0].eof, '${backend}: the silent witness must be reaped'
	w2 := h.fire([et_silent])!
	assert w2.conns[0].eof, '${backend}: the silent witness must be reaped'
	again := h.send(up.group, 'ping\n'.bytes(), vtest.count('ping\n', 1))!
	c := again.conns[0]
	assert !c.eof && !c.unmet, '${backend}: a taken-over connection was reaped on the deadline of a completed frame: ${c.raw.bytestr()}'
}

// check_parked_request_not_reaped: a request parked on a watch (a timerfd that
// fires after 3x the budgets) waits on its fd, not on the client: neither the
// accept-time deadline nor idle may reap it. Once the continuation answers,
// the connection is back at rest and the idle deadline must close it.
fn check_parked_request_not_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_delay_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: a parked request was reaped before its watch fired: ${c.raw.bytestr()}'
	assert c.frames.len == 1
	assert c.frames[0].bytestr().ends_with('delayed'), '${backend}: expected the continuation answer, got: ${c.raw.bytestr()}'
	assert c.eof, '${backend}: after the resumed response the idle deadline must close the connection'
	assert !c.raw.bytestr().contains('408'), '${backend}: idle close must be silent'
}

// check_lost_resume_closed: a continuation that returns .suspend without a
// live watch (watch_fd failed, or was never called) can never be resumed. The
// connection must be closed then — not left waiting forever with no deadline
// holding its max_connections slot. then_eof: only the server can end it.
fn check_lost_resume_closed(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_lost_req
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: a suspend that cannot be resumed must close the connection'
	assert out.active_after == 0
}

// check_streaming_watch_not_idle_reaped: a continuation that streams (append,
// .suspend, flushed, re-parked) for several idle budgets is not at rest between
// pieces — the idle clock must not start at those flushes (they run BEFORE the
// runtime re-parks the connection). After the last piece it is at rest again.
fn check_streaming_watch_not_idle_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_stream_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: a streaming response was cut mid-stream: ${c.raw.bytestr()}'
	assert c.frames.len == 1
	assert c.frames[0].bytestr().ends_with('tick\n'.repeat(et_ticks)), '${backend}: stream incomplete: ${c.raw.bytestr()}'
	assert c.eof, '${backend}: after the stream completed the idle deadline must close the connection'
}

// check_expect_100_under_timeouts: Expect: 100-continue with read and idle
// armed. The client holds the body for longer than the idle budget after the
// interim 100 (the idle witness): the head is buffered, so the connection is
// mid-request — the read deadline governs, idle must not fire. Then the final
// 200, then idle closes the connection silently.
fn check_expect_100_under_timeouts(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 5000
			idle_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	exp := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_expect_head
					want: 1
				},
			]
		},
	])!
	assert exp.conns[0].frames.len == 1
	assert exp.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 100'), '${backend}: interim 100 missing'
	witness := h.fire([et_idle_witness])!
	assert witness.conns[0].eof, '${backend}: the idle witness must be reaped'
	fin := h.send(exp.group, et_expect_body, vtest.frames(2))!
	c := fin.conns[0]
	assert !c.eof && !c.unmet, '${backend}: a request held after 100-continue was reaped: ${c.raw.bytestr()}'
	assert c.frames.len == 2
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 200')
	closed := h.wait(exp.group, et_never)!
	assert closed.conns[0].eof, '${backend}: idle must close the connection after the final response'
	assert !closed.conns[0].raw.bytestr().contains('408')
}

// check_streamed_upload_under_timeouts: a > 1 MiB body takes the drain path
// (head answered and held, body consumed unseen). The client stalls mid-body
// for longer than the idle budget (the idle witness): a draining connection
// is mid-request, so idle must not fire. Then a second full upload on the same
// connection proves the drain was exact and keep-alive survived.
fn check_streamed_upload_under_timeouts(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
	first_chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
	rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
	full_body := []u8{len: et_upload_body_len, init: u8(0x61)}
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			max_request_bytes: 8 * 1024 * 1024
			read_timeout_ms:   5000
			idle_timeout_ms:   300
		}
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_concat(head, first_chunk)
					want: 0
				},
			]
		},
	])!
	witness := h.fire([et_idle_witness])!
	assert witness.conns[0].eof, '${backend}: the idle witness must be reaped'
	one := h.send(up.group, rest, vtest.frames(1))!
	assert !one.conns[0].eof && !one.conns[0].unmet, '${backend}: an upload stalled mid-body was idle-reaped: ${one.conns[0].raw.bytestr()}'
	two := h.send(up.group, et_concat(head, full_body), vtest.frames(2))!
	c := two.conns[0]
	assert !c.eof && !c.unmet, '${backend}: keep-alive after a drained upload broke'
	assert c.frames.len == 2
	for f in c.frames {
		assert f.bytestr().ends_with('uploaded'), '${backend}: unexpected upload answer: ${f.bytestr()}'
	}
}

// check_connect_storm_served: many connections whose request is written right
// behind the connect, with an accept-time deadline armed. Some of them reach
// the worker as ONE event carrying the birth EPOLLOUT and the request's
// EPOLLIN; under EPOLLET the EPOLLIN half must be served in that same event,
// or the request is never reported again and the client waits forever.
fn check_connect_storm_served(backend server.IOBackend, limits server.Limits) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	}, vtest.repeat(128, vtest.Script{
		rounds: [
			vtest.Round{
				send: et_req
				want: 1
			},
		]
	}))!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert c.frames.len == 1, '${backend}: storm conn ${i} not served'
	}
}

// check_vanished_streams_released: many streams parked on their timers, and
// every client goes away at once (stop() closes them all, with ticks still
// unread, so most peers reset). In one batch a client's close and its timer's
// tick then arrive in either order, and the flush of a tick can be the first
// to see the peer gone. Every connection must be released exactly once. A
// stale event for an fd already closed in the batch (a client, or the timer
// its hangup tore down) must not release it again (active_conns drifts below
// zero) or build a zombie. Every stream's timer is closed with its connection
// too, including when a tick's flush is the first to see the peer gone (the
// re-armed watch is torn down there).
fn check_vanished_streams_released(backend server.IOBackend) ! {
	before := et_open_fds()
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 60000 // accept-time births on; nothing expires here
			idle_timeout_ms: -1
		}
	}, vtest.repeat(128, vtest.Script{
		rounds: [
			vtest.Round{
				send:  et_forever_req
				until: vtest.count('xxx', 1)
			},
		]
	}))!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert !c.unmet, '${backend}: stream ${i} did not start: ${c.raw.bytestr()}'
	}
	assert out.active_after == 0, '${backend}: active_conns drifted to ${out.active_after}'
	// Every stream's timer must be closed with its connection. drive() settles
	// the connection count; a timer closed on the tick that found its peer gone
	// may follow a moment later, so allow the same bounded settle. The stopped
	// server keeps 2 fds of its own; a leaked timer per vanished stream would
	// be one per stream (128).
	mut leaked := et_open_fds() - before
	for _ in 0 .. 500 {
		if leaked < 6 {
			break
		}
		time.sleep(time.millisecond)
		leaked = et_open_fds() - before
	}
	assert leaked < 6, '${backend}: ${leaked} fds leaked — a watch outlived its client'
}

fn et_open_fds() int {
	fds := os.ls('/proc/self/fd') or { return 0 }
	return fds.len
}

fn et_always(acc []u8) bool {
	return true
}

// et_big_mismatch returns the first index where raw stops being a prefix of
// the /big response (head, then only fill bytes), or -1 if it is one.
@[direct_array_access]
fn et_big_mismatch(raw []u8) int {
	for i in 0 .. raw.len {
		want := if i < et_big_head.len { et_big_head[i] } else { et_big_fill }
		if i >= et_big_head.len + et_big_len || raw[i] != want {
			return i
		}
	}
	return -1
}

// check_pipelined_partial_fresh_deadline: a request that arrives behind a
// completed one gets its own read deadline from its first byte. It must not
// inherit the clock armed at accept (or for the request before it). `first`
// starts a request, `second` completes it and starts the next one, `third`
// completes that one. Budgets: read 1200 ms, idle 800 ms (sweep 200 ms). The
// idle witness takes 800 to ~1000 ms. `second` goes out before the first
// request's deadline (1200 ms from accept); `third` goes out well after that
// deadline, but within 1200 ms of `second`. workers: 1, so each witness shares
// the sweep with the connection under test.
fn check_pipelined_partial_fresh_deadline(backend server.IOBackend, first []u8, second []u8, third []u8) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 1200
			idle_timeout_ms: 800
		}
	})!
	defer {
		h.stop()
	}
	conn := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: first
					want: 0
				},
			]
		},
	])!
	w1 := h.fire([et_idle_witness])!
	assert w1.conns[0].eof, '${backend}: the idle witness must be reaped'
	one := h.send(conn.group, second, vtest.frames(1))!
	assert !one.conns[0].eof && !one.conns[0].unmet, '${backend}: the first request was not answered: ${one.conns[0].raw.bytestr()}'
	w2 := h.fire([et_idle_witness])!
	assert w2.conns[0].eof, '${backend}: the idle witness must be reaped'
	two := h.send(conn.group, third, vtest.frames(2))!
	c := two.conns[0]
	assert !c.eof && !c.unmet, "${backend}: the pipelined request was reaped on the previous request's clock: ${c.raw.bytestr()}"
	assert c.frames.len == 2
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 200'), '${backend}: unexpected answer: ${c.frames[1].bytestr()}'
}

// check_no_408_inside_pending_response: a read deadline that expires while a
// response is still pending must close silently. The 408 must not be written
// into the middle of that response. /big (7 MiB) is parked part-sent because
// the client does not read. A streamed upload then stalls mid-body: its
// response is held until the body drains, and that hold also stops the
// writable drain of /big. The client then reads what was sent, so the socket
// has room when the upload's read deadline expires. The bytes received must be
// exactly a prefix of the /big response, and the connection must end.
fn check_no_408_inside_pending_response(backend server.IOBackend) ! {
	upload_head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
	// One full read buffer (8 KiB) starts the streamed drain. The send still
	// fits a fresh socket's send buffer, so it goes out in one call and the
	// client reads nothing yet.
	upload_start := et_concat(upload_head, []u8{len: 8192, init: u8(0x61)})
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 1000
			idle_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	big := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_big_req
					want: 0
				},
			]
		},
	])!
	// Server time passes: /big is answered and parks part-sent. Its request is
	// complete and nothing is buffered, so no read or idle deadline is armed.
	w1 := h.fire([et_idle_witness])!
	assert w1.conns[0].eof, '${backend}: the idle witness must be reaped'
	// et_always: write the upload start and return without reading.
	h.send(big.group, upload_start, et_always)!
	// Server time passes again (300 to ~400 ms): the upload head has been read
	// and the drain has started. Its read deadline (1000 ms) is still ahead.
	w2 := h.fire([et_idle_witness])!
	assert w2.conns[0].eof, '${backend}: the idle witness must be reaped'
	out := h.wait(big.group, et_never)!
	c := out.conns[0]
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.len > et_big_head.len, '${backend}: precondition: /big should be part-sent, got ${c.raw.len} bytes'
	assert c.raw.len < et_big_head.len + et_big_len, '${backend}: precondition: /big should still be pending, but all of it arrived'
	bad := et_big_mismatch(c.raw)
	assert bad < 0, '${backend}: bytes after offset ${bad} are not /big response bytes (408 inside it?): ${c.raw#[bad..bad + 120].bytestr()}'
}

// check_stalled_upload_408: a streamed upload that stalls mid-body until its
// read deadline passes gets a 408, then the close (plaintext epoll sends the
// 408 when part of a request arrived). The upload's own reply is held in
// write_buf until the body drains. The client has not seen it, so it must
// not suppress the 408: the 408 replaces it. But when a request pipelined
// ahead of the upload still has its reply held too, a 408 would be read as
// the answer to that request: the close is silent then.
fn check_stalled_upload_408(backend server.IOBackend) ! {
	upload := et_concat('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes(),
		[]u8{len: et_upload_chunk_len, init: u8(0x61)})
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: upload
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(et_req, upload)
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled upload must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	behind := out.conns[1]
	assert behind.connect_err == '', behind.connect_err
	assert behind.eof, '${backend}: the stalled upload must be reaped'
	assert behind.raw.len == 0, '${backend}: a 408 ahead of the reply owed to the pipelined GET: ${behind.raw.bytestr()}'
	assert out.active_after == 0
}

// check_stalled_upload_408_after_expect: an upload with Expect: 100-continue
// whose client sends the first body bytes in the same write as the head
// (RFC 9110 §10.1.1 lets it skip the wait), then stalls. The server queues the
// interim 100 in the burst that also starts the streamed drain, so the 100 is
// held with the upload's reply and never sent. It is that request's own
// output, not a response owed to an earlier request: the stall still gets its
// 408. When the client does wait for the 100, the 408 follows it.
fn check_stalled_upload_408_after_expect(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes()
	chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(head, chunk)
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: head
					want: 1
				},
				vtest.Round{
					send: chunk
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled upload whose 100 Continue was never sent must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	waited := out.conns[1]
	assert waited.connect_err == '', waited.connect_err
	assert waited.eof, '${backend}: the stalled upload must be reaped'
	assert waited.raw.bytestr().starts_with('HTTP/1.1 100'), '${backend}: interim 100 missing: ${waited.raw.bytestr()}'
	assert waited.raw.bytestr().contains('\r\n\r\nHTTP/1.1 408'), '${backend}: no 408 after the 100 Continue: ${waited.raw.bytestr()}'
	assert !waited.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	assert out.active_after == 0
}

// check_stepped_away_watch_not_adopted: a continuation that steps from one fd
// to another keeps the first one open. That fd stays registered, and its
// level-triggered EPOLLOUT keeps coming back with no watch and no connection
// behind it. It must not be taken for a new connection's birth: adopted, its
// state expired and closed the app's fd, which also decremented active_conns
// for a connection that was never counted. Only a socket accepted on the
// listener is born. `uds` = '' listens on TCP; otherwise on that unix socket
// path, where the app's fd (a socketpair end) is AF_UNIX too, but unnamed.
fn check_stepped_away_watch_not_adopted(backend server.IOBackend, uds string) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing:  backend
		handler:          et_handler
		workers:          1
		unix_socket_path: uds
		limits:           server.Limits{
			read_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_sock_req
					want: 1
				},
			]
			then_eof: true // idle-reaped; any adopted fd expired earlier
		},
		et_silent, // reaped by its accept-time deadline: births work here
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend} ${uds}: /sock not answered: ${c.raw.bytestr()}'
	assert c.eof
	assert out.conns[1].connect_err == '', out.conns[1].connect_err
	assert out.conns[1].eof, '${backend} ${uds}: the silent connection must be reaped'
	assert out.active_after == 0, '${backend} ${uds}: active_conns drifted to ${out.active_after}'
}

// check_pooled_fd_eof_no_spin: a pooled fd kept open after its watch finished
// stays registered, level-triggered. Once its upstream closes it, it reads
// EOF on every epoll_wait, with no watch and no connection behind it. The
// worker must not busy-loop on it (a report dropped on every wait never lets
// epoll_wait block), must not adopt it as a connection (its close would free
// a slot that was never counted) and must leave it open (the app owns it). The
// window is the silent witness, reaped by its accept-time deadline after at
// least 500 ms; the worker, blocked in epoll_wait, should use next to no CPU
// in it. `uds` = '' listens on TCP; otherwise on that unix socket path.
fn check_pooled_fd_eof_no_spin(backend server.IOBackend, uds string) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing:  backend
		handler:          et_handler
		workers:          1
		unix_socket_path: uds
		limits:           server.Limits{
			read_timeout_ms: 500
			idle_timeout_ms: -1 // the client connection stays at rest meanwhile
		}
	})!
	defer {
		h.stop()
	}
	pool := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_pool_req
					want: 1
				},
			]
		},
	])!
	assert !pool.conns[0].unmet, '${backend} ${uds}: /pool not answered: ${pool.conns[0].raw.bytestr()}'
	cpu0 := C.clock()
	witness := h.fire([et_silent])!
	cpu_us := C.clock() - cpu0
	assert witness.conns[0].eof, '${backend} ${uds}: the silent witness must be reaped'
	assert cpu_us < 100_000, '${backend} ${uds}: the worker busy-looped on a pooled fd whose upstream closed: ${cpu_us} us of CPU in a window of at least 500 ms'
	again := h.send(pool.group, et_req, vtest.frames(2))!
	assert !again.conns[0].eof && !again.conns[0].unmet, '${backend} ${uds}: the client connection stopped serving: ${again.conns[0].raw.bytestr()}'
	assert again.active_after == 1, '${backend} ${uds}: active_conns drifted to ${again.active_after}'
	pooled := int(stdatomic.load_i64(&et_pool.fd))
	assert et_fd_inode(pooled) == u64(stdatomic.load_i64(&et_pool.inode)), '${backend} ${uds}: the pooled end was closed under the app'
	C.close(pooled)
}

// check_self_watch_keepalive: a request parks on its own client socket
// becoming writable (watch_fd(client_fd, .writable)), then answers. The
// connection must go on serving: its next request is read and answered, and
// it is then idle-reaped as usual. A watch that replaced the socket's
// EPOLLIN|EPOLLET registration with a one-shot EPOLLOUT would leave it
// reporting nothing once the watch fired.
fn check_self_watch_keepalive(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			idle_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_self_req
					want: 1
				},
				vtest.Round{
					send: et_req
					want: 1
				},
			]
			then_eof: true // idle-reaped after the second answer
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 2, '${backend}: the request after a self-watch was not answered: ${c.raw.bytestr()}'
	for f in c.frames {
		assert f == et_ok, '${backend}: unexpected answer: ${f.bytestr()}'
	}
	assert c.eof
	assert out.active_after == 0, '${backend}: active_conns drifted to ${out.active_after}'
}

fn test_epoll_takeover_not_idle_reaped() ! {
	$if linux {
		check_takeover_not_idle_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
		check_takeover_not_idle_reaped(.epoll, server.Limits{
			idle_timeout_ms: 300
		})!
	}
}

fn test_epoll_takeover_quiet_after_partial_frame() ! {
	$if linux {
		check_takeover_quiet_after_partial_frame(.epoll)!
	}
}

fn test_epoll_parked_request_not_reaped() ! {
	$if linux {
		check_parked_request_not_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
		check_parked_request_not_reaped(.epoll, server.Limits{
			idle_timeout_ms: 300
		})!
	}
}

fn test_epoll_streaming_watch_not_idle_reaped() ! {
	$if linux {
		check_streaming_watch_not_idle_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
	}
}

fn test_epoll_lost_resume_closed() ! {
	$if linux {
		check_lost_resume_closed(.epoll)!
	}
}

fn test_epoll_reaped_under_gc_signals() ! {
	$if linux {
		check_reaped_under_gc_signals(.epoll)!
	}
}

fn test_epoll_pipelined_partial_fresh_deadline() ! {
	$if linux {
		// A partial head, completed together with the next request's partial.
		check_pipelined_partial_fresh_deadline(.epoll, 'GET / HTTP/1.1\r\nHost: x\r\n'.bytes(),
			'\r\nGET / HTTP/1.1\r\nHo'.bytes(), 'st: x\r\n\r\n'.bytes())!
		// A streamed upload, whose body completes together with the next
		// request's partial.
		head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
		chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
		rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
		check_pipelined_partial_fresh_deadline(.epoll, et_concat(head, chunk), et_concat(rest,
			'GET / HTTP/1.1\r\nHo'.bytes()), 'st: x\r\n\r\n'.bytes())!
	}
}

fn test_epoll_no_408_inside_pending_response() ! {
	$if linux {
		check_no_408_inside_pending_response(.epoll)!
	}
}

fn test_epoll_stalled_upload_408() ! {
	$if linux {
		check_stalled_upload_408(.epoll)!
	}
}

fn test_epoll_stalled_upload_408_after_expect() ! {
	$if linux {
		check_stalled_upload_408_after_expect(.epoll)!
	}
}

fn test_epoll_stepped_away_watch_not_adopted() ! {
	$if linux {
		check_stepped_away_watch_not_adopted(.epoll, '')!
		check_stepped_away_watch_not_adopted(.epoll, os.join_path(os.temp_dir(),
			'vanilla_et_sock_${os.getpid()}.sock'))!
	}
}

fn test_epoll_pooled_fd_eof_no_spin() ! {
	$if linux {
		check_pooled_fd_eof_no_spin(.epoll, '')!
		check_pooled_fd_eof_no_spin(.epoll, os.join_path(os.temp_dir(), 'vanilla_et_pool_${os.getpid()}.sock'))!
	}
}

fn test_epoll_self_watch_keepalive() ! {
	$if linux {
		check_self_watch_keepalive(.epoll)!
	}
}

fn test_epoll_expect_100_under_timeouts() ! {
	$if linux {
		check_expect_100_under_timeouts(.epoll)!
	}
}

fn test_epoll_pipelined_expect_gets_its_100() ! {
	$if linux {
		check_pipelined_expect_gets_its_100(.epoll)!
	}
}

fn test_epoll_streamed_expect_uploads_get_their_100() ! {
	$if linux {
		check_streamed_expect_uploads_get_their_100(.epoll)!
	}
}

fn test_epoll_streamed_upload_under_timeouts() ! {
	$if linux {
		check_streamed_upload_under_timeouts(.epoll)!
	}
}

fn test_epoll_connect_storm_served() ! {
	$if linux {
		check_connect_storm_served(.epoll, server.Limits{
			read_timeout_ms: 2000
		})!
		check_connect_storm_served(.epoll, server.Limits{
			idle_timeout_ms: 2000
		})!
	}
}

fn test_epoll_vanished_streams_released() ! {
	$if linux {
		check_vanished_streams_released(.epoll)!
	}
}

// --- poll (-d vanilla_poll): the checks that need no watch reactor ----------

fn test_poll_pipelined_partial_fresh_deadline() ! {
	$if linux {
		$if vanilla_poll ? {
			check_pipelined_partial_fresh_deadline(.poll, 'GET / HTTP/1.1\r\nHost: x\r\n'.bytes(),
				'\r\nGET / HTTP/1.1\r\nHo'.bytes(), 'st: x\r\n\r\n'.bytes())!
			head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
			chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
			rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
			check_pipelined_partial_fresh_deadline(.poll, et_concat(head, chunk), et_concat(rest,
				'GET / HTTP/1.1\r\nHo'.bytes()), 'st: x\r\n\r\n'.bytes())!
		}
	}
}

fn test_poll_no_408_inside_pending_response() ! {
	$if linux {
		$if vanilla_poll ? {
			check_no_408_inside_pending_response(.poll)!
		}
	}
}

fn test_poll_stalled_upload_408() ! {
	$if linux {
		$if vanilla_poll ? {
			check_stalled_upload_408(.poll)!
		}
	}
}

fn test_poll_expect_100_under_timeouts() ! {
	$if linux {
		$if vanilla_poll ? {
			check_expect_100_under_timeouts(.poll)!
		}
	}
}

fn test_poll_pipelined_expect_gets_its_100() ! {
	$if linux {
		$if vanilla_poll ? {
			check_pipelined_expect_gets_its_100(.poll)!
		}
	}
}

fn test_poll_streamed_expect_uploads_get_their_100() ! {
	$if linux {
		$if vanilla_poll ? {
			check_streamed_expect_uploads_get_their_100(.poll)!
		}
	}
}

fn test_poll_streamed_upload_under_timeouts() ! {
	$if linux {
		$if vanilla_poll ? {
			check_streamed_upload_under_timeouts(.poll)!
		}
	}
}

fn test_poll_connect_storm_served() ! {
	$if linux {
		$if vanilla_poll ? {
			check_connect_storm_served(.poll, server.Limits{
				read_timeout_ms: 2000
			})!
			check_connect_storm_served(.poll, server.Limits{
				idle_timeout_ms: 2000
			})!
		}
	}
}

fn test_poll_reaped_under_gc_signals() ! {
	$if linux {
		$if vanilla_poll ? {
			check_reaped_under_gc_signals(.poll)!
		}
	}
}

// check_poll_stalled_expect_upload_408: the stalled-upload 408 when the head
// also asks for 100-continue and comes in one write with body bytes. The first
// read fills the read buffer, so the interim 100 is queued and the drain
// starts in the same burst, before any flush. That unsent 100 belongs to the
// upload itself, not to an earlier request: the 408 replaces it along with the
// held reply. With a GET pipelined ahead, its reply is owed first: silent.
fn check_poll_stalled_expect_upload_408(backend server.IOBackend) ! {
	upload := et_concat('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes(),
		[]u8{len: et_upload_chunk_len, init: u8(0x61)})
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: upload
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(et_req, upload)
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled Expect: 100-continue upload must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	behind := out.conns[1]
	assert behind.connect_err == '', behind.connect_err
	assert behind.eof, '${backend}: the stalled upload must be reaped'
	assert behind.raw.len == 0, '${backend}: a 408 ahead of the reply owed to the pipelined GET: ${behind.raw.bytestr()}'
	assert out.active_after == 0
}

fn test_poll_stalled_expect_upload_408() ! {
	$if linux {
		$if vanilla_poll ? {
			check_poll_stalled_expect_upload_408(.poll)!
		}
	}
}
