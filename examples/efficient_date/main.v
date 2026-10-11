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
import server
import core
import time

// "Date: " (6) + IMF-fixdate (29, "Sun, 06 Nov 1994 08:49:37 GMT") + CRLF (2).
const date_line_len = 37
const date_line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

// DateCache is one worker's cached Date line + the unix second it is valid for.
struct DateCache {
mut:
	sec  i64  // unix second the cached line holds (0: only the template)
	line []u8 // "Date: <IMF-fixdate>\r\n", rewritten in place when `sec` changes
}

// make_state runs once per worker — each gets its own cache (no lock needed).
fn make_state() voidptr {
	return &DateCache{
		line: date_line_template.bytes()
	}
}

// refresh rebuilds the cached Date line only when the second has advanced.
@[direct_array_access]
fn (mut dc DateCache) refresh() {
	// Hot path: ONE cheap time.unix_now() (a bare time() call, ~2 ns, served from
	// the vDSO — no calendar decomposition, no allocation) to detect a second
	// boundary. Only when the second actually advances is the line touched:
	// time.update_http_header rewrites, in place, just the digits that changed
	// since `sec` (mostly the two seconds digits) — no allocation. Its first call
	// and the first after midnight write the whole date with write_http_header,
	// whose weekday lookup (V's time.day_of_week) allocates a small array: once a
	// day per worker, not once a second.
	// (Was: time.utc() on EVERY request just to read its .unix() second.)
	now_sec := time.unix_now()
	if now_sec == dc.sec {
		return
	}
	unsafe { time.update_http_header(&dc.line[6], date_line_len - 6, dc.sec, now_sec) or {} }
	dc.sec = now_sec
}

const head = 'HTTP/1.1 200 OK\r\n'

const tail = 'Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut dc := unsafe { &DateCache(worker_state) }
	dc.refresh()
	core.append_str(mut out, head)
	out << dc.line // cached: no per-request formatting in the common case
	core.append_str(mut out, tail)
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8096
		io_multiplexing: .epoll
		handler:         handle
		make_state:      make_state
	})!
	srv.run()
}
