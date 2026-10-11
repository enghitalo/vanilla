// vtest build: linux
// main.v arms its watch from on_worker_start, which only the Linux epoll
// backend runs.
module main

import time
import core
import server
import vtest

const want_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const get_req = 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

fn test_handler_answers_ok() {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(get_req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	assert out.bytestr() == want_ok
}

// record_watch stands in for the backend's registration hook: it only records
// the fd, as the real one does in last_watched.
fn record_watch(mut event_loop core.EventLoop, ext_fd int, interest core.WatchInterest, continuation core.WakeFn, watch_payload voidptr) {
	event_loop.last_watched = ext_fd
}

// On a hangup the continuation hands the fd back (.close: the runtime closes
// it) and does NOT re-arm: re-arming a level-triggered watch on a dead fd
// would wake the worker on every loop iteration.
fn test_hangup_releases_the_fd_without_rearming() {
	mut out := []u8{}
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	assert on_source_event(mut out, 42, true, unsafe { nil }, unsafe { nil }, mut event_loop) == .close
	assert event_loop.last_watched == -1, 'a hung-up fd must not be watched again'
	assert out.len == 0
}

// Ready data (no error) keeps the watch alive on the same fd.
fn test_ready_fd_is_watched_again() {
	mut out := []u8{}
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	assert on_source_event(mut out, 42, false, unsafe { nil }, unsafe { nil }, mut event_loop) == .suspend
	assert event_loop.last_watched == 42
	assert out.len == 0
}

// process_cpu_ms is the CPU time every thread of this process has used:
// server workers, the vtest reactor and the test itself.
fn process_cpu_ms() i64 {
	mut ts := C.timespec{}
	C.clock_gettime(C.CLOCK_PROCESS_CPUTIME_ID, &ts)
	return i64(ts.tv_sec) * 1000 + i64(ts.tv_nsec) / 1_000_000
}

// The real thing: every worker's on_start arms a watch on a pipe whose writer
// is already closed, so each watch fires with a hangup the moment its worker
// starts. The server must keep serving, and it must go IDLE: one served
// request, then a quiet keep-alive connection that only the server's idle
// deadline ends. The process's CPU time over that wait (the server's clock,
// not the test's) tells an idle worker from one spinning on a dead fd, which
// would burn a whole core for the entire wait.
fn test_server_serves_and_idles_after_the_hangup() ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
		on_worker_start: on_start
		limits:          server.Limits{
			read_timeout_ms: 30_000
			idle_timeout_ms: 400
		}
	})!
	defer {
		h.stop()
	}
	cpu_before := process_cpu_ms()
	sw := time.new_stopwatch()
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: get_req
				},
				vtest.Round{
					send: []u8{}
					want: 0
				},
			]
			then_eof: true
		},
	])!
	elapsed := sw.elapsed().milliseconds()
	cpu := process_cpu_ms() - cpu_before
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1
	assert c.frames[0].bytestr() == want_ok
	assert c.eof, 'the idle deadline must end the quiet connection'
	assert elapsed >= 300, 'the connection ended after ${elapsed} ms, before the idle deadline'
	assert cpu < elapsed / 2, 'the process used ${cpu} ms of CPU over ${elapsed} ms of idle server: a worker is spinning'
}
