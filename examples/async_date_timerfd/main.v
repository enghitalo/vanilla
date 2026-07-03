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
// The moving parts are stdlib since vlang/v#27639 / #27641 / #27642:
//   - `time.update_http_header` refreshes the line IN PLACE, rewriting only the
//     digits whose bucket rolled over (~2 ns/tick; calendar math only on day
//     rollover) — vs ~1.25 µs for the old dynamic-array rebuild it replaced.
//   - `time.unix_now()` reads the wall-clock second (vDSO, ~2 ns) without
//     constructing a `Time`.
//   - the timerfd declarations (`C.timerfd_create`/`C.timerfd_settime`/
//     `C.itimerspec`) ship with `import time` — no local `fn C.` declarations,
//     no hand-built itimerspec in a raw [4]i64.
//
// Contrast with examples/efficient_date (lazy per-request refresh: correct and
// simple, but pays the clock read on the request that crosses each second). Here
// the clock advances even with NO traffic — the timerfd wakes the idle loop once
// a second — so the Date is fresh independent of request rate.
//
// Run:   v run examples/async_date_timerfd/
// Try:   curl -i http://localhost:8097/        # note Date; re-run after a few
//        sleep 3; curl -i http://localhost:8097/   # Date advanced with no load
import http_server
import http_server.core
import time

fn C.read(fd int, buf voidptr, count usize) int

// 'Date: ' (6) + IMF-fixdate (time.http_header_len = 29) + CRLF (2) = 37.
// (A literal, not `6 + time.http_header_len + 2`: a fixed-array size built
// from another module's const trips the checker in _test.v builds; the
// relationship is pinned by a test instead.)
const date_prefix_len = 6
const date_line_len = 37

// Static bytes get their place ONCE; every refresh only rewrites date digits.
const line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

// DateCache is one worker's pre-formatted `Date: ...\r\n` line in a FIXED
// array — no heap, no growth. Only ever touched by that worker's thread
// (make_state + the timerfd continuation), so no lock.
struct DateCache {
mut:
	line [date_line_len]u8
	last i64 // unix second currently encoded (0 = never: first refresh writes all fields)
}

fn make_state() voidptr {
	mut dc := &DateCache{}
	unsafe { vmemcpy(&dc.line[0], line_template.str, date_line_len) }
	return dc
}

// rebuild refreshes the cached line for the current second: one ~2 ns clock
// read + an in-place update of only the digits that changed.
fn rebuild(mut dc DateCache) {
	now := time.unix_now()
	unsafe {
		// 31 writable bytes >= time.http_header_len: cannot fail.
		time.update_http_header(&dc.line[date_prefix_len], date_line_len - date_prefix_len,
			dc.last, now) or {}
	}
	dc.last = now
}

// arm_periodic starts the kernel-paced tick: first expiry after `ms`, then
// every `ms` — re-armed by the KERNEL, so the cadence never drifts with the
// continuation's processing time.
fn arm_periodic(tfd int, ms int) {
	interval := C.timespec{
		tv_sec:  ms / 1000
		tv_nsec: i64(ms % 1000) * 1_000_000
	}
	spec := C.itimerspec{
		it_value:    interval
		it_interval: interval
	}
	C.timerfd_settime(tfd, 0, &spec, unsafe { nil })
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
	mut expirations := u64(0)
	C.read(ac.ready_fd(), &expirations, 8) // drain the count to re-level the fd
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
