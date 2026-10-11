module main

// Video streaming — two reference designs, one server.
//
//   GET /video   FILE stream, the PULL model: HTTP Range requests (206 Partial
//                Content). This is how a browser <video> element seeks — it asks
//                for byte ranges. We read ONLY the requested range from disk,
//                with pread(2) straight into `out` (a multi-GB file never sits
//                in a []u8), and cap each chunk, so memory stays bounded no
//                matter the file size. POSIX (Linux, macOS).
//
//   GET /webcam  LIVE stream, the PUSH model: motion-JPEG over
//                multipart/x-mixed-replace. One capture thread fans frames out to
//                every viewer fd — no thread per viewer (see capture.v).
//
// Both keep the project's contract: the handler is still
// fn ([]u8, mut []u8, int, voidptr, mut core.EventLoop) core.Step.
// /video appends the response bytes into `out` (the core streams large ones via
// EPOLLOUT back-pressure); /webcam registers the fd and a single broadcaster
// owns it.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - Static responses are single-literal consts; dynamic framing goes
//     straight into `out` via core.append_str/wi — no `+`, no `${}`, no builders.
//   - Routing and the Range header are read IN PLACE as offsets/views into
//     the request buffer — no `.to_string()`, no substr, no split.
//   - The file is opened and fstat'ed per request, and the bytes a response
//     carries are read into `out` by core.append_file_region: no os.File, no
//     temporary []u8, no copy.
import server
import core
import http1_1.request_parser
import os
import strconv

#include <fcntl.h>
#include <sys/stat.h>

fn C.fstat(fd int, buf &C.stat) int

const sample_video = 'sample.mp4'

// Cap each 206 chunk so a Range request can never pull an unbounded slice into
// memory. A client (every media player does) just asks for the next range.
const video_chunk_max = 2 * 1024 * 1024

const index_page = 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: keep-alive\r\n\r\n<!doctype html><meta charset=utf-8><title>vanilla video</title><h2>File stream (Range / seekable)</h2><video src="/video" controls width=640></video><h2>Webcam (live MJPEG)</h2><img src="/webcam" width=640>'

// The multipart boundary text is INLINED here (consts are single literals —
// never built with `+`/`${}`); a test pins that it matches `part_prefix` in
// capture.v so the two can't drift.
const mjpeg_headers = 'HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=vanillaframe\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const method_not_allowed = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const video_missing = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 39\r\nConnection: keep-alive\r\n\r\nsample.mp4 missing (ffmpeg to generate)'

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// route_len returns the path length up to (not including) the first `?`, so
// the route Slice excludes the query string — trimmed by OFFSETS, no substr.
@[direct_array_access]
fn route_len(buf []u8, path request_parser.Slice) int {
	for i in 0 .. path.len {
		if buf[path.start + i] == u8(`?`) {
			return i
		}
	}
	return path.len
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut viewers Viewers) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		core.append_str(mut out, bad_request)
		return .done
	}
	if !slice_eq(req_buffer, req.method, 'GET') {
		core.append_str(mut out, method_not_allowed)
		return .done
	}
	// Effective route = path with the query string stripped, as offsets.
	route := request_parser.Slice{
		start: req.path.start
		len:   route_len(req_buffer, req.path)
	}

	if slice_eq(req_buffer, route, '/') {
		core.append_str(mut out, index_page)
	} else if slice_eq(req_buffer, route, '/webcam') {
		// Register the fd, start capture on the first viewer; the core sends
		// these headers and keeps the connection open. The broadcaster (in
		// capture.v) now owns the fd and pushes frames to it.
		viewers.ensure_capture()
		viewers.add(client_fd)
		core.append_str(mut out, mjpeg_headers)
	} else if slice_eq(req_buffer, route, '/video') {
		serve_video(req, req_buffer, sample_video, mut out)
	} else {
		core.append_str(mut out, not_found)
	}
	return .done
}

// serve_video answers a (possibly ranged) request for the video file at
// `path`, reading only the bytes it returns, with pread(2) straight into `out`
// after the header block (core.append_file_region). Range present -> 206 +
// Content-Range, capped to video_chunk_max. No Range -> 200 with the full file
// (browsers always send a Range, so this path is for simple clients / small
// files). The views come from `req_buffer`, the handler's own parameter (a
// view of `req.buffer` handed on to a callee moves `req` to the heap).
//
// The core's zero-copy alternative is core.queue_file (sendfile(2), used by
// server.static_assets): the worker sends the region itself, but it needs an
// fd that stays open for as long as the worker may send from it — not adopted
// here, where the file is opened per request.
fn serve_video(req request_parser.HttpRequest, req_buffer []u8, path string, mut out []u8) {
	// O_NONBLOCK: a FIFO put in the file's place cannot block the worker in
	// open() (on a regular file it changes nothing); fstat on the opened fd
	// then refuses anything but a regular file.
	fd := C.open(&char(path.str), C.O_RDONLY | C.O_NONBLOCK | C.O_CLOEXEC)
	if fd < 0 {
		core.append_str(mut out, video_missing)
		return
	}
	defer {
		C.close(fd)
	}
	mut sb := C.stat{}
	if C.fstat(fd, &sb) != 0 || sb.st_mode & os.s_ifmt != os.s_ifreg {
		core.append_str(mut out, video_missing)
		return
	}
	size := i64(sb.st_size)
	mark := out.len

	if rng := req.get_header_value_slice('Range') {
		if rng.len > 0 {
			// Zero-copy VIEW of the header value — parse_range scans it in place.
			header := unsafe { (&req_buffer[rng.start]).vbytes(rng.len) }
			if start, end_req := parse_range(header, size) {
				// Cap the chunk so memory stays bounded regardless of what was asked.
				mut end := end_req
				if end - start + 1 > video_chunk_max {
					end = start + video_chunk_max - 1
				}
				length := end - start + 1
				core.append_str(mut out,
					'HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Range: bytes ')
				wi(mut out, start)
				core.append_str(mut out, '-')
				wi(mut out, end)
				core.append_str(mut out, '/')
				wi(mut out, size)
				core.append_str(mut out, '\r\nContent-Length: ')
				wi(mut out, length)
				core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n')
				append_body(mut out, fd, start, length, mark)
				return
			}
		}
	}

	// No (valid) Range: full 200. Accept-Ranges tells the client it can seek.
	core.append_str(mut out,
		'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: ')
	wi(mut out, size)
	core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	append_body(mut out, fd, 0, size, mark)
}

// append_body reads bytes [off, off+length) of the file into `out`, after the
// header block that promised exactly `length` of them. A short read (the file
// shrank under us, or a read error) cannot keep that promise: everything this
// response appended, from `mark` on, is dropped for a 404.
fn append_body(mut out []u8, fd int, off i64, length i64, mark int) {
	if length > 0 && core.append_file_region(mut out, fd, off, length) != length {
		unsafe {
			out.len = mark
		}
		core.append_str(mut out, not_found)
	}
}

// parse_range parses "bytes=START-END" into an inclusive, clamped (start, end).
// Supports open-ended "bytes=START-" and suffix "bytes=-N" (last N bytes).
// Pure offset scan over the header VIEW — no substr, no split(), no strings.
fn parse_range(h []u8, size i64) ?(i64, i64) {
	prefix := 'bytes='
	if h.len <= prefix.len {
		return none
	}
	for i in 0 .. prefix.len {
		if h[i] != prefix[i] {
			return none
		}
	}
	// Exactly one '-' separates the two fields (RFC 9110 int-range/suffix-range).
	mut dash := -1
	for i in prefix.len .. h.len {
		if h[i] == u8(`-`) {
			if dash >= 0 {
				return none
			}
			dash = i
		}
	}
	if dash < 0 {
		return none
	}
	mut start := i64(0)
	mut end := size - 1
	if dash == prefix.len {
		n := dec_i64(h, dash + 1, h.len) // suffix: last N bytes
		start = if n >= size { i64(0) } else { size - n }
	} else {
		start = dec_i64(h, prefix.len, dash)
		if dash + 1 < h.len {
			end = dec_i64(h, dash + 1, h.len)
		}
	}
	if start < 0 || end >= size || start > end {
		return none
	}
	return start, end
}

// dec_i64 parses the leading decimal digits of h[from..to] in place. No digits
// yields 0 — the same accept/reject matrix as the substr+`.i64()` parser this
// replaced (out-of-range values are caught by parse_range's final clamp check).
@[direct_array_access]
fn dec_i64(h []u8, from int, to int) i64 {
	mut v := i64(0)
	for k in from .. to {
		if h[k] < `0` || h[k] > `9` {
			break
		}
		v = v * 10 + i64(h[k] - `0`)
	}
	return v
}

fn main() {
	// Self-contained: synthesize a short sample.mp4 once if absent (needs
	// ffmpeg). One-time init; an argument array, no shell (os.execute is
	// deprecated, and -prod refuses it).
	if !os.is_file(sample_video) {
		eprintln('generating ${sample_video} (one-time, via ffmpeg)...')
		os.exec(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
			'testsrc=size=640x480:rate=30:duration=8', '-pix_fmt', 'yuv420p', sample_video])
	}

	mut viewers := &Viewers{}
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         fn [mut viewers] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut viewers)
		}
		limits:          server.Limits{
			max_header_bytes: 16 * 1024
			read_timeout_ms:  10_000
			// idle_timeout_ms: -1 is REQUIRED here. /webcam returns .done after
			// the headers and hands its fd to the broadcaster thread, so the
			// core sees an idle keep-alive connection. With the default (0 =
			// inherit read_timeout_ms) every viewer would be closed after 10s —
			// and the broadcaster, which still holds the fd number, would then
			// write MJPEG frames into whatever new connection the kernel gives
			// that number next. The read timeout still bounds silent connects
			// and slow requests.
			idle_timeout_ms:  -1
			// NOTE: no write_timeout_ms — the webcam stream is intentionally
			// long-lived, so a write deadline would reap healthy viewers.
		}
	})!
	println('video stream on http://localhost:3000/  (/, /video, /webcam)')
	srv.run()
}
