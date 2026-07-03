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
fn C.time(t voidptr) i64

// 'Date: ' (6) + IMF-fixdate (29, RFC 9110 §5.6.7) + CRLF (2) = 37 bytes.
const date_line_len = 37

// Every static byte gets its place ONCE; rebuilds only overwrite digits.
const line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

// day_of_week() is 1..7 = Mon..Sun.
const wkday_names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const month_names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
	'Dec']

// DateCache is one worker's pre-formatted `Date: ...\r\n` line in a FIXED
// array — no heap, no growth, cache-line friendly. Only ever touched by that
// worker's thread (make_state + the timerfd continuation), so no lock.
//
// The IMF-fixdate is FIXED-WIDTH, so a 1 Hz refresh almost never changes more
// than the two seconds digits. rebuild_at exploits that: it re-encodes only
// the buckets that rolled over —
//   same minute  -> 2 byte stores (seconds)
//   same hour    -> 4 stores          same day -> 6 stores
//   day rollover -> full reformat (calendar math), once per day
// and reads the clock with C.time(0) (vDSO, ~2.5 ns) instead of time.utc()
// (~1.2 us of clock + calendar conversion, plus two hidden substr allocations
// inside push_to_http_header's weekday_str()/smonth()). Measured with the old
// dynamic-array + push_to_http_header rebuild: 1.25 us -> 9.2 ns, ~135x.
struct DateCache {
mut:
	line [date_line_len]u8
	last i64 // unix second currently encoded in line (0 = never formatted)
}

fn make_state() voidptr {
	mut dc := &DateCache{}
	unsafe { vmemcpy(&dc.line[0], line_template.str, date_line_len) }
	return dc
}

// put2 writes v (0..99) as two ASCII digits at line[o] — two byte stores.
@[direct_array_access; inline]
fn (mut dc DateCache) put2(o int, v int) {
	dc.line[o] = u8(`0` + v / 10)
	dc.line[o + 1] = u8(`0` + v % 10)
}

// rebuild_at re-encodes `now` into the line, touching only what changed.
// Pure over (dc.last, now) — the tests drive it through every rollover.
@[direct_array_access]
fn (mut dc DateCache) rebuild_at(now i64) {
	if now == dc.last {
		return
	}
	tod := int(now % 86400)
	if dc.last != 0 && now / 86400 == dc.last / 86400 {
		dc.put2(29, tod % 60)
		if now / 60 != dc.last / 60 {
			dc.put2(26, (tod / 60) % 60)
			if now / 3600 != dc.last / 3600 {
				dc.put2(23, tod / 3600)
			}
		}
	} else {
		// Day rollover (or first call): full reformat — the only place that
		// pays calendar math, once per day.
		t := time.unix(now)
		w := wkday_names[t.day_of_week() - 1]
		m := month_names[t.month - 1]
		dc.line[6] = w[0]
		dc.line[7] = w[1]
		dc.line[8] = w[2]
		dc.put2(11, t.day)
		dc.line[14] = m[0]
		dc.line[15] = m[1]
		dc.line[16] = m[2]
		dc.put2(18, t.year / 100)
		dc.put2(20, t.year % 100)
		dc.put2(23, t.hour)
		dc.put2(26, t.minute)
		dc.put2(29, t.second)
	}
	dc.last = now
}

// rebuild refreshes the cached line for the current second.
fn rebuild(mut dc DateCache) {
	dc.rebuild_at(i64(C.time(0)))
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
	unsafe { out.push_many(&dc.line[0], date_line_len) }
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
