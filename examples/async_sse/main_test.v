// vtest build: linux
// The stream runs on the epoll worker's subscriptions (Linux only).
module main

import core
import server
import time
import vtest
import http1_1.response

// The whole response body on the wire: one chunk per event, then the
// zero-size chunk. `data: tick 1 of 5\n\n` is 19 = 0x13 bytes.
const want_chunks = '13\r\ndata: tick 1 of 5\n\n\r\n' + '13\r\ndata: tick 2 of 5\n\n\r\n' +
	'13\r\ndata: tick 3 of 5\n\n\r\n' + '13\r\ndata: tick 4 of 5\n\n\r\n' +
	'13\r\ndata: tick 5 of 5\n\n\r\n' + 'b\r\ndata: bye\n\n\r\n' + '0\r\n\r\n'

const want_events = 'data: tick 1 of 5\n\ndata: tick 2 of 5\n\ndata: tick 3 of 5\n\n' +
	'data: tick 4 of 5\n\ndata: tick 5 of 5\n\ndata: bye\n\n'

const events_req = 'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const missing_req = 'GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

// Recorded is what the stand-in hooks saw, found through EventLoop.reactor,
// which a test loop never hands to a real backend.
struct Recorded {
mut:
	subscribed bool
	sub_state  voidptr
	wake_ms    int
}

// record_subscribe and record_wake_after stand in for the epoll worker's
// subscribe and wake_after: they record the state and the timer, and arm
// nothing.
fn record_subscribe(mut el core.EventLoop, wake_fn core.WakeFn, sub_state voidptr) core.ConnHandle {
	mut r := unsafe { &Recorded(el.reactor) }
	r.subscribed = true
	r.sub_state = sub_state
	return core.ConnHandle{
		fd: 7
	}
}

fn record_wake_after(mut el core.EventLoop, ms int) bool {
	mut r := unsafe { &Recorded(el.reactor) }
	r.wake_ms = ms
	return true
}

fn recording_loop(r &Recorded) core.EventLoop {
	return core.EventLoop{
		reactor:         voidptr(r)
		subscribe_hook:  record_subscribe
		wake_after_hook: record_wake_after
	}
}

// tick runs sse_tick for `reason` with the count `sent` and returns its step.
fn tick(mut out []u8, reason core.WakeReason, sent int, mut el core.EventLoop) core.Step {
	el.reason = reason
	return sse_tick(mut out, 7, false, voidptr(u64(sent)), unsafe { nil }, mut el)
}

// dechunk decodes a chunked body that starts at `start` (RFC 9112 §7.1),
// strictly: every chunk-size line is hex digits + CRLF, and every chunk's data
// is followed by CRLF. It returns the decoded body and the offset just past
// the final `0\r\n\r\n`, or none while the body is incomplete or malformed.
fn dechunk(raw []u8, start int) ?(string, int) {
	mut body := []u8{}
	mut i := start
	for {
		mut size := 0
		mut digits := 0
		for i < raw.len && raw[i] != `\r` {
			c := raw[i]
			d := if c >= `0` && c <= `9` {
				int(c - `0`)
			} else if c >= `a` && c <= `f` {
				int(c - `a`) + 10
			} else {
				return none
			}
			size = size * 16 + d
			digits++
			i++
		}
		if digits == 0 || i + 1 >= raw.len || raw[i + 1] != `\n` {
			return none
		}
		i += 2
		if size == 0 {
			if i + 1 >= raw.len || raw[i] != `\r` || raw[i + 1] != `\n` {
				return none
			}
			return body.bytestr(), i + 2
		}
		if i + size + 2 > raw.len || raw[i + size] != `\r` || raw[i + size + 1] != `\n` {
			return none
		}
		body << raw[i..i + size]
		i += size + 2
	}
	return none
}

// body_start is the offset just past the first response head, or -1.
fn body_start(raw []u8) int {
	for i in 0 .. raw.len - 3 {
		if raw[i] == `\r` && raw[i + 1] == `\n` && raw[i + 2] == `\r` && raw[i + 3] == `\n` {
			return i + 4
		}
	}
	return -1
}

fn test_wx_writes_chunk_sizes() {
	for n, want in {
		0:          '0'
		9:          '9'
		10:         'a'
		0x13:       '13'
		255:        'ff'
		4096:       '1000'
		0x7fffffff: '7fffffff'
	} {
		mut out := []u8{}
		wx(mut out, n)
		assert out.bytestr() == want, 'wx(${n})'
	}
}

// The wake fn, driven directly: five timer expiries come out as five chunks
// followed by the `bye` chunk and the zero-size chunk that ends the body. Each
// tick but the last stores its count (re-subscribing) and re-arms the timer;
// the last closes.
fn test_sse_tick_frames_each_event_as_a_chunk_and_ends_the_body() {
	mut r := &Recorded{}
	mut el := recording_loop(r)
	mut out := []u8{}
	mut sent := 0 // what handle subscribes with: no event sent yet
	for n in 1 .. 6 {
		r.wake_ms = 0
		r.subscribed = false
		step := tick(mut out, .timeout, sent, mut el)
		if n < 5 {
			assert step == .done, 'tick ${n}'
			assert r.wake_ms == tick_ms, 'tick ${n} must re-arm its timer'
			assert r.subscribed && u64(r.sub_state) == u64(n), 'tick ${n} must store its count'
			sent = int(u64(r.sub_state))
		} else {
			assert step == .close, 'the last tick ends the stream'
			assert r.wake_ms == 0, 'the last tick must not re-arm'
		}
	}
	assert out.bytestr() == want_chunks
	body, end := dechunk(out, 0) or { panic('the body does not end: ${out.bytestr()}') }
	assert body == want_events
	assert end == out.len
}

// The chunk size counts the counter's digits: a count past max_events (which
// handle never arms) still frames its chunk, then ends the stream.
fn test_sse_tick_sizes_multi_digit_counters() {
	mut r := &Recorded{}
	mut el := recording_loop(r)
	mut out := []u8{}
	step := tick(mut out, .timeout, 9, mut el)
	assert step == .close
	// `data: tick 10 of 5\n\n` is 20 = 0x14 bytes.
	assert out.bytestr() == '14\r\ndata: tick 10 of 5\n\n\r\n' + bye_and_end
}

// Server.shutdown() ends the body at once, with its `bye`; .closed has
// nothing to free.
fn test_sse_tick_shutdown_and_closed() {
	mut r := &Recorded{}
	mut el := recording_loop(r)
	mut out := []u8{}
	assert tick(mut out, .shutdown, 2, mut el) == .close
	assert out.bytestr() == bye_and_end
	out.clear()
	assert tick(mut out, .closed, 2, mut el) == .done
	assert out.len == 0 && r.wake_ms == 0
}

// Where the connection cannot be kept (no takeover, or no subscriptions: a
// tcc build, a plain test loop), /events answers 501 and closes.
fn test_events_without_push_is_501() {
	mut out := []u8{}
	mut el := core.EventLoop{}
	step := handle(events_req, mut out, -1, unsafe { nil }, mut el)
	if _ := core.take_queued_takeover() {
	}
	assert step == .close
	assert out.bytestr() == not_implemented
}

// The subscribe path, through the stand-in hooks: the head, the drain-only
// takeover, a subscription with no event sent yet, and the first tick armed.
// Takeover is inert under tcc (#173).
fn test_events_subscribes_and_arms_the_first_tick() {
	$if tinyc {
		return
	}
	core.enable_takeover() // this thread may queue a takeover, as an epoll worker does
	mut r := &Recorded{}
	mut el := recording_loop(r)
	mut out := []u8{}
	step := handle(events_req, mut out, -1, unsafe { nil }, mut el)
	qt := core.take_queued_takeover() or { core.QueuedTakeover{} }
	assert step == .done
	assert out.bytestr() == sse_headers
	assert voidptr(qt.cont) == voidptr(drain_conn), 'the connection was not handed to drain_conn'
	assert r.subscribed && r.sub_state == unsafe { nil }
	assert r.wake_ms == tick_ms
}

// stream runs one whole /events stream in process: handle's head, then
// max_events ticks of sse_tick, each with the count the last one stored.
fn stream(mut out []u8, mut el core.EventLoop, mut r Recorded) {
	unsafe {
		out.len = 0
	}
	handle(events_req, mut out, -1, unsafe { nil }, mut el)
	if _ := core.take_queued_takeover() {
	}
	r.sub_state = unsafe { nil }
	for _ in 0 .. max_events {
		unsafe {
			out.len = 0
		}
		el.reason = .timeout
		sse_tick(mut out, 7, false, r.sub_state, unsafe { nil }, mut el)
	}
}

// A stream allocates nothing: 2000 of them through one reused buffer must not
// move the collector's lifetime allocation counter. (Its state is the count
// in the subscription itself, not a struct per stream: under -gc none,
// vanilla's production build, that would be a leak per stream.)
fn test_stream_allocates_nothing() {
	$if gcboehm ? {
		core.enable_takeover()
		mut out := []u8{cap: 4096}
		mut r := &Recorded{}
		mut el := recording_loop(r)
		stream(mut out, mut el, mut r) // warm-up
		assert out.bytestr().ends_with(bye_and_end)
		rounds := 2000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			stream(mut out, mut el, mut r)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the stream allocated ${grown} bytes over ${rounds} streams'
	}
}

// stream_ended holds once the whole chunked SSE body has arrived.
fn stream_ended(acc []u8) bool {
	start := body_start(acc)
	if start < 0 {
		return false
	}
	_, _ := dechunk(acc, start) or { return false }
	return true
}

// On the wire: the stream ends where its chunked framing says, a tick a
// second, then the server closes the connection. Under tcc /events is a 501.
fn test_sse_stream_ends_and_the_connection_closes() ! {
	sw := time.new_stopwatch()
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
		workers:         1
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send:  events_req
					until: stream_ended
				},
			]
			then_eof: true
		},
	])!
	took := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	$if tinyc {
		assert c.raw.bytestr() == not_implemented
		return
	}
	assert !c.unmet, 'the stream did not end: ${c.raw.bytestr()}'
	assert c.eof, 'the connection stayed open after the stream'
	assert c.raw.bytestr() == sse_headers + want_chunks
	assert took >= 4 * tick_ms, 'five ticks took ${took} ms'
	assert out.inflight_after == 0
	assert out.active_after == 0
}

// Server.shutdown(grace) does not wait for the stream: the stream is not
// parked, so the drain does not count it, and its wake fn gets .shutdown and
// ends the body at once with its `bye`. The server has no push mailbox (posts
// are off): .shutdown does not need one.
fn test_shutdown_ends_the_stream_early() ! {
	$if tinyc {
		return
	}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
		workers:         2
	})!
	defer {
		h.stop()
	}
	first := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  events_req
					until: vtest.count('data: tick 1 of 5', 1)
				},
			]
		},
	])!
	assert first.conns[0].connect_err == '', first.conns[0].connect_err
	sw := time.new_stopwatch()
	h.server_ref().shutdown(5000)
	waited := sw.elapsed().milliseconds()
	assert waited < 1000, 'the stream held shutdown(5000) for ${waited} ms'
	got := h.wait(first.group, stream_ended)!
	c := got.conns[0]
	assert !c.unmet, 'the stream did not end on shutdown: ${c.raw.bytestr()}'
	assert c.raw.bytestr() == sse_headers + '13\r\ndata: tick 1 of 5\n\n\r\n' + bye_and_end
}

fn test_other_paths_get_404_and_bad_requests_get_400() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /events-not HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: 'GET /x?events HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: missing_req
				},
			]
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: 'GET\r\n\r\n'.bytes()
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 3
	for f in c.frames {
		assert f.bytestr() == not_found
	}
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
}
