module client

// HTTP/1.1 CLIENT codec — the mirror image of request_parser/ + response/
// (issue #122 Client story): a request SERIALIZER and a response PARSER,
// pure bytes-in/bytes-out. No sockets, no event loop, no allocation — the
// same discipline as the server-side codecs. Composition happens in the
// caller: transport.dial_* → send → event_loop.watch_fd + .suspend → recv →
// frame_response (see examples/mesh). Per the #122 client study, callers
// POOL connections per worker (make_state — a dial costs ~4× a request) and
// prefer unix_socket_path transports (2.3–2.7× TCP loopback).
import strconv

// no_body is the empty-body argument for write_request, allocated once.
pub const no_body = []u8{}

// frame_response return codes (mirrors request_parser's negative-int
// convention: -1 incomplete, other negatives are hard errors).
pub const incomplete = -1
// status line unparseable / conflicting or invalid framing headers /
// malformed chunked encoding
pub const err_malformed = -2
// no Content-Length and a body-bearing status: the body is delimited by
// connection close (RFC 9112 §6.3 fallback) — not frameable in advance
pub const err_until_close = -4

@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends n's decimal digits — itoa into a stack scratch, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// write_request appends a complete HTTP/1.1 request (head + body) into `out`
// — parts are appended directly, nothing is interpolated or concatenated.
// `extra_headers` is raw pre-formatted header lines ('K: v\r\n...') or ''.
// Keep-alive is the HTTP/1.1 default, so no Connection header is emitted;
// pass 'Connection: close\r\n' in extra_headers for one-shot requests.
// A Content-Length header is emitted whenever body is non-empty.
pub fn write_request(mut out []u8, method string, target string, host string, extra_headers string, body []u8) {
	ws(mut out, method)
	ws(mut out, ' ')
	ws(mut out, target)
	ws(mut out, ' HTTP/1.1\r\nHost: ')
	ws(mut out, host)
	ws(mut out, '\r\n')
	if extra_headers.len > 0 {
		ws(mut out, extra_headers)
	}
	if body.len > 0 {
		ws(mut out, 'Content-Length: ')
		wi(mut out, i64(body.len))
		ws(mut out, '\r\n')
	}
	ws(mut out, '\r\n')
	if body.len > 0 {
		out << body
	}
}

// write_get — the common case: a bodyless GET.
pub fn write_get(mut out []u8, target string, host string) {
	write_request(mut out, 'GET', target, host, '', no_body)
}

// head_len returns the byte length of the response head INCLUDING the blank
// line (i.e. the body offset), or -1 while the head is still incomplete.
@[direct_array_access]
pub fn head_len(buf []u8) int {
	for i := 0; i + 3 < buf.len; i++ {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i + 4
		}
	}
	return -1
}

// status_code parses the status line ('HTTP/1.x NNN ...') and returns the
// 3-digit code, or -1 if the line is not a valid HTTP/1 status line.
@[direct_array_access]
pub fn status_code(buf []u8) int {
	// 'HTTP/1.x ' is 9 bytes; the code is 3 more.
	if buf.len < 12 {
		return -1
	}
	if buf[0] != `H` || buf[1] != `T` || buf[2] != `T` || buf[3] != `P` || buf[4] != `/`
		|| buf[5] != `1` || buf[6] != `.` || buf[8] != ` ` {
		return -1
	}
	d0, d1, d2 := buf[9], buf[10], buf[11]
	if d0 < `1` || d0 > `9` || d1 < `0` || d1 > `9` || d2 < `0` || d2 > `9` {
		return -1
	}
	return int(d0 - `0`) * 100 + int(d1 - `0`) * 10 + int(d2 - `0`)
}

// header_line_matches reports whether the header line starting at `i` is
// `name` (case-insensitive; `name` must be given lowercase) and returns the
// value start offset past the colon and optional spaces, or -1.
@[direct_array_access]
fn header_value_start(buf []u8, i int, head_end int, name string) int {
	if i + name.len >= head_end {
		return -1
	}
	for j in 0 .. name.len {
		mut c := buf[i + j]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != name[j] {
			return -1
		}
	}
	if buf[i + name.len] != `:` {
		return -1
	}
	mut v := i + name.len + 1
	for v < head_end && (buf[v] == ` ` || buf[v] == `\t`) {
		v++
	}
	return v
}

// frame_response returns the TOTAL byte length (head + body, chunk framing
// included) of the first complete response buffered in `buf`, or a negative
// code: `incomplete` while more bytes are needed, `err_malformed` /
// `err_until_close` for responses that cannot be framed. Both framings are
// handled: Content-Length and Transfer-Encoding: chunked (trailer fields
// after the terminating chunk are skipped). Keep-alive pipelining works the
// same way as on the server: consume `total` bytes, compact, frame again.
@[direct_array_access]
pub fn frame_response(buf []u8) int {
	hl := head_len(buf)
	if hl < 0 {
		return incomplete
	}
	st := status_code(buf)
	if st < 100 {
		return err_malformed
	}
	// Bodyless by status (RFC 9110): 1xx interim, 204, 304. (A HEAD response
	// is also bodyless, but only the caller knows the request method — frame
	// HEAD exchanges with head_len directly.)
	if st < 200 || st == 204 || st == 304 {
		return hl
	}
	// Scan header lines for Content-Length / Transfer-Encoding, jumping line
	// to line (LF to LF) instead of testing every byte for CRLF.
	mut content_length := i64(-1)
	mut chunked := false
	mut line := next_line(buf, 0, hl) // first header line, past the status line
	for line > 0 && line < hl - 2 {
		te := header_value_start(buf, line, hl, 'transfer-encoding')
		if te > 0 {
			// The only coding the codec decodes is a lone/final chunked
			// (RFC 9112 §6.1); anything else cannot be framed.
			if !value_has_chunked(buf, te, hl) {
				return err_malformed
			}
			chunked = true
		}
		v := header_value_start(buf, line, hl, 'content-length')
		if v > 0 {
			mut n := i64(0)
			mut d := v
			for d < hl && buf[d] >= `0` && buf[d] <= `9` {
				n = n * 10 + i64(buf[d] - `0`)
				if n > 0x7fff_0000 {
					return err_malformed
				}
				d++
			}
			if d == v || (d < hl && buf[d] != `\r`) {
				return err_malformed // empty or non-numeric value
			}
			if content_length >= 0 && content_length != n {
				return err_malformed // conflicting duplicates
			}
			content_length = n
		}
		line = next_line(buf, line, hl)
	}
	if chunked {
		// TE wins over any (smuggling-suspect) Content-Length — same
		// precedence the server enforces (RFC 9112 §6.3).
		return frame_chunked_body(buf, hl)
	}
	if content_length < 0 {
		return err_until_close
	}
	total := i64(hl) + content_length
	if i64(buf.len) < total {
		return incomplete
	}
	return int(total)
}

// next_line returns the offset just past the next LF at/after `i` (i.e. the
// start of the following line), or -1 when no further line starts before
// `head_end`.
@[direct_array_access; inline]
fn next_line(buf []u8, i int, head_end int) int {
	mut j := i
	for j < head_end && buf[j] != `\n` {
		j++
	}
	if j + 1 >= head_end {
		return -1
	}
	return j + 1
}

// value_has_chunked reports whether the header value at [v..head_end) says
// (or ends in) 'chunked' — ASCII case-insensitive substring scan.
@[direct_array_access]
fn value_has_chunked(buf []u8, v int, head_end int) bool {
	needle := 'chunked'
	mut i := v
	for i + needle.len <= head_end {
		if buf[i] == `\r` {
			return false
		}
		mut ok := true
		for j in 0 .. needle.len {
			mut c := buf[i + j]
			if c >= `A` && c <= `Z` {
				c += 32
			}
			if c != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
		i++
	}
	return false
}

@[inline]
fn hex_digit(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

// frame_chunked_body walks chunk-size lines from `body_start` and returns
// the total message length once the terminating zero chunk (plus any
// trailer fields — skipped, unlike the server-side framer, since real
// upstreams do send them) and its final CRLF are buffered. The chunk-size
// accumulator is i64 with a hard cap so a hostile size can neither wrap
// negative nor hijack the zero-chunk branch (the request_parser #109
// lessons, applied here too).
@[direct_array_access]
fn frame_chunked_body(buf []u8, body_start int) int {
	mut pos := body_start
	for {
		// chunk-size line: HEXDIG+ [;extensions] CRLF
		mut size := i64(0)
		mut j := pos
		mut digits := 0
		for j < buf.len && buf[j] != `\r` && buf[j] != `;` {
			d := hex_digit(buf[j])
			if d < 0 {
				return err_malformed
			}
			size = size * 16 + i64(d)
			if size > 0x7fff_0000 {
				return err_malformed
			}
			j++
			digits++
		}
		if j >= buf.len {
			return if digits > 16 { err_malformed } else { incomplete }
		}
		if digits == 0 {
			return err_malformed // empty size line
		}
		// skip extensions to the CRLF
		for j < buf.len && buf[j] != `\r` {
			j++
		}
		if j + 1 >= buf.len {
			return incomplete
		}
		if buf[j + 1] != `\n` {
			return err_malformed
		}
		data_start := j + 2
		if size == 0 {
			// Trailer section: zero or more header lines, then a blank CRLF.
			mut t := data_start
			for {
				if t + 1 >= buf.len {
					return incomplete
				}
				if buf[t] == `\r` && buf[t + 1] == `\n` {
					return t + 2 // the final CRLF — message complete
				}
				// skip one trailer line
				for t < buf.len && buf[t] != `\n` {
					t++
				}
				if t >= buf.len {
					return incomplete
				}
				t++ // past the LF
			}
		}
		// chunk-data + REQUIRED CRLF (RFC 9112 §7.1) — verified, not assumed.
		crlf_at := i64(data_start) + size
		if crlf_at + 1 >= i64(buf.len) {
			return incomplete
		}
		if buf[int(crlf_at)] != `\r` || buf[int(crlf_at) + 1] != `\n` {
			return err_malformed
		}
		pos = int(crlf_at) + 2
	}
	return incomplete
}

// body_bounds returns (start, len) of the RAW body region inside a response
// already framed to `total` bytes (both 0 when there is no body). For a
// chunked response the region still carries the chunk framing — use
// append_body for the decoded bytes.
pub fn body_bounds(buf []u8, total int) (int, int) {
	hl := head_len(buf)
	if hl < 0 || total <= hl {
		return 0, 0
	}
	return hl, total - hl
}

// is_chunked reports whether the (complete-headed) response declares
// Transfer-Encoding — i.e. whether the body region is chunk-framed.
@[direct_array_access]
pub fn is_chunked(buf []u8) bool {
	hl := head_len(buf)
	if hl < 0 {
		return false
	}
	s, _ := header_value_from(buf, hl, 'transfer-encoding')
	return s >= 0
}

// header_value returns (start, len) of the first `name` header's value in
// the response head, or (-1, 0) when absent. `name` must be lowercase; the
// match is ASCII case-insensitive. The bounds are a zero-copy view into buf.
pub fn header_value(buf []u8, name string) (int, int) {
	hl := head_len(buf)
	if hl < 0 {
		return -1, 0
	}
	return header_value_from(buf, hl, name)
}

// header_value_from is header_value with the head walk already paid — every
// path that has `hl` in hand goes through here so the head is scanned once.
@[direct_array_access]
fn header_value_from(buf []u8, hl int, name string) (int, int) {
	mut line := next_line(buf, 0, hl)
	for line > 0 && line < hl - 2 {
		v := header_value_start(buf, line, hl, name)
		if v > 0 {
			mut e := v
			for e < hl && buf[e] != `\r` {
				e++
			}
			return v, e - v
		}
		line = next_line(buf, line, hl)
	}
	return -1, 0
}

// append_body appends the DECODED body of a framed response into `out`: the
// raw bytes for a Content-Length body, the de-chunked data for a chunked
// one — a single call that works against any upstream. Returns false only
// if the (already-framed) chunk structure fails to re-parse.
@[direct_array_access]
pub fn append_body(mut out []u8, buf []u8, total int) bool {
	// One head walk serves the bounds AND the framing question.
	hl := head_len(buf)
	if hl < 0 || total <= hl {
		return true // no body
	}
	start := hl
	raw_len := total - hl
	te, _ := header_value_from(buf, hl, 'transfer-encoding')
	if te < 0 {
		unsafe { out.push_many(&u8(buf.data) + start, raw_len) }
		return true
	}
	mut pos := start
	for pos < total {
		mut size := i64(0)
		mut j := pos
		for j < total && buf[j] != `\r` && buf[j] != `;` {
			d := hex_digit(buf[j])
			if d < 0 {
				return false
			}
			size = size * 16 + i64(d)
			j++
		}
		for j < total && buf[j] != `\r` {
			j++
		}
		data := j + 2
		if size == 0 {
			return true // trailers (if any) carry no body data
		}
		if i64(data) + size > i64(total) {
			return false
		}
		unsafe { out.push_many(&u8(buf.data) + data, int(size)) }
		pos = data + int(size) + 2 // past data + CRLF
	}
	return true
}
