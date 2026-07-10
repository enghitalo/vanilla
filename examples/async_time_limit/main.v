module main

// Async-runtime example: a cooperative deadline over multi-step async work.
// `/job?steps=N` does N units of work (each a 50ms timer tick), but gives up
// with 504 the moment total elapsed time crosses a budget (300ms). The budget
// and remaining steps ride along in worker.udata; every continuation checks the
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
import http_server
import http_server.core
import time

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const budget_ms = i64(300)

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// Job is the per-request state carried across ticks via worker.udata.
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
	C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
}

// parse_steps pulls N out of `/job?steps=N`, defaulting to 10.
fn parse_steps(req []u8) int {
	s := req.bytestr()
	idx := s.index('steps=') or { return 10 }
	mut n := 0
	mut seen := false
	for i := idx + 6; i < s.len && s[i] >= `0` && s[i] <= `9`; i++ {
		n = n * 10 + int(s[i] - `0`)
		seen = true
	}
	return if seen && n > 0 { n } else { 10 }
}

fn handle(req []u8, mut out []u8, mut worker core.Worker) core.Step {
	if !req.bytestr().contains('/job') {
		out << not_found
		return .done
	}
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 50)
	job := &Job{
		tfd:   tfd
		left:  parse_steps(req)
		start: time.ticks()
	}
	worker.watch(tfd, .readable, tick, voidptr(job))
	return .suspend
}

// tick runs each 50ms: if we are over budget, 504; if all steps are done, 200;
// otherwise consume one step and re-arm.
fn tick(mut out []u8, mut worker core.Worker) core.Step {
	mut tmp := [8]u8{}
	C.read(worker.ready_fd(), &tmp[0], 8)
	mut job := unsafe { &Job(worker.udata) }
	elapsed := time.ticks() - job.start
	if elapsed > budget_ms {
		C.close(job.tfd)
		body := 'deadline exceeded after ${elapsed}ms (budget ${budget_ms}ms)'
		out << 'HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
		return .done
	}
	job.left--
	if job.left <= 0 {
		C.close(job.tfd)
		body := 'completed within budget (~${elapsed}ms)'
		out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
		return .done
	}
	worker.watch(job.tfd, .readable, tick, worker.udata) // more work to do
	return .suspend
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8095
		io_multiplexing: .epoll
		handler:         handle
	})!
	server.run()
}
