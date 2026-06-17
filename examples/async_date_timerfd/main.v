module main

// Async-runtime example: the architecturally-pure cached `Date:` header — a
// per-worker timerfd that refreshes the cache from the worker's OWN epoll loop,
// the nginx model mapped onto this server's per-worker reactor.
//
// `on_worker_start` arms a CLIENTLESS background watch (a 1s periodic timerfd) on
// each worker. Its continuation rebuilds THAT worker's cached Date line and
// re-arms — no extra thread, no shared state, no lock, no data race (everything
// touching the cache runs on the one thread that owns it). The request handler
// then does ZERO time work on the hot path: it just appends the cached bytes.
//
// Contrast with examples/efficient_date (lazy per-request refresh: correct and
// simple, but calls time.utc() on the request that crosses each second). Here the
// clock advances even with NO traffic — the timerfd wakes the idle loop once a
// second — so the Date is fresh independent of request rate.
//
// Run:   v run examples/async_date_timerfd/
// Try:   curl -i http://localhost:8097/        # note Date; re-run after a few
//        sleep 3; curl -i http://localhost:8097/   # Date advanced with no load
import http_server
import http_server.core
import time

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// DateCache is one worker's pre-formatted `Date: ...\r\n` line. Only ever touched
// by that worker's thread (make_state + the timerfd continuation), so no lock.
struct DateCache {
mut:
	line []u8
}

fn make_state() voidptr {
	return &DateCache{
		line: []u8{cap: 40}
	}
}

// rebuild reformats the cached line for the current second.
@[direct_array_access]
fn rebuild(mut dc DateCache) {
	dc.line.clear()
	dc.line << 'Date: '.bytes()
	time.utc().push_to_http_header(mut dc.line) // "Sun, 06 Nov 1994 08:49:37 GMT"
	dc.line << '\r\n'.bytes()
}

fn arm_periodic(tfd int, ms int) {
	mut spec := [4]i64{} // { it_interval{s,ns}, it_value{s,ns} } — both set = periodic
	spec[0] = i64(ms / 1000)
	spec[1] = i64(ms % 1000) * 1_000_000
	spec[2] = spec[0]
	spec[3] = spec[1]
	C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
}

// on_start runs once per worker (client_fd = -1): build the cache now so the very
// first request has a Date, then arm a 1s timerfd as a clientless background watch.
fn on_start(mut ac core.AsyncCtx) {
	mut dc := unsafe { &DateCache(ac.state) }
	rebuild(mut dc)
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 1000)
	ac.watch(tfd, .readable, date_tick, unsafe { nil })
}

// date_tick fires once a second: drain the timerfd, refresh this worker's cache,
// and re-arm. Returns .suspend (keep the background watch alive). It never writes
// to `out` (there is no client) and lives for the worker's whole lifetime.
fn date_tick(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut tmp := [8]u8{}
	C.read(ac.ready_fd(), &tmp[0], 8) // drain the expiration count to re-level the fd
	mut dc := unsafe { &DateCache(ac.state) }
	rebuild(mut dc)
	ac.watch(ac.ready_fd(), .readable, date_tick, unsafe { nil })
	return .suspend
}

const head = 'HTTP/1.1 200 OK\r\n'.bytes()

const tail = 'Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// handle is a plain sync handler: zero time work — just append the cached Date.
fn handle(req []u8, fd int, mut out []u8, state voidptr) ! {
	dc := unsafe { &DateCache(state) }
	out << head
	out << dc.line
	out << tail
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:             8097
		io_multiplexing:  .epoll
		stateful_handler: handle
		make_state:       make_state
		on_worker_start:  on_start
	})!
	server.run()
}
