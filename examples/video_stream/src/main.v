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
// Both keep the project's contract: the handler is still fn ([]u8, int, mut []u8) !.
// /video returns the response bytes (the core streams large ones via EPOLLOUT
// back-pressure); /webcam registers the fd and a single broadcaster owns it.
import http_server
import http_server.http1_1.request_parser
import os
import strings

const sample_video = 'sample.mp4'

// Cap each 206 chunk so a Range request can never pull an unbounded slice into
// memory. A client (every media player does) just asks for the next range.
const video_chunk_max = 2 * 1024 * 1024

const index_page = (
	'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: keep-alive\r\n\r\n' +
	'<!doctype html><meta charset=utf-8><title>vanilla video</title>' +
	'<h2>File stream (Range / seekable)</h2>' + '<video src="/video" controls width=640></video>' + '<h2>Webcam (live MJPEG)</h2>' + '<img src="/webcam" width=640>').bytes()

const mjpeg_headers = ('HTTP/1.1 200 OK\r\n' +
	'Content-Type: multipart/x-mixed-replace; boundary=${boundary}\r\n' +
	'Cache-Control: no-cache\r\n' + 'Connection: close\r\n' + '\r\n').bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const method_not_allowed = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const video_missing = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 38\r\nConnection: keep-alive\r\n\r\nsample.mp4 missing (ffmpeg to generate)'.bytes()

fn handle(req_buffer []u8, fd int, mut viewers Viewers) ![]u8 {
	req := request_parser.decode_http_request(req_buffer) or { return bad_request }
	method := req.method.to_string(req.buffer)
	mut path := req.path.to_string(req.buffer)
	if qi := path.index('?') {
		path = path[..qi]
	}
	if method != 'GET' {
		return method_not_allowed
	}

	match path {
		'/' {
			return index_page
		}
		'/webcam' {
			// Register the fd, start capture on the first viewer; the core sends
			// these headers and keeps the connection open. The broadcaster (in
			// capture.v) now owns the fd and pushes frames to it.
			viewers.ensure_capture()
			viewers.add(fd)
			return mjpeg_headers
		}
		'/video' {
			return serve_video(req)
		}
		else {
			return not_found
		}
	}
}

// serve_video answers a (possibly ranged) request for the video file, reading
// only the bytes it returns. Range present -> 206 + Content-Range, capped to
// video_chunk_max. No Range -> 200 with the full file (browsers always send a
// Range, so this path is for simple clients / small files).
fn serve_video(req request_parser.HttpRequest) []u8 {
	if !os.is_file(sample_video) {
		return video_missing
	}
	size := i64(os.file_size(sample_video))

	if rng := req.get_header_value_slice('Range') {
		if start, end_req := parse_range(rng.to_string(req.buffer), size) {
			// Cap the chunk so memory stays bounded regardless of what was asked.
			mut end := end_req
			if end - start + 1 > video_chunk_max {
				end = start + video_chunk_max - 1
			}
			data := read_range(sample_video, start, int(end - start + 1)) or { return not_found }
			mut sb := strings.new_builder(256 + data.len)
			sb.write_string('HTTP/1.1 206 Partial Content\r\n')
			sb.write_string('Content-Type: video/mp4\r\n')
			sb.write_string('Accept-Ranges: bytes\r\n')
			sb.write_string('Content-Range: bytes ${start}-${end}/${size}\r\n')
			sb.write_string('Content-Length: ${data.len}\r\n')
			sb.write_string('Connection: keep-alive\r\n\r\n')
			sb.write(data) or {}
			return sb
		}
	}

	// No (valid) Range: full 200.
	data := read_range(sample_video, 0, int(size)) or { return not_found }
	mut sb := strings.new_builder(256 + data.len)
	sb.write_string('HTTP/1.1 200 OK\r\n')
	sb.write_string('Content-Type: video/mp4\r\n')
	sb.write_string('Accept-Ranges: bytes\r\n') // tell the client it can seek
	sb.write_string('Content-Length: ${data.len}\r\n')
	sb.write_string('Connection: keep-alive\r\n\r\n')
	sb.write(data) or {}
	return sb
}

// parse_range parses "bytes=START-END" into an inclusive, clamped (start, end).
// Supports open-ended "bytes=START-" and suffix "bytes=-N" (last N bytes).
fn parse_range(header string, size i64) ?(i64, i64) {
	if !header.starts_with('bytes=') {
		return none
	}
	spec := header['bytes='.len..]
	parts := spec.split('-')
	if parts.len != 2 {
		return none
	}
	mut start := i64(0)
	mut end := size - 1
	if parts[0] == '' {
		n := parts[1].i64() // suffix: last N bytes
		start = if n >= size { i64(0) } else { size - n }
	} else {
		start = parts[0].i64()
		if parts[1] != '' {
			end = parts[1].i64()
		}
	}
	if start < 0 || end >= size || start > end {
		return none
	}
	return start, end
}

// read_range reads `length` bytes at `start` WITHOUT loading the whole file.
fn read_range(path string, start i64, length int) ?[]u8 {
	mut f := os.open(path) or { return none }
	defer { f.close() }
	data := f.read_bytes_at(length, u64(start))
	return data
}

fn main() {
	// Self-contained: synthesize a short sample.mp4 once if absent (needs ffmpeg).
	if !os.is_file(sample_video) {
		eprintln('generating ${sample_video} (one-time, via ffmpeg)...')
		os.execute('ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x480:rate=30:duration=8 -pix_fmt yuv420p ${sample_video}')
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
		request_handler: fn [mut viewers] (req_buffer []u8, fd int, mut out []u8) ! {
			out << handle(req_buffer, fd, mut viewers)!
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
