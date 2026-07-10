module main

// Transfer-Encoding: chunked — reference design (request decode + response frame).
//
// Chunked encoding is how HTTP/1.1 sends a body of UNKNOWN length: a series of
// `<hex-size>\r\n<bytes>\r\n` chunks terminated by `0\r\n\r\n` (RFC 9112 §7.1).
// It is the streaming primitive of HTTP/1.1 — large uploads, live logs,
// generated output you don't want to buffer entirely before sending.
//
// WHAT THE CORE DOES TODAY (this section used to say "ASPIRATIONAL" — it isn't):
//   - FRAMES chunked requests: the handler is dispatched only after the
//     terminating zero-chunk arrived (request_parser.frame_chunked_total);
//     malformed chunk sizes are a 400 and an over-limit body a 413 BEFORE the
//     handler ever runs, so `req.body` always holds complete, well-formed
//     chunk frames.
//   - Ships the smuggling guard: `req.validate_http1()` rejects Content-Length
//     together with Transfer-Encoding (RFC 9112 §6.1) and enforces exactly-one
//     Host. It is OPT-IN by design (a parse-free fast responder pays nothing),
//     so a body-processing handler like this one calls it — one line.
//
// WHAT THE HANDLER STILL OWNS: `req.body` is the raw WIRE format. Decoding is
// handler-side and ZERO-COPY: `next_chunk` walks the frames by offsets and
// yields each chunk as a window into the request buffer. The echo below
// re-frames those views straight into `out` — the payload bytes are appended
// once and never pass through an intermediate buffer or string.
//
// RESPONSE side: a handler produces one buffer per request, so a chunked
// response built here is framing, not true streaming — for incremental
// delivery backed by the fd (backpressure via the event loop) see the async
// examples (examples/async_sse). The frames below are still byte-exact wire
// format; curl decodes them like any chunked response.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response

// Escaped rune literals are broken in this toolchain (docs/V_PERF_TOOLBOX.md
// gotcha) — CR/LF as explicit byte values, same as the core parser.
const cr = u8(13)
const lf = u8(10)

// ---- request side: zero-copy chunk iterator ---------------------------------

@[inline]
fn hex_digit(c u8) !int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	lc := c | 0x20 // lowercase ASCII letters
	if lc >= `a` && lc <= `f` {
		return int(lc - `a`) + 10
	}
	return error('invalid chunk size')
}

// next_chunk parses ONE chunk frame at `pos` in buf[..limit] and returns
// (data_start, data_len, next_pos):
//   data_len > 0  -> chunk data is the window buf[data_start .. data_start+data_len]
//   data_len == 0 -> terminating zero-chunk (next_pos is just past its CRLF)
// Chunk extensions (`;name=val`) are skipped, trailers are not modeled.
// Zero allocations, zero copies — callers consume the data as a view.
// In production malformed framing never reaches the handler (the core 400s it
// first); the error paths exist for direct-call tests and defense in depth.
@[direct_array_access]
fn next_chunk(buf []u8, pos int, limit int) !(int, int, int) {
	mut size := 0
	mut i := pos
	mut digits := 0
	for i < limit {
		c := buf[i]
		if c == cr || c == `;` {
			break
		}
		size = size * 16 + hex_digit(c)!
		digits++
		i++
	}
	if digits == 0 {
		return error('missing chunk size')
	}
	for i < limit && buf[i] != cr { // skip chunk extensions
		i++
	}
	if i + 1 >= limit || buf[i + 1] != lf {
		return error('truncated chunk-size line')
	}
	data_start := i + 2
	if size == 0 {
		// Terminating chunk: require the closing CRLF.
		if data_start + 1 >= limit || buf[data_start] != cr || buf[data_start + 1] != lf {
			return error('truncated terminating chunk')
		}
		return data_start, 0, data_start + 2
	}
	end := data_start + size
	if end + 2 > limit {
		return error('truncated chunk')
	}
	if buf[end] != cr || buf[end + 1] != lf {
		return error('chunk data not CRLF-terminated')
	}
	return data_start, size, end + 2
}

// decode_chunked_into appends the decoded payload into dst — ONE copy total,
// straight from the request-buffer windows; no intermediate buffers, no
// strings, no hex-string parsing. For handlers that need the body contiguous.
fn decode_chunked_into(buf []u8, start int, len int, mut dst []u8) ! {
	limit := start + len
	mut pos := start
	for {
		data_start, data_len, next_pos := next_chunk(buf, pos, limit)!
		if data_len == 0 {
			return
		}
		unsafe { dst.push_many(&buf[data_start], data_len) }
		pos = next_pos
	}
}

// ---- response side: frame views as chunks, no allocation --------------------

// ws appends a string's bytes straight into `out` (BEST_PRACTICES §3b).
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wx appends n's lowercase hex digits into `out` — the chunk-size line —
// via a stack scratch. No allocation, no `${n:x}`.
fn wx(mut out []u8, n int) {
	if n == 0 {
		out << u8(`0`)
		return
	}
	mut scratch := [8]u8{}
	mut i := 8
	mut v := u32(n)
	for v > 0 {
		i--
		d := u8(v & 0xF)
		scratch[i] = if d < 10 { `0` + d } else { `a` + (d - 10) }
		v >>= 4
	}
	unsafe { out.push_many(&scratch[i], 8 - i) }
}

// write_chunk frames one chunk into `out`: <hex-size>\r\n<data>\r\n. The data
// view is appended directly — never copied through an intermediate.
fn write_chunk(mut out []u8, data []u8) {
	wx(mut out, data.len)
	ws(mut out, '\r\n')
	out << data
	ws(mut out, '\r\n')
}

const resp_head_chunked = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n'.bytes()
const last_chunk = '0\r\n\r\n'.bytes()

// The no-body demo pieces — three separate frames on the wire.
const demo_pieces = ['first piece\n'.bytes(), 'second piece\n'.bytes(),
	'third piece\n'.bytes()]

// is_chunked reports whether Transfer-Encoding is `chunked` — compared in
// place over the header bytes (case-insensitive), no to_string/to_lower.
@[direct_array_access]
fn is_chunked(req request_parser.HttpRequest) bool {
	s := req.get_header_value_slice('Transfer-Encoding') or { return false }
	lit := 'chunked'
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if (req.buffer[s.start + i] | 0x20) != lit[i] {
			return false
		}
	}
	return true
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	// The RFC 9112 MUSTs, incl. the CL+TE request-smuggling rejection (§6.1).
	// Anything that processes bodies should pay this one call.
	req.validate_http1() or {
		out << response.tiny_bad_request_response
		return .close
	}
	out << resp_head_chunked
	if req.body.len > 0 && is_chunked(req) {
		// ECHO: walk the request's chunk frames and re-frame each data window
		// into the response — request payload bytes are appended exactly once.
		limit := req.body.start + req.body.len
		mut pos := req.body.start
		for {
			data_start, data_len, next_pos := next_chunk(req.buffer, pos, limit) or {
				out << response.tiny_bad_request_response
				return .close
			}
			if data_len == 0 {
				break
			}
			write_chunk(mut out, unsafe { (&req.buffer[data_start]).vbytes(data_len) })
			pos = next_pos
		}
	} else {
		// No chunked body: stream three known pieces to show the framing.
		for piece in demo_pieces {
			write_chunk(mut out, piece)
		}
	}
	out << last_chunk
	return .done
}

fn main() {
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
		handler:         handle
	})!
	println('Chunked streaming demo on http://localhost:3000/')
	println('  GET  /  -> three chunked pieces')
	println("  POST /  with Transfer-Encoding: chunked -> echoes your chunks back (try: curl -sS -H 'Transfer-Encoding: chunked' --data-binary 'hello' localhost:3000)")
	server.run()
}
