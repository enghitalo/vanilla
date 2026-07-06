module main

// Low-cost `Date` response header — no globals, lock-free reads.
//
// RFC 9110 §6.6.1: an origin server with a clock should send `Date` on responses.
// But formatting the time PER REQUEST (a clock syscall + date formatting) is pure
// waste at hundreds of thousands of rps. The `Date` header only has 1-second
// resolution, so the fix is to format it ONCE PER SECOND and cache it; a value up
// to ~1s old is perfectly conformant.
//
// THE TWO CONSTRAINTS YOU HIT, solved:
//
//   1. "Low cost" — the hot path does NO syscall and NO formatting: it just reads
//      a pre-built `Date: …\r\n` line (37 bytes) and copies it into the response.
//
//   2. "No globals" — the cache is plain state the APP owns (`DateCache`), created
//      in main() and captured by the handler closure (and the ticker). The library
//      stays untouched; the handler still has the bytes-in/bytes-out contract.
//
// LOCK-FREE & GC-SAFE via DOUBLE BUFFERING: the cache holds two fixed 37-byte
// buffers. The ticker formats the INACTIVE buffer, then atomically flips an index
// to publish it. A reader atomically loads the index and copies that buffer — it's
// never the one being written (the writer touches `1 - active`), so there are no
// torn reads, no mutex, and no pointer-as-integer tricks for the GC to mishandle.
import http_server
import time
import sync.stdatomic

// "Date: " (6) + "Wed, 21 Oct 2015 07:28:00 GMT" (29) + "\r\n" (2) = 37
const date_line_len = 37

// The static frame every buffer starts from: only the 29 date bytes at offset 6
// ever change (write_http_header rewrites exactly those), so the "Date: " prefix
// and trailing CRLF are seeded once and never touched on the refresh path.
const line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

struct DateCache {
mut:
	bufs [2][date_line_len]u8
	idx  u64 // active buffer index (0/1); read/written atomically
}

// seed lays down the static frame ("Date: " + placeholder + CRLF) in BOTH
// buffers once, so every later refresh only rewrites the 29 date bytes.
fn (mut c DateCache) seed() {
	for i in 0 .. 2 {
		unsafe { vmemcpy(&c.bufs[i][0], line_template.str, date_line_len) }
	}
}

// refresh formats the current UTC time into the INACTIVE buffer, then publishes
// it by flipping the atomic index. Called once per second by the ticker, so even
// this off-hot-path work is cheap: `time.write_http_header` writes the 29-byte
// RFC 9110 IMF-fixdate straight into the buffer at offset 6 (after "Date: "),
// allocation-free — no format template to parse, no intermediate string.
fn (mut c DateCache) refresh() {
	cur := stdatomic.load_u64(&c.idx)
	next := 1 - cur
	unsafe {
		time.utc().write_http_header(&c.bufs[int(next)][6], date_line_len - 6) or {}
	}
	stdatomic.store_u64(&c.idx, next) // publish atomically
}

// date_line returns the current cached "Date: …\r\n" as a zero-copy slice. One
// atomic load; no syscall, no formatting.
fn (c &DateCache) date_line() []u8 {
	i := int(stdatomic.load_u64(&c.idx))
	return c.bufs[i][..]
}

// The two STATIC halves of the response — everything except the Date line, which
// is the only per-request-varying part (and is already pre-built in the cache).
// Built once as consts so the hot path allocates nothing.
const status_head = 'HTTP/1.1 200 OK\r\n'.bytes()

// Content-Length: 2 is the 'ok' body.
const resp_tail = 'Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

fn main() {
	mut cache := &DateCache{}
	cache.seed() // lay down the static frame in both buffers once
	cache.refresh() // format the date before the first request is served

	// One ticker for the whole server (not per connection): refresh ~1×/second.
	spawn fn [mut cache] () {
		for {
			time.sleep(time.second)
			cache.refresh()
		}
	}()

	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: fn [cache] (req_buffer []u8, fd int, mut out []u8) ! {
			// Zero per-request allocation: append the two static halves and the
			// pre-built cached Date line (one atomic load, zero-copy slice) straight
			// into the server-owned `out` buffer — no per-request strings.Builder, no
			// copy-through an intermediate.
			out << status_head
			out << cache.date_line()
			out << resp_tail
		}
	})!
	println('Date-header demo on http://localhost:3000/  (cached, refreshed 1x/s)')
	server.run()
}
