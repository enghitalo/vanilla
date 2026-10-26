// vtest build: linux
// main.v streams a posix_spawn(3) pipe through the epoll watch reactor (Linux only).
module main

import core
import os
import server
import strconv
import time
import vtest
import http1_1.response

#include <fcntl.h>
#include <sys/resource.h>
#include "@VMODROOT/core/libc_shim.h"

fn C.vanilla_read(fd int, buf voidptr, count u64) int

fn C.pipe(fds &i32) int
fn C.vanilla_write(fd int, buf voidptr, n u64) int
fn C.fcntl(fd int, cmd int, arg int) int

struct C.rlimit {
mut:
	rlim_cur u64
	rlim_max u64
}

fn C.getrlimit(resource int, rlim &C.rlimit) int
fn C.setrlimit(resource int, rlim &C.rlimit) int

const stream_req = 'GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const missing_req = 'GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

// Like main() for the server, have the kernel reap every producer the tests
// start, from before the first one.
fn testsuite_begin() {
	ignore_sigchld()
}

// lowest_free_fd is the number the kernel gives the next new fd. The same
// value before and after a failed spawn means it closed what it opened.
fn lowest_free_fd() !int {
	mut f := os.open('/dev/null')!
	fd := f.fd
	f.close()
	return fd
}

// signal_mask returns the `name` mask (SigIgn, say) of a /proc/<pid>/status
// text: bit n-1 stands for signal n.
fn signal_mask(status string, name string) !u64 {
	for line in status.split_into_lines() {
		if line.starts_with(name + ':') {
			return strconv.parse_uint(line.all_after(':').trim_space(), 16, 64)!
		}
	}
	return error('no ${name} line in: ${status}')
}

// zombie_children lists the children of this process that exited and were
// never reaped: the /proc/<pid>/stat entries in state Z whose ppid is this
// process.
fn zombie_children() []int {
	me := os.getpid()
	mut found := []int{}
	for name in os.ls('/proc') or { []string{} } {
		if name.len == 0 || !name[0].is_digit() {
			continue
		}
		stat := os.read_file('/proc/${name}/stat') or { continue } // exited since ls
		// `pid (comm) state ppid ...`, where comm may hold spaces and parens.
		f := stat.all_after_last(')').fields()
		if f.len > 1 && f[0] == 'Z' && f[1].int() == me {
			found << name.int()
		}
	}
	return found
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

// A /stream whose producer cannot start gets 503 and parks nothing. The fd
// limit is lowered to the next free fd number, so the producer's pipe cannot
// be opened (EMFILE). It runs before the tests that start a server, whose
// threads would otherwise share the limit.
fn test_stream_answers_503_when_the_producer_cannot_start() ! {
	mut saved := C.rlimit{}
	assert C.getrlimit(C.RLIMIT_NOFILE, &saved) == 0
	mut full := saved
	full.rlim_cur = u64(lowest_free_fd()!)
	assert C.setrlimit(C.RLIMIT_NOFILE, &full) == 0
	mut event_loop := core.EventLoop{
		register: record_register
	}
	mut out := []u8{}
	step := handle(stream_req, mut out, -1, unsafe { nil }, mut event_loop)
	C.setrlimit(C.RLIMIT_NOFILE, &saved)
	assert step == .done
	assert out.bytestr() == service_unavailable
	assert event_loop.last_watched == -1, 'a failed spawn must watch nothing'
}

// A spawn that fails (no shell at that path) returns -1 and closes both ends
// of the pipe it had opened.
fn test_failed_spawn_leaves_no_fd_open() ! {
	before := lowest_free_fd()!
	assert C.spawn_producer(c'/nonexistent/sh', producer) == -1
	assert lowest_free_fd()! == before
}

// The producer starts with SIGPIPE and SIGCHLD at their default actions,
// though this process ignores both: SIGPIPE as new_server would (set by hand:
// no server has started yet), SIGCHLD from testsuite_begin. The probe execs
// grep in the shell's place, which keeps the shell's signal dispositions, to
// print its own SigIgn mask down the pipe.
fn test_producer_starts_with_default_sigpipe_and_sigchld() ! {
	unsafe { C.signal(C.SIGPIPE, C.SIG_IGN) }
	pipe_bit := u64(1) << (C.SIGPIPE - 1)
	chld_bit := u64(1) << (C.SIGCHLD - 1)
	ours := signal_mask(os.read_file('/proc/self/status')!, 'SigIgn')!
	assert ours & pipe_bit != 0 && ours & chld_bit != 0, 'this process must ignore both'
	fd := C.spawn_producer(c'/bin/sh', c'exec grep "^SigIgn:" /proc/self/status')
	assert fd >= 0
	C.fcntl(fd, C.F_SETFL, 0) // blocking: read up to EOF
	mut got := []u8{}
	mut buf := [256]u8{}
	for {
		n := C.vanilla_read(fd, &buf[0], buf.len)
		if n <= 0 {
			break
		}
		unsafe { got.push_many(&buf[0], n) }
	}
	C.close(fd)
	status := got.bytestr()
	ign := signal_mask(status, 'SigIgn')!
	assert ign & pipe_bit == 0, 'the producer ignores SIGPIPE: ${status}'
	assert ign & chld_bit == 0, 'the producer ignores SIGCHLD: ${status}'
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
	assert C.vanilla_write(wfd, line.str, u64(line.len)) == line.len
	step := on_chunk(mut out, rfd, false, unsafe { nil }, unsafe { nil }, mut event_loop)
	assert step == .suspend
	assert event_loop.last_watched == rfd
	assert out.bytestr() == '>7\r\nline 1\n\r\n'
	mut big := []u8{len: 5000}
	for i in 0 .. big.len {
		big[i] = u8(`a` + i % 26)
	}
	assert C.vanilla_write(wfd, big.data, u64(big.len)) == big.len
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

// A client that disconnects mid-stream leaves no zombie (#292). The client
// closes once the first line is in; at least 1.5 s later, when even a
// producer that ran its whole 1 s loop has exited, no child of this process
// may be a zombie (it ignores SIGCHLD, as main() does). Here the producer
// does run that whole loop: it also holds a copy of the client's socket
// (vtest's sockets are not close-on-exec, and client and server share this
// process), so the close reaches the server only when the producer exits.
fn test_a_client_leaving_mid_stream_leaves_no_zombie() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  stream_req
					until: vtest.count('line 1\n', 1)
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, c.raw.bytestr()
	assert out.inflight_after == 0
	assert out.active_after == 0
	time.sleep(1500 * time.millisecond)
	zombies := zombie_children()
	assert zombies.len == 0, 'zombie children: ${zombies}'
}
