module main

import os

fn viewers() Viewers {
	return Viewers{}
}

fn route(method string, target string) string {
	mut v := viewers()
	raw := '${method} ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'
	r := handle(raw.bytes(), -1, mut v) or { panic('handle error: ${err}') }
	return r.bytestr()
}

// --- routing (these paths never touch the camera) -------------------------

fn test_index() {
	r := route('GET', '/')
	assert r.contains('200 OK')
	assert r.contains('text/html')
	assert r.contains('/video')
	assert r.contains('/webcam')
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
	mut v := viewers()
	r := handle('GARBAGE\r\n\r\n'.bytes(), -1, mut v) or { panic(err) }
	assert r.bytestr().contains('400 Bad Request')
}

// --- the MJPEG response line is well-formed (no ffmpeg involved) -----------

fn test_mjpeg_headers_wellformed() {
	h := mjpeg_headers.bytestr()
	assert h.contains('200 OK')
	assert h.contains('Content-Type: multipart/x-mixed-replace; boundary=${boundary}')
	assert h.contains('Cache-Control: no-cache')
}

// --- Range parsing ----------------------------------------------------------

fn test_parse_range_explicit() {
	start, end := parse_range('bytes=0-99', 1000) or { panic('should parse') }
	assert start == 0
	assert end == 99
}

fn test_parse_range_open_ended() {
	start, end := parse_range('bytes=500-', 1000) or { panic('should parse') }
	assert start == 500
	assert end == 999 // clamped to size-1
}

fn test_parse_range_suffix_last_n() {
	start, end := parse_range('bytes=-100', 1000) or { panic('should parse') }
	assert start == 900 // last 100 bytes
	assert end == 999
}

fn rejects(header string, size i64) bool {
	if _, _ := parse_range(header, size) {
		return false // parsed -> not rejected
	}
	return true
}

fn test_parse_range_rejects_out_of_bounds() {
	assert rejects('bytes=2000-3000', 1000) // beyond size
	assert rejects('bytes=500-100', 1000) // start > end
	assert rejects('items=0-9', 1000) // wrong unit
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
