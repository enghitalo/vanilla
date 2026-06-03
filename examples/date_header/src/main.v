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
import strings

// "Date: " (6) + "Wed, 21 Oct 2015 07:28:00" (25) + " GMT" (4) + "\r\n" (2) = 37
const date_line_len = 37

struct DateCache {
mut:
	bufs [2][date_line_len]u8
	idx  u64 // active buffer index (0/1); read/written atomically
}

// refresh formats the current UTC time into the INACTIVE buffer, then publishes
// it by flipping the atomic index. Called once per second by the ticker, so even
// this off-hot-path work is cheap: `time.push_to_http_header` writes the 29-byte
// RFC 7231 date straight into the buffer with hand-placed bytes — no format
// template to parse (unlike `custom_format`), no intermediate string.
fn (mut c DateCache) refresh() {
	mut line := 'Date: '.bytes() // 6 bytes
	time.utc().push_to_http_header(mut line) // + "Wed, 21 Oct 2015 07:28:00 GMT" (29)
	line << `\r`
	line << `\n` // 37 total
	cur := stdatomic.load_u64(&c.idx)
	next := 1 - cur
	for j in 0 .. date_line_len {
		c.bufs[int(next)][j] = line[j]
	}
	stdatomic.store_u64(&c.idx, next) // publish atomically
}

// date_line returns the current cached "Date: …\r\n" as a zero-copy slice. One
// atomic load; no syscall, no formatting.
fn (c &DateCache) date_line() []u8 {
	i := int(stdatomic.load_u64(&c.idx))
	return c.bufs[i][..]
}

fn handle(req_buffer []u8, _ int, cache &DateCache) ![]u8 {
	body := 'ok'
	mut sb := strings.new_builder(96)
	sb.write_string('HTTP/1.1 200 OK\r\n')
	sb.write(cache.date_line()) or {} // cached Date header line
	sb.write_string('Content-Type: text/plain\r\n')
	sb.write_string('Content-Length: ${body.len}\r\n')
	sb.write_string('Connection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

fn main() {
	mut cache := &DateCache{}
	cache.refresh() // seed before the first request is served

	// One ticker for the whole server (not per connection): refresh ~1×/second.
	spawn fn [mut cache] () {
		for {
			time.sleep(time.second)
			cache.refresh()
		}
	}()

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: fn [cache] (req_buffer []u8, fd int) ![]u8 {
			return handle(req_buffer, fd, cache)
		}
	})!
	println('Date-header demo on http://localhost:3000/  (cached, refreshed 1x/s)')
	server.run()
}
