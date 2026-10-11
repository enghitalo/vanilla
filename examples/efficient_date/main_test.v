module main

import core
import time

// The response is byte-exact except for the clock, so each assert brackets
// the request with the wall-clock second before and after it and requires the
// exact bytes for one of the seconds in between. The Date line is checked
// against vlib's RFC 9110 IMF-fixdate formatter as the oracle.

// want_at is the full response for unix second `u` (test scaffolding).
fn want_at(u i64) string {
	return 'HTTP/1.1 200 OK\r\nDate: ' + time.unix(u).http_header_string() +
		'\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
}

// second_of returns the second in [from, to] whose response `got` is, or -1.
fn second_of(got string, from i64, to i64) i64 {
	for u in from .. to + 1 {
		if got == want_at(u) {
			return u
		}
	}
	return -1
}

fn test_response_carries_the_current_date() {
	state := make_state()
	before := time.unix_now()
	got := serve('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n', state)
	after := time.unix_now()
	assert second_of(got, before, after) >= 0, got
}

// The handler never parses: any request, even garbage, gets the same answer.
fn test_any_request_gets_the_same_response() {
	state := make_state()
	for req in [
		'POST /anything?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
		'GARBAGE\r\n\r\n',
		'',
	] {
		before := time.unix_now()
		got := serve(req, state)
		after := time.unix_now()
		assert second_of(got, before, after) >= 0, 'request: ${req} got: ${got}'
	}
}

// Once the second advances the cached line is REBUILT in place — replaced,
// not appended to — so the next response carries the new second and keeps the
// same length.
fn test_date_line_is_rebuilt_when_the_second_advances() {
	state := make_state()
	mut before := time.unix_now()
	first := serve('GET / HTTP/1.1\r\n\r\n', state)
	mut after := time.unix_now()
	first_at := second_of(first, before, after)
	assert first_at >= 0, first
	for time.unix_now() <= first_at {
		time.sleep(10 * time.millisecond)
	}
	before = time.unix_now()
	second := serve('GET / HTTP/1.1\r\n\r\n', state)
	after = time.unix_now()
	assert second_of(second, before, after) > first_at, second
	assert second.len == first.len
}

// The handler APPENDS: a response already in `out` (an earlier pipelined
// request in the same batch) must survive untouched.
fn test_appends_after_existing_bytes() {
	state := make_state()
	mut out := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	mut event_loop := core.EventLoop{}
	before := time.unix_now()
	assert handle('GET / HTTP/1.1\r\n\r\n'.bytes(), mut out, -1, state, mut event_loop) == .done
	after := time.unix_now()
	got := out.bytestr()
	assert got.starts_with('HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\n')
	assert second_of(got.all_after('No Content\r\n\r\n'), before, after) >= 0, got
}

// Neither the cached path nor the once-a-second rebuild allocates: 20k
// requests through one reused buffer, as a worker serves them, every other
// one rebuilding the line as if a second had passed, must not move the
// collector's lifetime allocation counter. (Under `-gc none`, vanilla's production build, an allocation here
// would be a permanent leak.)
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		state := make_state()
		mut dc := unsafe { &DateCache(state) }
		req := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		mut out := []u8{cap: 256}
		mut event_loop := core.EventLoop{}
		handle(req, mut out, -1, state, mut event_loop) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for i in 0 .. rounds {
			if i % 2 == 0 {
				dc.sec-- // as if the second had advanced: refresh() rewrites the line
			}
			unsafe {
				out.len = 0
			}
			handle(req, mut out, -1, state, mut event_loop)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds} requests'
	}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect.
fn serve(req string, state voidptr) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req.bytes(), mut out, -1, state, mut event_loop) == .done
	return out.bytestr()
}
