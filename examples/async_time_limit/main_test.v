// vtest build: linux
// main.v needs <sys/timerfd.h> and the epoll watch reactor (Linux only).
module main

import core
import time
import server
import vtest
import http1_1.request_parser
import http1_1.response

#include <unistd.h>

fn C.pipe(fds &i32) int
fn C.write(fd int, buf voidptr, n usize) int

fn get(target string) []u8 {
	return 'GET ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
}

fn steps_of(target string) int {
	req := request_parser.decode_http_request(get(target)) or { panic(err) }
	return parse_steps(req)
}

// record_register stands in for the backend's watch registration: it records
// the fd the way the reactor does, and arms nothing.
fn record_register(mut event_loop core.EventLoop, ext_fd int, interest core.WatchInterest, continuation core.WakeFn, watch_payload voidptr) {
	event_loop.last_watched = ext_fd
}

// framed_body checks that a response's Content-Length matches its body and
// returns the body. The bodies are built from parts now, with the length
// computed up front, so the two must agree.
fn framed_body(resp string) string {
	head_end := resp.index('\r\n\r\n') or { panic('no head end in ${resp}') }
	head := resp[..head_end]
	body := resp[head_end + 4..]
	cl := head.all_after('Content-Length: ').all_before('\r\n').int()
	assert cl == body.len, 'Content-Length ${cl} for a ${body.len}-byte body: ${resp}'
	return body
}

// number_between returns the decimal number between prefix and suffix in s.
fn number_between(s string, prefix string, suffix string) i64 {
	assert s.starts_with(prefix), s
	assert s.ends_with(suffix), s
	digits_ := s[prefix.len..s.len - suffix.len]
	assert digits_.len > 0 && digits_.bytes().all(it >= `0` && it <= `9`), s
	return digits_.i64()
}

fn test_parse_steps_reads_the_query() {
	assert steps_of('/job?steps=4') == 4
	assert steps_of('/job?a=1&steps=7') == 7
	assert steps_of('/job?steps=12x') == 12
	assert steps_of('/job') == 10
	assert steps_of('/job?steps=') == 10
	assert steps_of('/job?steps=0') == 10
	assert steps_of('/job?steps=abc') == 10
	assert steps_of('/job?xsteps=3') == 10
}

// tick, driven directly with a start time far in the past: the 504 must carry
// a Content-Length that matches its body for elapsed values of any width.
fn test_tick_frames_the_504_for_any_elapsed_width() {
	for ago in [i64(301), 9_999, 1_000_000, 12_345_678_901] {
		mut fds := [2]i32{}
		rc := C.pipe(unsafe { &fds[0] })
		assert rc == 0
		expiry := u64(1)
		written := C.write(int(fds[1]), &expiry, 8)
		assert written == 8
		job := &Job{
			tfd:   int(fds[0])
			left:  10
			start: time.ticks() - ago
		}
		mut event_loop := core.EventLoop{
			register: record_register
		}
		mut out := []u8{}
		step := tick(mut out, int(fds[0]), false, voidptr(job), unsafe { nil }, mut event_loop)
		C.close(int(fds[1])) // tick closed fds[0] (job.tfd)
		assert step == .done
		resp := out.bytestr()
		assert resp.starts_with('HTTP/1.1 504 Gateway Timeout\r\n'), resp
		elapsed := number_between(framed_body(resp), 'deadline exceeded after ', 'ms (budget 300ms)')
		assert elapsed >= ago
	}
}

fn test_tick_frames_the_200_when_the_work_is_done() {
	mut fds := [2]i32{}
	rc := C.pipe(unsafe { &fds[0] })
	assert rc == 0
	expiry := u64(1)
	written := C.write(int(fds[1]), &expiry, 8)
	assert written == 8
	job := &Job{
		tfd:   int(fds[0])
		left:  1
		start: time.ticks() - 42
	}
	mut event_loop := core.EventLoop{
		register: record_register
	}
	mut out := []u8{}
	step := tick(mut out, int(fds[0]), false, voidptr(job), unsafe { nil }, mut event_loop)
	C.close(int(fds[1]))
	assert step == .done
	resp := out.bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK\r\n'), resp
	elapsed := number_between(framed_body(resp), 'completed within budget (~', 'ms)')
	assert elapsed >= 42
}

// On the wire, all on one keep-alive connection: a job within budget, a job
// over budget, then a 404. A wrong Content-Length on either job response would
// misframe everything after it.
fn test_jobs_end_to_end() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: get('/job?steps=2')
				},
				vtest.Round{
					send: get('/job?steps=10')
				},
				vtest.Round{
					send: get('/jobs')
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
	assert c.frames.len == 3
	ok := c.frames[0].bytestr()
	assert ok.starts_with('HTTP/1.1 200 OK\r\n'), ok
	_ := number_between(framed_body(ok), 'completed within budget (~', 'ms)')
	late := c.frames[1].bytestr()
	assert late.starts_with('HTTP/1.1 504 Gateway Timeout\r\n'), late
	elapsed := number_between(framed_body(late), 'deadline exceeded after ', 'ms (budget 300ms)')
	assert elapsed > budget_ms
	assert c.frames[2].bytestr() == not_found
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
	assert out.active_after == 0
}
