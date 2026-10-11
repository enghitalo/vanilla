module main

// The cache logic is pure/in-memory, so the format, the publish, and the response
// composition are all unit-testable without a clock-dependent assertion on the
// exact value. seed() must run before refresh() (it lays the static "Date: " /
// CRLF frame that update_http_header does not touch), exactly as main() does.

fn test_refresh_produces_valid_date_line() {
	mut c := DateCache{}
	c.seed()
	c.refresh()
	line := c.date_line().bytestr()
	assert line.starts_with('Date: ')
	assert line.ends_with(' GMT\r\n')
	assert line.len == date_line_len // fixed-width IMF-fixdate line
}

fn test_double_buffer_flips() {
	mut c := DateCache{}
	c.seed()
	c.refresh()
	first := c.idx
	c.refresh()
	assert c.idx == 1 - first // publishes to the other buffer each time
}

fn test_response_includes_date_header() {
	mut c := &DateCache{}
	c.seed()
	c.refresh()
	// Exactly what the handler closure writes into `out`.
	mut out := []u8{}
	respond(c, mut out)
	resp := out.bytestr()
	assert resp.contains('HTTP/1.1 200 OK\r\n')
	assert resp.contains('Date: ')
	assert resp.contains(' GMT\r\n')
	assert resp.contains('Content-Length: 2\r\n')
}

// The hot path allocates nothing: 20k responses through one reused buffer must
// not move the collector's lifetime allocation counter. (Under `-gc none`,
// vanilla's epoll build, an allocation here would be a permanent leak.)
fn test_respond_allocates_nothing() {
	$if gcboehm ? {
		mut c := &DateCache{}
		c.seed()
		c.refresh()
		mut out := []u8{cap: 4096}
		respond(c, mut out) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			respond(c, mut out)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'respond allocated ${grown} bytes over ${rounds} requests'
	}
}

// The ticker's refresh allocates nothing either, once each buffer has been
// formatted (the first full write pays V's weekday lookup; see refresh): 20k
// refreshes, the clock's second boundaries included, must not move the
// collector's lifetime allocation counter.
fn test_refresh_allocates_nothing() {
	$if gcboehm ? {
		mut c := &DateCache{}
		c.seed()
		c.refresh() // warm-up: both buffers get the whole date once
		c.refresh()
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			c.refresh()
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'refresh allocated ${grown} bytes over ${rounds} calls'
		line := c.date_line().bytestr()
		assert line.starts_with('Date: ') && line.ends_with(' GMT\r\n')
	}
}
