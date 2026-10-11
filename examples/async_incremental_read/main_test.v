// vtest build: linux
// main.v streams a popen(3) pipe through the epoll watch reactor (Linux only).
module main

import core
import server
import vtest
import http1_1.response

fn C.pipe(fds &i32) int
fn C.write(fd int, buf voidptr, n usize) int

const stream_req = 'GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const missing_req = 'GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

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

// stream_ended holds once the whole chunked body has arrived.
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
		0:    '0'
		7:    '7'
		10:   'a'
		255:  'ff'
		4096: '1000'
	} {
		mut out := []u8{}
		wx(mut out, n)
		assert out.bytestr() == want, 'wx(${n})'
	}
}

// record_register stands in for the backend's watch registration: it records
// the fd the way the reactor does, and arms nothing.
fn record_register(mut event_loop core.EventLoop, ext_fd int, interest core.WatchInterest, continuation core.WakeFn, watch_payload voidptr) {
	event_loop.last_watched = ext_fd
}

// on_chunk, driven directly over a pipe: each wake frames what the pipe holds
// as one chunk, after whatever `out` already has (out starts with no capacity,
// so the first wake grows it); a 5000-byte write takes a full 4 KiB chunk and
// then the rest; and a wake that finds nothing (EAGAIN) appends nothing and
// re-arms.
fn test_on_chunk_frames_what_the_pipe_holds() {
	mut fds := [2]i32{}
	assert C.pipe(unsafe { &fds[0] }) == 0
	rfd := int(fds[0])
	wfd := int(fds[1])
	defer {
		C.close(rfd)
		C.close(wfd)
	}
	C.fcntl(rfd, C.F_SETFL, C.O_NONBLOCK)
	mut event_loop := core.EventLoop{
		register: record_register
	}
	mut out := []u8{}
	out << `>`
	line := 'line 1\n'
	assert C.write(wfd, line.str, usize(line.len)) == line.len
	step := on_chunk(mut out, rfd, false, unsafe { nil }, unsafe { nil }, mut event_loop)
	assert step == .suspend
	assert event_loop.last_watched == rfd
	assert out.bytestr() == '>7\r\nline 1\n\r\n'
	mut big := []u8{len: 5000}
	for i in 0 .. big.len {
		big[i] = u8(`a` + i % 26)
	}
	assert C.write(wfd, big.data, usize(big.len)) == big.len
	on_chunk(mut out, rfd, false, unsafe { nil }, unsafe { nil }, mut event_loop)
	on_chunk(mut out, rfd, false, unsafe { nil }, unsafe { nil }, mut event_loop)
	want := '>7\r\nline 1\n\r\n' + '1000\r\n' + big[..4096].bytestr() + '\r\n' + '388\r\n' +
		big[4096..].bytestr() + '\r\n'
	assert out.bytestr() == want
	event_loop.last_watched = -1
	step2 := on_chunk(mut out, rfd, false, unsafe { nil }, unsafe { nil }, mut event_loop)
	assert step2 == .suspend
	assert event_loop.last_watched == rfd, 'EAGAIN must re-arm'
	assert out.bytestr() == want, 'EAGAIN must append nothing'
}

// On the wire: every chunk must be well formed (its hex size matches its data),
// the body must end with the zero-size chunk, and the same connection must
// then answer the next request.
fn test_stream_forwards_every_line_as_chunks_and_ends() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  stream_req
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
	raw := c.raw.bytestr()
	assert raw.starts_with(chunk_headers), raw
	body, end := dechunk(c.raw, chunk_headers.len) or { panic('malformed chunked body: ${raw}') }
	assert body == 'line 1\nline 2\nline 3\nline 4\nline 5\n'
	assert raw[end..] == not_found
	assert out.inflight_after == 0
	assert out.active_after == 0
}

fn test_other_paths_get_404_and_bad_requests_close() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /streams HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: 'GET /x?stream HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
			]
		},
		vtest.Script{
			rounds:   [vtest.Round{
				send: 'GET\r\n\r\n'.bytes()
			}]
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
