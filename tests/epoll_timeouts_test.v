// vtest build: linux
// Connection-reaping edge cases on the plain epoll worker that
// backend_behaviors_test.v does not cover: what the read/idle deadlines must
// NOT reap (a taken-over connection, a parked request, a request streaming
// from a watch), a suspended request that can never resume (closed, not
// leaked), and the flows that keep a request open across edges
// (Expect: 100-continue, a streamed > 1 MiB upload) while those deadlines are
// armed. Plus a connect storm whose requests arrive with the connection — the
// accept-time EPOLLOUT birth edge must still serve the EPOLLIN half. Also: a
// pipelined request's own read deadline; no 408 inside a pending response;
// streams whose clients all vanish at once are released exactly once, timers
// included; and a spent watch on an fd the app keeps open is never adopted as
// a connection.
//
// vtest contract (docs/VTEST.md): the only clocks are the server's Limits. A
// "pause longer than idle" is produced by a WITNESS connection the server
// itself reaps by a deadline at least as long as the idle budget: when
// fire(witness) returns, that much server time has passed while the
// connection under test sat still — no client sleeps, no stopwatch deadlines.
import os
import server
import core
import vtest

$if linux {
	#include <sys/timerfd.h>
	#include <sys/socket.h>
}

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &int) int

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
// keeping that end open.
const et_sock_req = 'GET /sock HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

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
const et_upload_prefix = 'POST /upload'.bytes()
const et_lost_prefix = 'GET /lost'.bytes()
const et_lost_req = 'GET /lost HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_big_prefix = 'GET /big'.bytes()
const et_sock_prefix = 'GET /sock'.bytes()
const et_forever_prefix = 'GET /forever'.bytes()

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
	if et_has_prefix(req, et_sock_prefix) {
		mut sv := [2]int{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close // no response: the test fails on the missing frame
		}
		// Both ends ride in the payload: low 32 bits, high 32 bits.
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(sv[0], .writable, et_sock_step, pair)
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
// The spent watch on it must stay silent: it is not a new connection.
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

fn et_concat(a []u8, b []u8) []u8 {
	mut out := []u8{cap: a.len + b.len}
	out << a
	out << b
	return out
}

fn et_never(acc []u8) bool {
	return false
}

// check_takeover_not_idle_reaped: a taken-over connection keeps only its
// mid-frame read deadline — sitting quiet between messages for longer than
// the idle budget must not close it. The silent witness is reaped by its
// accept-time deadline, which is at least as long as the idle budget.
fn check_takeover_not_idle_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
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
// to see the peer gone. Every connection must be released exactly once. Its
// timer must be closed, not leaked. A stale event for an fd already closed in
// the batch must not release it again (active_conns drifts below zero) or
// build a zombie. An fd leak here means a watch outlived its client.
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
	after := et_open_fds()
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert !c.unmet, '${backend}: stream ${i} did not start: ${c.raw.bytestr()}'
	}
	assert out.active_after == 0, '${backend}: active_conns drifted to ${out.active_after}'
	// Slack for the server's own fds (2 here); leaked timers are dozens.
	assert after - before < 16, '${backend}: ${after - before} fds leaked'
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

// check_stepped_away_watch_not_adopted: a continuation that steps from one fd
// to another keeps the first one open. The first watch is spent, so it must
// report nothing more. Before, its level-triggered EPOLLOUT came back with no
// watch behind it, looked like a new connection's birth, and was adopted. The
// adopted state then expired and closed the app's fd. That decremented
// active_conns for a connection that was never counted.
fn check_stepped_away_watch_not_adopted(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
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
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: /sock not answered: ${c.raw.bytestr()}'
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

// io_uring has one live ring per process: run this with VANILLA_WORKERS=1, and
// on its own (-run-only).
fn test_iouring_lost_resume_closed() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_lost_resume_closed(.io_uring)!
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

fn test_epoll_vanished_streams_released() ! {
	$if linux {
		check_vanished_streams_released(.epoll)!
	}
}

fn test_epoll_stepped_away_watch_not_adopted() ! {
	$if linux {
		check_stepped_away_watch_not_adopted(.epoll)!
	}
}

fn test_epoll_expect_100_under_timeouts() ! {
	$if linux {
		check_expect_100_under_timeouts(.epoll)!
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
