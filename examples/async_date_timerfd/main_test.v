module main

import time

// SOLUTION: rebuild_at is pure over (dc.last, now) — drive it through every
// bucket rollover and compare byte-for-byte against the vlib formatter as the
// ORACLE. The incremental path only ever touches the digits that changed, so
// the oracle equality is exactly the property that matters.

// expected builds the reference line via vlib (test scaffolding).
fn expected(u i64) string {
	return 'Date: ' + time.unix(u).http_header_string() + '\r\n'
}

fn cache() &DateCache {
	return unsafe { &DateCache(make_state()) }
}

fn line_of(dc &DateCache) string {
	return unsafe { tos(&dc.line[0], date_line_len) }.clone()
}

fn test_first_format_and_idempotence() {
	mut dc := cache()
	dc.rebuild_at(1735689600) // 2025-01-01 00:00:00 UTC (full format path)
	assert line_of(dc) == expected(1735689600)
	dc.rebuild_at(1735689600) // same second: no-op, line unchanged
	assert line_of(dc) == expected(1735689600)
}

fn test_all_rollovers_match_oracle() {
	mut dc := cache()
	seq := [
		i64(1735689600), // seed (full format)
		1735689601, // +1 s: seconds digits only
		1735689659, // :59
		1735689660, // minute rollover
		1735693199, // 00:59:59
		1735693200, // hour rollover
		1735775999, // 23:59:59
		1735776000, // day rollover (full reformat)
		1740787199, // jump forward weeks (leap-February territory)
		999999999, // jump BACKWARD across years — must fully reformat
		1000000000, // and advance again
	]
	for u in seq {
		dc.rebuild_at(u)
		assert line_of(dc) == expected(u), 'mismatch at unix=${u}'
	}
}

fn test_every_second_across_midnight() {
	// Brute-force a window over a day boundary: every second must match the
	// oracle (catches any missed bucket update in the incremental path).
	mut dc := cache()
	start := i64(1735775990) // 2025-01-01 23:59:50 UTC
	for u in start .. start + 30 {
		dc.rebuild_at(u)
		assert line_of(dc) == expected(u), 'mismatch at unix=${u}'
	}
}
