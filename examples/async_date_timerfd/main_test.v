module main

import time

// SOLUTION: the incremental-update logic itself lives in vlib now
// (time.update_http_header, oracle-tested there across every rollover) —
// these tests cover THIS example's wiring: the template seeding, the
// refresh-current-second contract, and the handler's framing.

fn line_of(dc &DateCache) string {
	return unsafe { tos(&dc.line[0], date_line_len) }.clone()
}

fn expected(u i64) string {
	return 'Date: ' + time.unix(u).http_header_string() + '\r\n'
}

fn test_line_len_matches_vlib() {
	assert date_line_len == date_prefix_len + time.http_header_len + 2
}

fn test_rebuild_encodes_the_current_second() {
	mut dc := unsafe { &DateCache(make_state()) }
	rebuild(mut dc)
	assert dc.last > 0
	assert line_of(dc) == expected(dc.last)
	rebuild(mut dc) // same second: no-op; a second later: seconds digits only
	assert line_of(dc) == expected(dc.last)
}

fn test_handle_serves_the_cached_date() ! {
	state := make_state()
	mut dc := unsafe { &DateCache(state) }
	rebuild(mut dc)
	mut out := []u8{}
	handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, mut out, state)!
	s := out.bytestr()
	assert s.starts_with('HTTP/1.1 200 OK\r\nDate: ')
	assert s.contains(time.unix(dc.last).http_header_string())
	assert s.ends_with('Connection: keep-alive\r\n\r\nok')
}
