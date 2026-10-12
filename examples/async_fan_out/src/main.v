module main

// Async-runtime example: fan-out. One request starts N operations at once and
// answers when the last one finishes, so its latency is the slowest
// operation's, not the sum of all of them.
//
// `/fan?n=8&ms=200` arms N one-shot timers, member i firing after
// ms*(i+1)/n ms: they stand in for N upstream calls of different speeds.
// A request still parks on ONE fd: an epoll instance of its own, the
// aggregator, with the N members registered in it. The aggregator is readable
// whenever a member is, so each wake drains the members that finished
// (epoll_wait with a zero timeout) and parks again until none is left.
// `&budget=150` bounds the whole fan-out: when it runs out first, the request
// is answered 504 with how many members made it, and the rest are cancelled.
//
// Run:   v -prod run examples/async_fan_out/src
// Try:   curl 'http://localhost:8100/fan?n=8&ms=400'
//        # -> {"n":8,"done":8,"elapsed_ms":400,"slowest_ms":400,"sum_ms":1800}
//        curl 'http://localhost:8100/fan?n=8&ms=400&budget=180'
//        # -> 504 {"n":8,"done":3,"elapsed_ms":180,"slowest_ms":400,"sum_ms":1800}
//
// Who closes what: the request owns the member fds and the aggregator, and
// the continuation closes every one of them on every path. That is why the
// aggregator is watched with watch_fd_persistent_deadline and not watch_fd:
// on a client disconnect (or a deadline), the epoll worker turns a
// caller-owned watch into a tombstone whose continuation still runs when the
// aggregator is ready, so it drains and closes the members. A request-owned
// watch_fd fd would instead be closed by the runtime, without the
// continuation, and the N members would leak. See README.md.
import server
import core
import time
import strconv
import http1_1.request_parser
import http1_1.response

#include <sys/timerfd.h>
#include <unistd.h>
#include "@VMODROOT/examples/async_fan_out/src/fan_out.h"

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.close(fd int) int
fn C.fan_open() int
fn C.fan_add(agg int, fd int, idx int) int
fn C.fan_ready(agg int, idx &i32, max int) int

// max_members caps n: the members of one request (fan_ready takes up to 64).
const max_members = 32

// groups_per_worker is how many fan-outs one worker runs at once. Past it a
// request is shed with 503.
const groups_per_worker = 256

const default_n = 8

const default_ms = 200

// max_ms caps ms and budget, so a client cannot park a request (or hold its
// members) for hours.
const max_ms = 10_000

const n_key = 'n'.bytes()

const ms_key = 'ms'.bytes()

const budget_key = 'budget'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_502 = 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '

const resp_504_head = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Type: application/json\r\nContent-Length: '

const resp_head_end = '\r\nConnection: keep-alive\r\n\r\n'

// The literal parts of the body:
//   {"n":<n>,"done":<done>,"elapsed_ms":<ms>,"slowest_ms":<ms>,"sum_ms":<ms>}
const body_n = '{"n":'

const body_done = ',"done":'

const body_elapsed = ',"elapsed_ms":'

const body_slowest = ',"slowest_ms":'

const body_sum = ',"sum_ms":'

const body_end = '}'

// Group is one fan-out in flight: the aggregator, its members, and what the
// answer needs. A worker keeps groups_per_worker of them, allocated once
// (FanState), so a request allocates nothing; the watch payload points at
// its group.
struct Group {
mut:
	idx      int // position in FanState.groups
	next     int // free-list link; -1 ends the list
	agg      int = -1 // the aggregator (an epoll fd)
	n        int              // members started
	left     int              // members not finished yet
	done     int              // members that finished before the answer
	ms       int              // the slowest member's delay
	budget   int              // ms for the whole fan-out; 0 = Limits.park_timeout_ms
	start    i64              // now_ms() when the handler ran
	answered bool             // the client got its answer: wakes only drain and close
	fds      [max_members]i32 // member fds; -1 once closed
}

// FanState is one worker's make_state value: its groups, as a free list, and
// the scratch fan_ready fills on every wake.
struct FanState {
mut:
	groups []Group
	free   int
	ready  [max_members]i32
}

fn new_state() voidptr {
	mut st := &FanState{
		groups: []Group{len: groups_per_worker}
	}
	for i in 0 .. groups_per_worker {
		st.groups[i].idx = i
		st.groups[i].next = if i + 1 < groups_per_worker { i + 1 } else { -1 }
	}
	return voidptr(st)
}

// take pops a free group, or returns -1 when all of them are in flight.
fn (mut st FanState) take() int {
	i := st.free
	if i >= 0 {
		st.free = st.groups[i].next
	}
	return i
}

// release closes g's aggregator and gives g back. Every member must be
// closed already.
fn (mut st FanState) release(mut g Group) {
	if g.agg >= 0 {
		C.close(g.agg)
		g.agg = -1
	}
	g.next = st.free
	st.free = g.idx
}

// now_ms is the monotonic clock in milliseconds (see examples/async_time_limit
// for why not time.ticks()).
@[inline]
fn now_ms() i64 {
	return i64(time.sys_mono_now() / 1_000_000)
}

// member_delay is member i's delay: ms*(i+1)/n, at least 1 ms (a timerfd armed
// with zero never fires).
@[inline]
fn member_delay(ms int, n int, i int) int {
	d := ms * (i + 1) / n
	return if d > 0 { d } else { 1 }
}

// sum_ms is what the n members would take one after the other.
fn sum_ms(ms int, n int) int {
	mut s := 0
	for i in 0 .. n {
		s += member_delay(ms, n, i)
	}
	return s
}

// one_shot_timer returns a timerfd that fires once after `ms`, or -1.
fn one_shot_timer(ms int) int {
	fd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	if fd < 0 {
		return -1
	}
	mut spec := [4]i64{} // struct itimerspec: { it_interval{0,0}, it_value{sec,nsec} }
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	if C.timerfd_settime(fd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil }) != 0 {
		C.close(fd)
		return -1
	}
	return fd
}

// cancel makes a member finish now. A timer is re-armed to fire at once; an
// upstream socket would be shutdown(2), which wakes the aggregator with a
// hangup. Either way the member stays open: the next wake drains and closes
// it like any other.
fn cancel(fd int) {
	mut spec := [4]i64{}
	spec[3] = 1 // 1 ns
	C.timerfd_settime(fd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
}

// launch opens g's aggregator and starts n members in it. On failure (out of
// fds) it closes what it opened, except the aggregator, which release closes.
fn (mut g Group) launch(n int, ms int, budget int) bool {
	g.n = 0
	g.left = 0
	g.done = 0
	g.ms = ms
	g.budget = budget
	g.answered = false
	g.start = now_ms()
	g.agg = C.fan_open()
	if g.agg < 0 {
		return false
	}
	for i in 0 .. n {
		fd := one_shot_timer(member_delay(ms, n, i))
		if fd < 0 || C.fan_add(g.agg, fd, i) != 0 {
			if fd >= 0 {
				C.close(fd)
			}
			g.close_members()
			return false
		}
		g.fds[i] = i32(fd)
		g.n++
		g.left++
	}
	return true
}

// drain closes every member that finished: close also takes it out of the
// aggregator. One call collects them all: a group has at most max_members.
@[direct_array_access]
fn (mut g Group) drain(mut st FanState) {
	k := C.fan_ready(g.agg, &st.ready[0], max_members)
	for j in 0 .. k {
		i := int(st.ready[j])
		if i < 0 || i >= g.n || g.fds[i] < 0 {
			continue
		}
		C.close(g.fds[i])
		g.fds[i] = -1
		g.left--
		if !g.answered {
			g.done++
		}
	}
}

// close_members closes every member still open.
@[direct_array_access]
fn (mut g Group) close_members() {
	for i in 0 .. g.n {
		if g.fds[i] >= 0 {
			C.close(g.fds[i])
			g.fds[i] = -1
		}
	}
	g.left = 0
}

// time_left is the deadline for g's next park: what is left of its budget
// (at least 1 ms), or 0 (Limits.park_timeout_ms) without one. Each watch arms
// a fresh deadline, so the budget bounds the whole fan-out, not one wake.
fn (g &Group) time_left() int {
	if g.budget <= 0 {
		return 0
	}
	left := g.budget - int(now_ms() - g.start)
	return if left > 0 { left } else { 1 }
}

// park watches g's aggregator. Caller-owned (persistent): see the module
// header and README.md for why that, and not watch_fd, keeps every member
// closed exactly once.
@[inline]
fn park(g &Group, mut event_loop core.EventLoop) {
	event_loop.watch_fd_persistent_deadline(g.agg, .readable, on_ready, voidptr(g), g.time_left())
}

// route_is reports whether the request path, without its query string, is
// `lit`. It compares bytes in place: the request is never copied.
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

// query_int reads a positive integer query parameter in place (no copy). A
// missing, empty, zero or non-numeric value means `dflt`; anything above
// `limit` is capped.
@[direct_array_access]
fn query_int(req request_parser.HttpRequest, key []u8, dflt int, limit int) int {
	v := req.get_query_slice(key) or { return dflt }
	mut n := 0
	for i in 0 .. v.len {
		c := req.buffer[v.start + i]
		if c < `0` || c > `9` {
			return dflt
		}
		n = n * 10 + int(c - `0`)
		if n > limit {
			return limit
		}
	}
	return if n > 0 { n } else { dflt }
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

// answer appends g's response under `head` (the 200 or the 504 status line).
fn answer(mut out []u8, head string, g &Group) {
	elapsed := now_ms() - g.start
	sum := sum_ms(g.ms, g.n)
	core.append_str(mut out, head)
	wi(mut out, body_n.len + digits(g.n) + body_done.len + digits(g.done) + body_elapsed.len +
		digits(elapsed) + body_slowest.len + digits(g.ms) + body_sum.len + digits(sum) +
		body_end.len)
	core.append_str(mut out, resp_head_end)
	core.append_str(mut out, body_n)
	wi(mut out, g.n)
	core.append_str(mut out, body_done)
	wi(mut out, g.done)
	core.append_str(mut out, body_elapsed)
	wi(mut out, elapsed)
	core.append_str(mut out, body_slowest)
	wi(mut out, g.ms)
	core.append_str(mut out, body_sum)
	wi(mut out, sum)
	core.append_str(mut out, body_end)
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if !route_is(r, '/fan') {
		core.append_str(mut out, not_found)
		return .done
	}
	mut st := unsafe { &FanState(worker_state) }
	idx := st.take()
	if idx < 0 {
		core.append_str(mut out, resp_503) // every group of this worker is in flight
		return .done
	}
	mut g := unsafe { &st.groups[idx] }
	n := query_int(r, n_key, default_n, max_members)
	ms := query_int(r, ms_key, default_ms, max_ms)
	budget := query_int(r, budget_key, 0, max_ms)
	if !g.launch(n, ms, budget) {
		st.release(mut g)
		core.append_str(mut out, resp_503) // out of fds
		return .done
	}
	park(g, mut event_loop)
	if event_loop.last_watched != g.agg {
		// Refused: a backend with no watch reactor (IOCP, poll).
		g.close_members()
		st.release(mut g)
		core.append_str(mut out, resp_503)
		return .done
	}
	return .suspend
}

// on_ready runs when the aggregator is readable (one member or more
// finished), or once when the budget runs out first. It also runs when the
// client is gone: on epoll the watch is then a tombstone, `out` is discarded,
// and this function still drains and closes every member, then the
// aggregator. It cannot tell, and does not need to.
fn on_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &FanState(worker_state) }
	mut g := unsafe { &Group(watch_payload) }
	if event_loop.timed_out() {
		// The budget ran out first (epoll worker). Answer with what arrived,
		// and cancel the rest. The aggregator stays open: the runtime keeps
		// the caller-owned watch as a tombstone, whose run, as soon as the
		// cancelled members are ready, closes them and the aggregator.
		for i in 0 .. g.n {
			if g.fds[i] >= 0 {
				cancel(g.fds[i])
			}
		}
		answer(mut out, resp_504_head, g)
		g.answered = true
		return .done
	}
	if !ready_fd_error {
		g.drain(mut st)
		if g.left > 0 {
			park(g, mut event_loop)
			if event_loop.last_watched == g.agg {
				return .suspend
			}
		}
	}
	if g.left > 0 {
		// The aggregator failed, or could not be watched again (then nothing
		// would resume the request): give up on every member.
		g.close_members()
		if !g.answered {
			core.append_str(mut out, resp_502)
		}
	} else if !g.answered {
		answer(mut out, resp_200_head, g)
	}
	st.release(mut g)
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8100
		io_multiplexing: .epoll
		handler:         handle
		make_state:      new_state
	})!
	srv.run()
}
