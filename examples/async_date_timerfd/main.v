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

// 'Date: ' (6) + IMF-fixdate (29, RFC 9110 §5.6.7) + CRLF (2) = 37 bytes.
const date_line_len = 37

// Every static byte gets its place ONCE; rebuilds only overwrite digits.
const line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

// DateCache is one worker's pre-formatted `Date: ...\r\n` line in a FIXED
// array — no heap, no growth, cache-line friendly. Only ever touched by that
// worker's thread (make_state + the timerfd continuation), so no lock.
//
// The refresh is time.update_http_header (V stdlib, #27639): because the
// IMF-fixdate is FIXED-WIDTH, a 1 Hz refresh almost never changes more than the
// two seconds digits, so it rewrites ONLY the buckets that rolled over —
//   same minute  -> 2 byte stores (seconds)
//   same hour    -> 4 stores          same day -> 6 stores
//   day rollover -> full reformat (calendar math), once per day
// and reads the clock with time.unix_now() (#27641 — a bare time() call, vDSO,
// ~2 ns) instead of time.utc() (~1.2 us of clock + calendar conversion). This
// example originally hand-rolled the technique that both those PRs upstreamed;
// it now just calls the stdlib. Measured same-minute tick: ~2 ns vs the old
// dynamic-array + push_to_http_header rebuild at 1.25 us.
struct DateCache {
mut:
	line [date_line_len]u8
	last i64 // unix second currently encoded in line[6..35] (0 = never formatted)
}

fn make_state() voidptr {
	mut dc := &DateCache{}
	unsafe { vmemcpy(&dc.line[0], line_template.str, date_line_len) }
	return dc
}

// rebuild_at re-encodes `now` into the cached line via stdlib
// time.update_http_header, touching only the digits that changed: the common
// (same-minute) path is a 2-byte store; a full reformat happens only on day
// rollover. dc.line[6] is the 29-byte IMF-fixdate; [0..6] is "Date: " and
// [35..37] the CRLF — both seeded by make_state and never rewritten here.
// Split out from rebuild() as a pure seam over (dc.last, now) so the tests can
// drive it through every rollover without depending on the wall clock.
fn (mut dc DateCache) rebuild_at(now i64) {
	unsafe { time.update_http_header(&dc.line[6], date_line_len - 6, dc.last, now) or {} }
	dc.last = now
}

// rebuild refreshes the cached line for the current second.
fn rebuild(mut dc DateCache) {
	dc.rebuild_at(time.unix_now())
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
fn on_start(worker_state voidptr, mut event_loop core.EventLoop) {
	mut dc := unsafe { &DateCache(worker_state) }
	rebuild(mut dc)
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 1000)
	event_loop.watch_fd(tfd, .readable, date_tick, unsafe { nil })
}

// date_tick fires once a second: drain the timerfd, refresh this worker's cache,
// and re-arm. Returns .suspend (keep the background watch alive). It never writes
// to `out` (there is no client) and lives for the worker's whole lifetime.
fn date_tick(mut _outout []u8, ready_fd int, _ready_fd_errorready_fd_error bool, _watch_payloadwatch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // drain the expiration count to re-level the fd
	mut dc := unsafe { &DateCache(worker_state) }
	rebuild(mut dc)
	event_loop.watch_fd(ready_fd, .readable, date_tick, unsafe { nil })
	return .suspend
}

const head = 'HTTP/1.1 200 OK\r\n'.bytes()

const tail = 'Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// handle is a plain sync handler: zero time work — just append the cached Date.
fn handle(_reqreq []u8, mut out []u8, _client_fdclient_fd int, worker_state voidptr, mut _event_loopevent_loop core.EventLoop) core.Step {
	dc := unsafe { &DateCache(worker_state) }
	out << head
	unsafe { out.push_many(&dc.line[0], date_line_len) }
	out << tail
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8097
		io_multiplexing: .epoll
		handler:         handle
		make_state:      make_state
		on_worker_start: on_start
	})!
	server.run()
}
