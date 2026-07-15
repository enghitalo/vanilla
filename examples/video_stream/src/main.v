module main

// Video streaming — two reference designs, one server.
//
//   GET /video   FILE stream, the PULL model: HTTP Range requests (206 Partial
//                Content). This is how a browser <video> element seeks — it asks
//                for byte ranges. We read ONLY the requested range from disk (a
//                multi-GB file never sits in a []u8) and cap each chunk, so
//                memory stays bounded no matter the file size.
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
//     straight into `out` via ws/wi — no `+`, no `${}`, no builders.
//   - Routing and the Range header are read IN PLACE as offsets/views into
//     the request buffer — no `.to_string()`, no substr, no split.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import os
import strconv

const sample_video = 'sample.mp4'

// Cap each 206 chunk so a Range request can never pull an unbounded slice into
// memory. A client (every media player does) just asks for the next range.
const video_chunk_max = 2 * 1024 * 1024

const index_page = 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: keep-alive\r\n\r\n<!doctype html><meta charset=utf-8><title>vanilla video</title><h2>File stream (Range / seekable)</h2><video src="/video" controls width=640></video><h2>Webcam (live MJPEG)</h2><img src="/webcam" width=640>'.bytes()

// The multipart boundary text is INLINED here (consts are single literals —
// never built with `+`/`${}`); a test pins that it matches `part_prefix` in
// capture.v so the two can't drift.
const mjpeg_headers = 'HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=vanillaframe\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const method_not_allowed = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const video_missing = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 39\r\nConnection: keep-alive\r\n\r\nsample.mp4 missing (ffmpeg to generate)'.bytes()

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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
	req := request_parser.decode_http_request(req_buffer) or {
		out << bad_request
		return .done
	}
	if !slice_eq(req.buffer, req.method, 'GET') {
		out << method_not_allowed
		return .done
	}
	// Effective route = path with the query string stripped, as offsets.
	route := request_parser.Slice{
		start: req.path.start
		len:   route_len(req.buffer, req.path)
	}

	if slice_eq(req.buffer, route, '/') {
		out << index_page
	} else if slice_eq(req.buffer, route, '/webcam') {
		// Register the fd, start capture on the first viewer; the core sends
		// these headers and keeps the connection open. The broadcaster (in
		// capture.v) now owns the fd and pushes frames to it.
		viewers.ensure_capture()
		viewers.add(client_fd)
		out << mjpeg_headers
	} else if slice_eq(req.buffer, route, '/video') {
		serve_video(req, mut out)
	} else {
		out << not_found
	}
	return .done
}

// serve_video answers a (possibly ranged) request for the video file, reading
// only the bytes it returns. Range present -> 206 + Content-Range, capped to
// video_chunk_max. No Range -> 200 with the full file (browsers always send a
// Range, so this path is for simple clients / small files).
//
// The body allocation (`read_range`) is DISK I/O, not a discipline violation:
// reading a file range must materialize bytes somewhere. The core's zero-copy
// alternative is core.queue_file (sendfile(2), used by http_server.static_assets)
// — not adopted here because this example teaches bounded-memory Range reads.
fn serve_video(req request_parser.HttpRequest, mut out []u8) {
	if !os.is_file(sample_video) {
		out << video_missing
		return
	}
	size := i64(os.file_size(sample_video))

	if rng := req.get_header_value_slice('Range') {
		if rng.len > 0 {
			// Zero-copy VIEW of the header value — parse_range scans it in place.
			header := unsafe { (&req.buffer[rng.start]).vbytes(rng.len) }
			if start, end_req := parse_range(header, size) {
				// Cap the chunk so memory stays bounded regardless of what was asked.
				mut end := end_req
				if end - start + 1 > video_chunk_max {
					end = start + video_chunk_max - 1
				}
				data := read_range(sample_video, start, int(end - start + 1)) or {
					out << not_found
					return
				}
				ws(mut out,
					'HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Range: bytes ')
				wi(mut out, start)
				ws(mut out, '-')
				wi(mut out, end)
				ws(mut out, '/')
				wi(mut out, size)
				ws(mut out, '\r\nContent-Length: ')
				wi(mut out, data.len)
				ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
				out << data
				return
			}
		}
	}

	// No (valid) Range: full 200. Accept-Ranges tells the client it can seek.
	data := read_range(sample_video, 0, int(size)) or {
		out << not_found
		return
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: ')
	wi(mut out, data.len)
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	out << data
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

// read_range reads `length` bytes at `start` WITHOUT loading the whole file.
fn read_range(path string, start i64, length int) ?[]u8 {
	mut f := os.open(path) or { return none }
	defer { f.close() }
	data := f.read_bytes_at(length, u64(start))
	return data
}

fn main() {
	// Self-contained: synthesize a short sample.mp4 once if absent (needs
	// ffmpeg). One-time init — the output filename is spelled out because
	// consts/commands are single literals (keep it in sync with sample_video).
	if !os.is_file(sample_video) {
		eprintln('generating ${sample_video} (one-time, via ffmpeg)...')
		os.execute('ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x480:rate=30:duration=8 -pix_fmt yuv420p sample.mp4')
	}

	mut viewers := &Viewers{}
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
		handler:         fn [mut viewers] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut viewers)
		}
		limits:          http_server.Limits{
			max_header_bytes: 16 * 1024
			read_timeout_ms:  10_000
			// NOTE: no write_timeout_ms — the webcam stream is intentionally
			// long-lived, so a write deadline would reap healthy viewers.
		}
	})!
	println('video stream on http://localhost:3000/  (/, /video, /webcam)')
	server.run()
}
