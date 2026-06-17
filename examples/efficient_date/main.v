module main

// Performance example: a cheap, correct `Date:` header. Every HTTP response is
// supposed to carry a Date, but formatting an RFC-1123 timestamp per request is
// pure waste — the value only changes once a second. This caches the formatted
// `Date: ...\r\n` line PER WORKER and rebuilds it only when the wall-clock second
// advances, so almost every request just appends the cached bytes (no time
// syscall, no formatting, no allocation).
//
// Per-worker state (make_state) means the cache is lock-free: each epoll worker
// owns its own DateCache, nothing is shared across threads. This is the same
// trick nginx uses (a coarse cached time string refreshed by the event loop).
//
// Run:   v run examples/efficient_date/
// Try:   curl -i http://localhost:8096/        # note the Date header
//
// A background timerfd could refresh the cache proactively instead of lazily,
// but that needs a worker-start hook for a watch not tied to any request — a
// noted async-runtime follow-up. Lazy refresh is simpler and just as cheap.
import http_server
import time

// DateCache is one worker's cached Date line + the unix second it is valid for.
struct DateCache {
mut:
	sec  i64  // unix second the cached line was built for
	line []u8 // "Date: <rfc1123>\r\n", reused until `sec` changes
}

// make_state runs once per worker — each gets its own cache (no lock needed).
fn make_state() voidptr {
	return &DateCache{
		sec:  0
		line: []u8{cap: 40}
	}
}

// refresh rebuilds the cached Date line only when the second has advanced.
@[direct_array_access]
fn (mut dc DateCache) refresh() {
	now := time.utc()
	if now.unix() == dc.sec {
		return
	}
	dc.sec = now.unix()
	dc.line.clear()
	dc.line << 'Date: '.bytes()
	now.push_to_http_header(mut dc.line) // appends "Sun, 06 Nov 1994 08:49:37 GMT"
	dc.line << '\r\n'.bytes()
}

const body = 'ok'.bytes()

const head = 'HTTP/1.1 200 OK\r\n'.bytes()

const tail = 'Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

fn handle(req []u8, fd int, mut out []u8, state voidptr) ! {
	mut dc := unsafe { &DateCache(state) }
	dc.refresh()
	out << head
	out << dc.line // cached: no per-request formatting in the common case
	out << tail
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:             8096
		io_multiplexing:  .epoll
		stateful_handler: handle
		make_state:       make_state
	})!
	server.run()
}
