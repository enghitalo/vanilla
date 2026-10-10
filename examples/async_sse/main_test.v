// vtest build: linux
// main.v needs <sys/timerfd.h> and the epoll watch reactor (Linux only).
module main

import core
import server
import vtest
import http1_1.response

#include <unistd.h>

fn C.pipe(fds &i32) int
fn C.write(fd int, buf voidptr, n usize) int

// The whole response body on the wire: one chunk per event, then the
// zero-size chunk. `data: tick 1 of 5\n\n` is 19 = 0x13 bytes.
const want_chunks = '13\r\ndata: tick 1 of 5\n\n\r\n' + '13\r\ndata: tick 2 of 5\n\n\r\n' +
	'13\r\ndata: tick 3 of 5\n\n\r\n' + '13\r\ndata: tick 4 of 5\n\n\r\n' +
	'13\r\ndata: tick 5 of 5\n\n\r\n' + 'b\r\ndata: bye\n\n\r\n' + '0\r\n\r\n'

const want_events = 'data: tick 1 of 5\n\ndata: tick 2 of 5\n\ndata: tick 3 of 5\n\n' +
	'data: tick 4 of 5\n\ndata: tick 5 of 5\n\ndata: bye\n\n'

const events_req = 'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const missing_req = 'GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

// record_register stands in for the backend's watch registration: it records
// the fd the way the reactor does, and arms nothing.
fn record_register(mut event_loop core.EventLoop, ext_fd int, interest core.WatchInterest, continuation core.WakeFn, watch_payload voidptr) {
	event_loop.last_watched = ext_fd
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

// stream_ended holds once the whole chunked SSE body has arrived.
fn stream_ended(acc []u8) bool {
	start := body_start(acc)
	if start < 0 {
		return false
	}
	_, _ := dechunk(acc, start) or { return false }
	return true
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

// The continuation, driven directly: five ticks must come out as five chunks
// followed by the `bye` chunk and the zero-size chunk that ends the body. Under
// the old code the body had no framing at all, so it never ended.
fn test_sse_tick_frames_each_event_as_a_chunk_and_ends_the_body() {
	mut fds := [2]i32{}
	rc := C.pipe(unsafe { &fds[0] })
	assert rc == 0
	rfd := int(fds[0])
	wfd := int(fds[1])
	st := &Stream{
		tfd: rfd
		max: 5
	}
	mut event_loop := core.EventLoop{
		register: record_register
	}
	mut out := []u8{}
	expiry := u64(1)
	for tick in 1 .. 6 {
		written := C.write(wfd, &expiry, 8) // what a timerfd expiry reads as
		assert written == 8
		event_loop.last_watched = -1
		step := sse_tick(mut out, rfd, false, voidptr(st), unsafe { nil }, mut event_loop)
		if tick < 5 {
			assert step == .suspend, 'tick ${tick}'
			assert event_loop.last_watched == rfd, 'tick ${tick} must re-arm its timer'
		} else {
			assert step == .done, 'the last tick ends the request'
			assert event_loop.last_watched == -1, 'the last tick must not re-arm'
		}
	}
	C.close(wfd) // sse_tick already closed rfd (st.tfd) on the last tick
	assert out.bytestr() == want_chunks
	body, end := dechunk(out, 0) or { panic('the body does not end: ${out.bytestr()}') }
	assert body == want_events
	assert end == out.len
}

fn test_sse_tick_sizes_multi_digit_counters() {
	mut fds := [2]i32{}
	rc := C.pipe(unsafe { &fds[0] })
	assert rc == 0
	defer {
		C.close(int(fds[0]))
		C.close(int(fds[1]))
	}
	st := &Stream{
		tfd:  int(fds[0])
		sent: 9
		max:  120
	}
	mut event_loop := core.EventLoop{
		register: record_register
	}
	mut out := []u8{}
	expiry := u64(1)
	written := C.write(int(fds[1]), &expiry, 8)
	assert written == 8
	step := sse_tick(mut out, int(fds[0]), false, voidptr(st), unsafe { nil }, mut event_loop)
	assert step == .suspend
	// `data: tick 10 of 120\n\n` is 22 = 0x16 bytes.
	assert out.bytestr() == '16\r\ndata: tick 10 of 120\n\n\r\n'
}

// On the wire: the stream must end where the chunked framing says it does, and
// the same connection must then answer the next request. With the old
// close-delimited body the first round never completes.
fn test_sse_stream_ends_and_the_connection_stays_usable() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  events_req
					until: stream_ended
				},
				vtest.Round{
					send:  missing_req
					until: vtest.count('HTTP/1.1 404', 1)
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, 'the stream did not end: ${c.raw.bytestr()}'
	assert c.raw.bytestr() == sse_headers + want_chunks + not_found
	assert out.inflight_after == 0
	assert out.active_after == 0
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
	assert c.frames.len == 2
	assert c.frames[0].bytestr() == not_found
	assert c.frames[1].bytestr() == not_found
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
}
