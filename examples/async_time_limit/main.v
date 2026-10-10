module main

// Async-runtime example: a cooperative deadline over multi-step async work.
// `/job?steps=N` does N units of work (each a 50ms timer tick), but gives up
// with 504 the moment total elapsed time crosses a budget (300ms). The budget
// and remaining steps ride along in watch_payload; every continuation checks the
// clock before doing more, so a too-big job is cut off instead of running away.
//
// Run:   v run examples/async_time_limit/
// Try:   curl 'http://localhost:8095/job?steps=4'    # ~200ms  -> 200 completed
//        curl 'http://localhost:8095/job?steps=10'   # would be ~500ms -> 504
//
// This is the building block for per-request time limits on anything async (a
// slow upstream, a long query loop): one monotonic check per resume, no extra
// watch. (A single hard wall-clock deadline can also be a second timerfd — but
// v1 allows one in-flight watch per conn, so here we check the clock per step.)
import server
import core
import time
import strconv
import http1_1.request_parser
import http1_1.response

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const budget_ms = i64(300)

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_504_head = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: '

const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: '

const resp_head_end = '\r\nConnection: keep-alive\r\n\r\n'

// The literal parts of the two bodies:
//   deadline exceeded after <elapsed>ms (budget <budget_ms>ms)
//   completed within budget (~<elapsed>ms)
const exceeded_a = 'deadline exceeded after '

const exceeded_b = 'ms (budget '

const ms_close = 'ms)'

const completed_a = 'completed within budget (~'

const steps_key = 'steps'.bytes()

// Job is the per-request state carried across ticks via watch_payload.
struct Job {
mut:
	tfd   int // the periodic 50ms work-tick timerfd
	left  int // work steps still to do
	start i64 // time.ticks() at request start, for the elapsed-vs-budget check
}

fn arm_periodic(tfd int, ms int) {
	mut spec := [4]i64{}
	spec[0] = i64(ms / 1000)
	spec[1] = i64(ms % 1000) * 1_000_000
	spec[2] = spec[0]
	spec[3] = spec[1]
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
}

// parse_steps pulls N out of `/job?steps=N` in place (no copy): the leading
// digits of the value, defaulting to 10.
@[direct_array_access]
fn parse_steps(req request_parser.HttpRequest) int {
	v := req.get_query_slice(steps_key) or { return 10 }
	mut n := 0
	mut seen := false
	for i in 0 .. v.len {
		c := req.buffer[v.start + i]
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + int(c - `0`)
		seen = true
	}
	return if seen && n > 0 { n } else { 10 }
}

// route_is reports whether the request path, without its query string, is
// `lit`. req.path includes the query, so the compare stops at the first `?`.
// It compares bytes in place: the request is never copied.
@[direct_array_access]
fn route_is(req request_parser.HttpRequest, lit string) bool {
	mut n := 0
	for n < req.path.len && req.buffer[req.path.start + n] != `?` {
		n++
	}
	if n != lit.len {
		return false
	}
	for i in 0 .. n {
		if req.buffer[req.path.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// wi appends the decimal digits of n (zero-alloc: itoa into a stack scratch).
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// digits is the length of n in decimal (n >= 0), for a Content-Length.
@[inline]
fn digits(n i64) int {
	return strconv.dec_digits(u64(n))
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if !route_is(r, '/job') {
		core.append_str(mut out, not_found)
		return .done
	}
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 50)
	job := &Job{
		tfd:   tfd
		left:  parse_steps(r)
		start: time.ticks()
	}
	event_loop.watch_fd(tfd, .readable, tick, voidptr(job))
	return .suspend
}

// tick runs each 50ms: if we are over budget, 504; if all steps are done, 200;
// otherwise consume one step and re-arm.
fn tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	mut job := unsafe { &Job(watch_payload) }
	elapsed := time.ticks() - job.start
	if elapsed > budget_ms {
		C.close(job.tfd)
		core.append_str(mut out, resp_504_head)
		wi(mut out, exceeded_a.len + digits(elapsed) + exceeded_b.len + digits(budget_ms) +
			ms_close.len)
		core.append_str(mut out, resp_head_end)
		core.append_str(mut out, exceeded_a)
		wi(mut out, elapsed)
		core.append_str(mut out, exceeded_b)
		wi(mut out, budget_ms)
		core.append_str(mut out, ms_close)
		return .done
	}
	job.left--
	if job.left <= 0 {
		C.close(job.tfd)
		core.append_str(mut out, resp_200_head)
		wi(mut out, completed_a.len + digits(elapsed) + ms_close.len)
		core.append_str(mut out, resp_head_end)
		core.append_str(mut out, completed_a)
		wi(mut out, elapsed)
		core.append_str(mut out, ms_close)
		return .done
	}
	event_loop.watch_fd(job.tfd, .readable, tick, watch_payload) // more work to do
	return .suspend
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8095
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
