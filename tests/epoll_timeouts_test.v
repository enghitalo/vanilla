// vtest build: linux
// Connection-reaping edge cases on the plain epoll worker that
// backend_behaviors_test.v does not cover: what the read/idle deadlines must
// NOT reap (a taken-over connection, a parked request, a request streaming
// from a watch), and the flows that keep a request open across edges
// (Expect: 100-continue, a streamed > 1 MiB upload) while those deadlines are
// armed. Plus a connect storm whose requests arrive with the connection — the
// accept-time EPOLLOUT birth edge must still serve the EPOLLIN half.
//
// vtest contract (docs/VTEST.md): the only clocks are the server's Limits. A
// "pause longer than idle" is produced by a WITNESS connection the server
// itself reaps by a deadline at least as long as the idle budget: when
// fire(witness) returns, that much server time has passed while the
// connection under test sat still — no client sleeps, no stopwatch deadlines.
import server
import core
import vtest

$if linux {
	#include <sys/timerfd.h>
}

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.close(fd int) int

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
	if et_has_prefix(req, et_upload_prefix) {
		out << et_upload_ok // answered from the head; the body is drained unseen
		return .done
	}
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
