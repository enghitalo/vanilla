module main

import core
import http1_1.request_parser
import os

fn C.mkfifo(path &char, mode u32) int

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect. Callers pass
// their own Viewers so they can inspect state afterwards. client_fd -1 keeps
// any accidental send() harmless (EBADF), never a write to a real descriptor.
fn serve(req string, mut v Viewers) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop, mut v)
	return out.bytestr()
}

fn route(method string, target string) string {
	mut v := Viewers{}
	return serve('${method} ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n', mut v)
}

// video runs serve_video for `path` (sample_video is CWD-relative, and a test
// must not write one into the repo), with an optional Range header.
fn video(path string, range string) string {
	mut head := 'GET /video HTTP/1.1\r\nHost: localhost\r\n'
	if range != '' {
		head += 'Range: ${range}\r\n'
	}
	buf := (head + '\r\n').bytes()
	mut req := request_parser.HttpRequest{
		buffer: buf
	}
	assert request_parser.decode_into(mut req)
	mut out := []u8{}
	serve_video(req, buf, path, mut out)
	return out.bytestr()
}

// temp_file writes `body` to a file of its own in the temp dir.
fn temp_file(name string, body string) string {
	path := os.join_path(os.temp_dir(), 'vanilla_video_${os.getpid()}_${name}')
	os.write_file(path, body) or { panic(err) }
	return path
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
	mut fds := []int{}
	v.snapshot_into(mut fds)
	assert fds.len == 0 // nothing was registered along the way
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
	assert mjpeg_headers.contains('200 OK')
	assert mjpeg_headers.contains('Content-Type: multipart/x-mixed-replace; boundary=')
	assert mjpeg_headers.contains('Cache-Control: no-cache')
}

fn test_part_prefix_matches_advertised_boundary() {
	// drift guard: the boundary is inlined in TWO single-literal consts
	// (mjpeg_headers in main.v, part_prefix in capture.v). Extract the token
	// the Content-Type advertises and require the part framing to open with it.
	b := mjpeg_headers.all_after('boundary=').all_before('\r\n')
	assert b.len > 0
	assert part_prefix.starts_with('--${b}\r\n')
	assert part_prefix.ends_with('Content-Length: ')
}

// snapshot_into refills the caller's buffer in place: the old contents go,
// and once it has room for every viewer it is not reallocated.
fn test_snapshot_into_reuses_the_buffer() {
	mut v := Viewers{}
	v.add(7)
	v.add(9)
	mut fds := []int{cap: 4}
	fds << 42
	data := fds.data
	v.snapshot_into(mut fds)
	fds.sort()
	assert fds == [7, 9]
	assert fds.data == data
	v.drop(7)
	v.snapshot_into(mut fds)
	assert fds == [9]
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

// --- serve_video reads only the bytes it returns -----------------------------

fn test_video_range_reads_only_the_slice() {
	path := temp_file('slice.bin', '0123456789ABCDEF')
	defer {
		os.rm(path) or {}
	}
	assert video(path, 'bytes=4-8') == 'HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Range: bytes 4-8/16\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\n45678'
	assert video(path, 'bytes=0-2').ends_with('\r\n\r\n012')
	assert video(path, 'bytes=-3').ends_with('Content-Range: bytes 13-15/16\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\nDEF')
}

fn test_video_without_range_is_the_whole_file() {
	path := temp_file('whole.bin', '0123456789ABCDEF')
	defer {
		os.rm(path) or {}
	}
	whole := 'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: 16\r\nConnection: keep-alive\r\n\r\n0123456789ABCDEF'
	assert video(path, '') == whole
	assert video(path, 'bytes=20-30') == whole // unusable range -> full 200
}

// An open-ended range is answered with at most video_chunk_max bytes; the
// player asks for the next range.
fn test_video_chunk_is_capped() {
	path := temp_file('big.bin', 'v'.repeat(video_chunk_max) + 'TAIL')
	defer {
		os.rm(path) or {}
	}
	size := video_chunk_max + 4
	first := video(path, 'bytes=0-')
	assert first.contains('Content-Range: bytes 0-${video_chunk_max - 1}/${size}\r\n')
	assert first.contains('Content-Length: ${video_chunk_max}\r\n')
	assert first.all_after('\r\n\r\n').len == video_chunk_max
	next := video(path, 'bytes=${video_chunk_max}-')
	assert next.ends_with('Content-Length: 4\r\nConnection: keep-alive\r\n\r\nTAIL')
}

// A missing file, a directory and a FIFO are all "missing". A plain open()
// of a FIFO blocks until a writer shows up, so this test hangs if open()
// loses O_NONBLOCK.
fn test_video_not_a_regular_file_is_missing() {
	missing := os.join_path(os.temp_dir(), 'vanilla_video_${os.getpid()}_none.mp4')
	assert video(missing, '') == video_missing
	assert video(os.temp_dir(), 'bytes=0-1') == video_missing
	fifo := os.join_path(os.temp_dir(), 'vanilla_video_${os.getpid()}_fifo')
	assert C.mkfifo(&char(fifo.str), 0o600) == 0
	defer {
		os.rm(fifo) or {}
	}
	assert video(fifo, '') == video_missing
}

// --- the point of the design: serving allocates nothing ----------------------

// Every route but /webcam (which registers a viewer and starts the capture
// thread) runs 20k times through one reused `out`, as a worker would serve
// them; the collector's lifetime allocation counter must not move. (Under
// `-gc none`, vanilla's production build, the same allocation would be a
// permanent leak.) Each /video request still opens and closes the file.
fn test_serving_allocates_nothing() {
	$if gcboehm ? {
		path := temp_file('alloc.bin', 'x'.repeat(64 * 1024))
		defer {
			os.rm(path) or {}
		}
		routes := [
			'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /?autoplay=1 HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /video HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /video HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'GARBAGE\r\n\r\n',
		].map(it.bytes())
		ranges := [
			'GET /video HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /video HTTP/1.1\r\nHost: x\r\nRange: bytes=1000-9999\r\n\r\n',
			'GET /video HTTP/1.1\r\nHost: x\r\nRange: bytes=60000-\r\n\r\n',
			'GET /video HTTP/1.1\r\nHost: x\r\nRange: bytes=-512\r\n\r\n',
			'GET /video HTTP/1.1\r\nHost: x\r\nRange: bytes=99999-\r\n\r\n',
		].map(it.bytes())
		mut reqs := []request_parser.HttpRequest{}
		for r in ranges {
			mut req := request_parser.HttpRequest{
				buffer: r
			}
			assert request_parser.decode_into(mut req)
			reqs << req
		}
		missing := os.join_path(os.temp_dir(), 'vanilla_video_${os.getpid()}_none.mp4')
		mut v := Viewers{}
		mut out := []u8{cap: 128 * 1024}
		mut event_loop := core.EventLoop{}
		rounds := 20_000
		mut before := u64(0)
		for round in 0 .. rounds + 1 {
			if round == 1 { // round 0 was the warm-up: `out` is at its high-water mark
				before = gc_heap_usage().total_bytes
			}
			for r in routes {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, unsafe { nil }, mut event_loop, mut v)
			}
			for i, req in reqs {
				unsafe {
					out.len = 0
				}
				serve_video(req, ranges[i], path, mut out)
			}
			unsafe {
				out.len = 0
			}
			serve_video(reqs[0], ranges[0], missing, mut out)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds * (routes.len +
			reqs.len + 1)} requests'
	}
}
