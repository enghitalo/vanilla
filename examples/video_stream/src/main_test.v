module main

import http_server.core
import os

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect. Callers pass
// their own Viewers so they can inspect state afterwards. client_fd -1 keeps
// any accidental send() harmless (EBADF), never a write to a real descriptor.
fn serve(req string, mut v Viewers) string {
	mut out := []u8{}
	mut worker := core.Worker{
		client_fd: -1
	}
	handle(req.bytes(), mut out, mut worker, mut v)
	return out.bytestr()
}

fn route(method string, target string) string {
	mut v := Viewers{}
	return serve('${method} ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n', mut v)
}

// --- routing (these paths never touch the camera) -------------------------

fn test_index() {
	r := route('GET', '/')
	assert r.contains('200 OK')
	assert r.contains('text/html')
	assert r.contains('/video')
	assert r.contains('/webcam')
}

fn test_index_with_query_string() {
	// the query is trimmed by offsets (route_len), never copied
	r := route('GET', '/?autoplay=1')
	assert r.contains('200 OK')
	assert r.contains('text/html')
}

fn test_unknown_path_404() {
	assert route('GET', '/nope').contains('404 Not Found')
}

fn test_non_get_405() {
	r := route('POST', '/video')
	assert r.contains('405 Method Not Allowed')
	assert r.contains('Allow: GET')
}

fn test_malformed_400() {
	mut v := Viewers{}
	// not even a request line
	r := serve('GARBAGE\r\n\r\n', mut v)
	assert r.contains('400 Bad Request')
	// truncated head: request line parses, but the header block never terminates
	r2 := serve('GET / HTTP/1.1\r\nHost: localhost', mut v)
	assert r2.contains('400 Bad Request')
	assert v.snapshot().len == 0 // nothing was registered along the way
}

fn test_video_missing_404() {
	// Guarded: sample_video is CWD-relative; only assert the 404 branch when no
	// real sample.mp4 sits in the test CWD (writing one would dirty the repo).
	if os.is_file(sample_video) {
		return
	}
	r := route('GET', '/video')
	assert r.contains('404 Not Found')
	assert r.contains('sample.mp4 missing')
}

// --- the MJPEG response line is well-formed (no ffmpeg involved) -----------

fn test_mjpeg_headers_wellformed() {
	h := mjpeg_headers.bytestr()
	assert h.contains('200 OK')
	assert h.contains('Content-Type: multipart/x-mixed-replace; boundary=')
	assert h.contains('Cache-Control: no-cache')
}

fn test_part_prefix_matches_advertised_boundary() {
	// drift guard: the boundary is inlined in TWO single-literal consts
	// (mjpeg_headers in main.v, part_prefix in capture.v). Extract the token
	// the Content-Type advertises and require the part framing to open with it.
	b := mjpeg_headers.bytestr().all_after('boundary=').all_before('\r\n')
	assert b.len > 0
	p := part_prefix.bytestr()
	assert p.starts_with('--${b}\r\n')
	assert p.ends_with('Content-Length: ')
}

// --- Range parsing ----------------------------------------------------------

fn test_parse_range_explicit() {
	start, end := parse_range('bytes=0-99'.bytes(), 1000) or { panic('should parse') }
	assert start == 0
	assert end == 99
}

fn test_parse_range_open_ended() {
	start, end := parse_range('bytes=500-'.bytes(), 1000) or { panic('should parse') }
	assert start == 500
	assert end == 999 // clamped to size-1
}

fn test_parse_range_suffix_last_n() {
	start, end := parse_range('bytes=-100'.bytes(), 1000) or { panic('should parse') }
	assert start == 900 // last 100 bytes
	assert end == 999
}

fn test_parse_range_suffix_larger_than_file() {
	start, end := parse_range('bytes=-5000'.bytes(), 1000) or { panic('should parse') }
	assert start == 0 // suffix longer than the file clamps to the whole file
	assert end == 999
}

fn rejects(header string, size i64) bool {
	if _, _ := parse_range(header.bytes(), size) {
		return false // parsed -> not rejected
	}
	return true
}

fn test_parse_range_rejects_out_of_bounds() {
	assert rejects('bytes=2000-3000', 1000) // beyond size
	assert rejects('bytes=500-100', 1000) // start > end
	assert rejects('items=0-9', 1000) // wrong unit
	assert rejects('bytes=', 1000) // no spec at all
	assert rejects('bytes=0-9-9', 1000) // two dashes (split len != 2)
	assert rejects('bytes=100', 1000) // no dash
}

// --- read_range reads only the requested slice -----------------------------

fn test_read_range_reads_only_the_slice() {
	tmp := os.join_path(os.temp_dir(), 'vanilla_video_range_test.bin')
	os.write_file(tmp, '0123456789ABCDEF') or { panic(err) }
	defer {
		os.rm(tmp) or {}
	}

	mid := read_range(tmp, 4, 5) or { panic('read failed') }
	assert mid.bytestr() == '45678'

	head := read_range(tmp, 0, 3) or { panic('read failed') }
	assert head.bytestr() == '012'
}
