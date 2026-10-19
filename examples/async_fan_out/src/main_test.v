// vtest build: linux
// main.v needs <sys/timerfd.h>, an epoll aggregator and a backend with a
// watch reactor (Linux: epoll, io_uring).
module main

import os
import time
import core
import server
import transport
import testkit
import vtest
import http1_1.request_parser
import http1_1.response

fn get(target string) []u8 {
	return 'GET ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
}

fn one(target string) vtest.Script {
	return vtest.Script{
		rounds: [vtest.Round{
			send: get(target)
		}]
	}
}

fn config(backend server.IOBackend) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing: backend
		handler:         handle
		make_state:      new_state
		workers:         1 // one worker overlaps every member of every request
	}
}

// field reads the integer after `"key":` in a response body.
fn field(resp string, key string) int {
	return resp.all_after('"${key}":').int()
}

// open_fds counts this process's timerfds and epoll fds (/proc/self/fd): the
// members and aggregators of the fan-outs in flight, on top of the server's
// own epoll fds, which a baseline taken after start holds.
fn open_fds() (int, int) {
	mut timers := 0
	mut polls := 0
	for name in os.ls('/proc/self/fd') or { return -1, -1 } {
		link := os.readlink('/proc/self/fd/${name}') or { continue }
		if link == 'anon_inode:[timerfd]' {
			timers++
		} else if link == 'anon_inode:[eventpoll]' {
			polls++
		}
	}
	return timers, polls
}

// settle waits, for at most ms, until no more timerfds and epoll fds are open
// than the baseline; it returns the last counts. A leak never settles.
fn settle(base_timers int, base_polls int, ms int) (int, int) {
	mut t, mut p := open_fds()
	for _ in 0 .. ms / 5 {
		if t <= base_timers && p <= base_polls {
			break
		}
		time.sleep(5 * time.millisecond)
		t, p = open_fds()
	}
	return t, p
}

// wait_polls waits, for at most ms, until at least `want` epoll fds are open;
// the last count.
fn wait_polls(want int, ms int) int {
	_, mut p := open_fds()
	for _ in 0 .. ms / 5 {
		if p >= want {
			break
		}
		time.sleep(5 * time.millisecond)
		_, p = open_fds()
	}
	return p
}

// --- in process: the handler and its continuation, no server ----------------

// record_watch stands in for the backend's registration hook: it only records
// the fd, as the real one does in last_watched.
fn record_watch(mut event_loop core.EventLoop, ext_fd int, interest core.WatchInterest, continuation core.WakeFn, watch_payload voidptr) {
	event_loop.last_watched = ext_fd
}

// group_of is the group whose aggregator is agg: the watch payload the
// runtime would hand back.
fn group_of(state voidptr, agg int) voidptr {
	mut st := unsafe { &FanState(state) }
	for i in 0 .. st.groups.len {
		if st.groups[i].agg == agg {
			return unsafe { voidptr(&st.groups[i]) }
		}
	}
	return unsafe { nil }
}

// wait_readable waits, for at most ms, until a member of agg is ready (it
// consumes nothing: the members are level-triggered).
fn wait_readable(agg int, ms int) bool {
	mut idx := [max_members]i32{}
	for _ in 0 .. ms {
		if C.fan_ready(agg, &idx[0], max_members) > 0 {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

// cycle serves one request the way a worker does: the handler parks on the
// aggregator, then the continuation runs each time the aggregator is readable,
// until it answers.
fn cycle(state voidptr, req []u8, mut out []u8, mut event_loop core.EventLoop) core.Step {
	event_loop.last_watched = -1
	mut step := handle(req, mut out, -1, state, mut event_loop)
	for step == .suspend {
		agg := event_loop.last_watched
		if !wait_readable(agg, 3000) {
			return .close
		}
		event_loop.last_watched = -1
		step = on_ready(mut out, agg, false, group_of(state, agg), state, mut event_loop)
	}
	return step
}

// n_ms_budget is what the handler reads from `target`: [n, ms, budget].
fn n_ms_budget(target string) []int {
	r := request_parser.decode_http_request(get(target)) or { panic(err) }
	return [query_int(r, n_key, default_n, max_members), query_int(r, ms_key, default_ms, max_ms),
		query_int(r, budget_key, 0, max_ms)]
}

fn test_query_defaults_and_caps() {
	assert n_ms_budget('/fan') == [default_n, default_ms, 0]
	assert n_ms_budget('/fan?n=3&ms=40&budget=90') == [3, 40, 90]
	assert n_ms_budget('/fan?budget=7&ms=1&n=1') == [1, 1, 7]
	assert n_ms_budget('/fan?n=0&ms=&budget=x') == [default_n, default_ms, 0]
	assert n_ms_budget('/fan?n=-2&ms=12x') == [default_n, default_ms, 0]
	assert n_ms_budget('/fan?n=33&ms=10001&budget=99999999999999999999') == [
		max_members,
		max_ms,
		max_ms,
	]
}

fn test_member_delays_spread_up_to_ms() {
	assert [0, 1, 2, 7].map(member_delay(400, 8, it)) == [50, 100, 150, 400]
	assert sum_ms(400, 8) == 1800
	assert sum_ms(200, 1) == 200
	// A delay that rounds down to 0 would disarm its timerfd: 1 ms instead.
	assert member_delay(5, 32, 0) == 1
	assert member_delay(5, 32, 31) == 5
}

// A park armed with time_left() never ends before the budget does, even when
// a millisecond boundary passes between launch and park (vanilla#373: a start
// truncated to the ms made that park 1 ms short, and the 504 came at 1499 ms
// of a 1500 ms budget). Each try starts up to 1 ms in the past, so a boundary
// falls between start and park in about half of them.
fn test_time_left_never_ends_before_the_budget() {
	mut g := Group{
		budget: 1500
	}
	for i in 0 .. 2000 {
		g.start = now_ns() - i64(i % 1000) * 1000
		tl := g.time_left()
		read := now_ns() // no earlier than the clock read inside time_left
		assert tl <= g.budget
		assert read + i64(tl) * 1_000_000 >= g.start + i64(g.budget) * 1_000_000, 'a ${tl} ms park ends before the ${g.budget} ms budget'
	}
	g.start = now_ns() - 3 * i64(g.budget) * 1_000_000
	assert g.time_left() == 1, 'spent: the shortest deadline'
	g.budget = 0
	assert g.time_left() == 0, 'no budget: Limits.park_timeout_ms'
}

fn test_other_paths_404_and_bad_requests_close() {
	state := new_state()
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert handle(get('/fans'), mut out, -1, state, mut event_loop) == .done
	assert out.bytestr() == not_found
	out.clear()
	assert handle('GET\r\n\r\n'.bytes(), mut out, -1, state, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
	assert event_loop.last_watched == -1
}

// Every member finishes: one 200, its Content-Length the body's, and every
// fd the request opened is closed.
fn test_cycle_answers_and_closes_every_fd() {
	base_t, base_p := open_fds()
	state := new_state()
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert cycle(state, get('/fan?n=5&ms=30'), mut out, mut event_loop) == .done
	resp := out.bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
	body := resp.all_after('\r\n\r\n')
	assert resp.all_after('Content-Length: ').int() == body.len
	assert body.starts_with('{"n":5,"done":5,"elapsed_ms":')
	assert body.ends_with(',"slowest_ms":30,"sum_ms":${sum_ms(30, 5)}}')
	assert field(body, 'elapsed_ms') >= 30
	t, p := open_fds()
	assert t == base_t && p == base_p, 'left open: ${t - base_t} timerfds, ${p - base_p} epoll fds'
}

// The budget runs out first (the epoll worker's park deadline): the
// continuation answers 504 with what arrived and cancels the rest. The
// runtime then keeps the watch as a tombstone and runs the continuation again,
// orphaned (against a discarded buffer), while the aggregator is readable:
// here, at once (the cancelled timers fire now, not in 10 s). That run closes
// everything.
fn test_budget_answers_504_and_the_tombstone_run_closes_everything() {
	base_t, base_p := open_fds()
	state := new_state()
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert handle(get('/fan?n=4&ms=10000&budget=50'), mut out, -1, state, mut event_loop) == .suspend
	agg := event_loop.last_watched
	assert agg >= 0
	assert event_loop.timeout_ms > 0 && event_loop.timeout_ms <= 50, 'the budget is the park deadline'
	t, p := open_fds()
	assert t == base_t + 4 && p == base_p + 1
	event_loop.reason = .timeout
	event_loop.last_watched = -1
	assert on_ready(mut out, agg, false, group_of(state, agg), state, mut event_loop) == .done
	assert event_loop.last_watched == -1
	resp := out.bytestr()
	assert resp.starts_with('HTTP/1.1 504 Gateway Timeout\r\n')
	assert resp.all_after('Content-Length: ').int() == resp.all_after('\r\n\r\n').len
	assert resp.contains('{"n":4,"done":0,')
	event_loop.reason = .orphaned // as the runtime runs a tombstone
	mut scratch := []u8{}
	mut runs := 0
	for {
		assert wait_readable(agg, 2000), 'the cancelled members never fired'
		event_loop.last_watched = -1
		step := on_ready(mut scratch, agg, false, group_of(state, agg), state, mut event_loop)
		runs++
		if step == .done {
			break
		}
		assert step == .suspend && event_loop.last_watched == agg
		assert runs < 10
	}
	assert scratch.len == 0, 'a run after the answer must not write one'
	t2, p2 := open_fds()
	assert t2 == base_t && p2 == base_p, 'left open: ${t2 - base_t} timerfds, ${p2 - base_p} epoll fds'
}

// Every group of the worker in flight: the next request is shed, honestly.
fn test_sheds_503_when_every_group_is_in_flight() {
	state := new_state()
	mut st := unsafe { &FanState(state) }
	st.free = -1
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert handle(get('/fan'), mut out, -1, state, mut event_loop) == .done
	assert out.bytestr() == resp_503
	assert event_loop.last_watched == -1
}

// A backend that cannot watch (IOCP, poll) refuses the watch: 503, and the
// request's fds are closed.
fn test_a_refused_watch_answers_503_and_closes_every_fd() {
	base_t, base_p := open_fds()
	state := new_state()
	mut event_loop := core.EventLoop{
		register: core.reject_register
	}
	mut out := []u8{}
	assert handle(get('/fan?n=3'), mut out, -1, state, mut event_loop) == .done
	assert out.bytestr() == resp_503
	t, p := open_fds()
	assert t == base_t && p == base_p
}

// The aggregator wakes with an error: 502, and every fd closed.
fn test_a_failed_aggregator_answers_502_and_closes_every_fd() {
	base_t, base_p := open_fds()
	state := new_state()
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert handle(get('/fan?n=3&ms=5000'), mut out, -1, state, mut event_loop) == .suspend
	agg := event_loop.last_watched
	event_loop.last_watched = -1
	assert on_ready(mut out, agg, true, group_of(state, agg), state, mut event_loop) == .done
	assert out.bytestr() == resp_502
	assert event_loop.last_watched == -1, 'a failed aggregator must not be watched again'
	t, p := open_fds()
	assert t == base_t && p == base_p
}

// Members are left but the aggregator cannot be watched again: nothing would
// resume the request, so it answers 502 at once and closes every fd.
fn test_a_refused_rearm_answers_502_and_closes_every_fd() {
	base_t, base_p := open_fds()
	state := new_state()
	mut event_loop := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	assert handle(get('/fan?n=2&ms=5000'), mut out, -1, state, mut event_loop) == .suspend
	agg := event_loop.last_watched
	event_loop.register = core.reject_register
	event_loop.last_watched = -1
	assert on_ready(mut out, agg, false, group_of(state, agg), state, mut event_loop) == .done
	assert out.bytestr() == resp_502
	t, p := open_fds()
	assert t == base_t && p == base_p
}

// A whole fan-out, handler and continuation runs, allocates nothing (under
// -gc none, the production build, an allocation would be a leak per request).
fn test_a_fan_out_allocates_nothing() {
	$if gcboehm ? {
		state := new_state()
		req := get('/fan?n=4&ms=1')
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{
			register: record_watch
		}
		assert cycle(state, req, mut out, mut event_loop) == .done // warm-up
		rounds := 200
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			cycle(state, req, mut out, mut event_loop)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the fan-out allocated ${grown} bytes over ${rounds} requests'
	}
}

// --- on a live server ---------------------------------------------------------

// check_overlap: eight requests, sixteen members each, all on one worker.
// Members one after the other would take sum_ms(400, 16) = 3400 ms for ONE
// request; overlapped, every request takes its slowest member, 400 ms, and so
// do all eight together. The margins are wide: the lower bound is a hard one
// (no timer fires early), the upper one is the sequential sum.
fn check_overlap(backend server.IOBackend) ! {
	mut h := vtest.start(config(backend))!
	defer {
		h.stop()
	}
	base_t, base_p := open_fds()
	sum := sum_ms(400, 16)
	sw := time.new_stopwatch()
	out := h.fire(vtest.repeat(8, one('/fan?n=16&ms=400')))!
	el := sw.elapsed().milliseconds()
	for c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert c.frames.len == 1
		resp := c.frames[0].bytestr()
		assert resp.starts_with('HTTP/1.1 200 OK\r\n'), resp
		assert resp.contains('{"n":16,"done":16,'), resp
		e := field(resp, 'elapsed_ms')
		assert e >= 400 && e < sum, '${backend}: a request took ${e} ms; its members one after the other take ${sum} ms'
	}
	assert el >= 400, '${backend}: answered after ${el} ms, before the slowest member'
	assert el < sum, '${backend}: 8 requests took ${el} ms; ONE request with its members in sequence takes ${sum} ms'
	t, p := settle(base_t, base_p, 3000)
	assert t <= base_t && p <= base_p, '${backend}: left open: ${t - base_t} timerfds, ${p - base_p} epoll fds'
}

// check_disconnect: four clients park on fan-outs, then hang up. Nobody gets
// an answer, and still every member and every aggregator is closed once the
// members finish: on epoll by the tombstone the runtime keeps for the
// caller-owned watch, on io_uring by the resume it runs anyway. (A
// request-owned watch_fd would have had the runtime close the aggregator on
// the hangup, and the 32 members would stay open for good.) The worker then
// serves on.
fn check_disconnect(backend server.IOBackend) ! {
	mut h := vtest.start(config(backend))!
	defer {
		h.stop()
	}
	base_t, base_p := open_fds()
	mut fds := []int{}
	for _ in 0 .. 4 {
		fd := transport.dial_tcp('127.0.0.1', h.port())!
		fds << fd
		assert testkit.fd_write_all(fd, get('/fan?n=8&ms=1500'), 3000)
	}
	// Parked: each request's aggregator is open until its slowest member.
	polls := wait_polls(base_p + 4, 3000)
	t0, _ := open_fds()
	for fd in fds {
		transport.close_fd(fd)
	}
	assert polls >= base_p + 4, '${backend}: ${polls - base_p} of 4 fan-outs parked'
	assert t0 > base_t, '${backend}: no member open'
	t, p := settle(base_t, base_p, 6000)
	assert t <= base_t && p <= base_p, '${backend}: after the hangups, left open: ${t - base_t} timerfds, ${p - base_p} epoll fds'
	out := h.fire([one('/fan?n=2&ms=10')])!
	assert out.conns[0].frames.len == 1
	assert out.conns[0].frames[0].bytestr().contains('{"n":2,"done":2,')
}

fn test_epoll_members_and_requests_overlap() ! {
	check_overlap(.epoll)!
}

fn test_epoll_client_disconnect_closes_every_fd() ! {
	check_disconnect(.epoll)!
}

// The budget on the wire (epoll enforces park deadlines): members fire at
// 1000, 2000, ... 10000 ms, the budget is 1500 ms. The 1000 ms member makes
// it; the 504 comes at the budget; the other nine are cancelled, so their
// fds close right away instead of when the slowest would fire (10 s).
fn test_epoll_budget_answers_504_and_cancels_the_rest() ! {
	mut h := vtest.start(config(.epoll))!
	defer {
		h.stop()
	}
	base_t, base_p := open_fds()
	sw := time.new_stopwatch()
	out := h.fire([one('/fan?n=10&ms=10000&budget=1500')])!
	el := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.frames.len == 1
	resp := c.frames[0].bytestr()
	assert resp.starts_with('HTTP/1.1 504 Gateway Timeout\r\n'), resp
	assert resp.contains('{"n":10,"done":1,'), resp
	assert el >= 1500 && el < 10_000, 'answered after ${el} ms'
	t, p := settle(base_t, base_p, 3000)
	assert t <= base_t && p <= base_p, 'left open: ${t - base_t} timerfds, ${p - base_p} epoll fds'
}

// io_uring: no park deadlines there (the budget is not enforced), the rest is
// the same. Self-skipping where io_uring_setup is blocked or
// VANILLA_NO_IOURING is set.

fn test_iouring_members_and_requests_overlap() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_overlap(.io_uring)!
}

fn test_iouring_client_disconnect_closes_every_fd() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_disconnect(.io_uring)!
}
