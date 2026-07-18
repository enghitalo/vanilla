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
// status line unparseable / conflicting framing headers
pub const err_malformed = -2
// Transfer-Encoding present — chunked responses are a follow-up; vanilla
// servers always answer with Content-Length
pub const err_chunked = -3
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

// frame_response returns the TOTAL byte length (head + body) of the first
// complete response buffered in `buf`, or a negative code: `incomplete`
// while more bytes are needed, `err_malformed` / `err_chunked` /
// `err_until_close` for responses that cannot be framed. Keep-alive
// pipelining works the same way as on the server: consume `total` bytes,
// compact, frame again.
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
	// Scan header lines for Content-Length / Transfer-Encoding. Lines start
	// after the status line's CRLF.
	mut content_length := i64(-1)
	mut i := 0
	for i + 1 < hl {
		if buf[i] == `\r` && buf[i + 1] == `\n` {
			line := i + 2
			if line >= hl - 2 {
				break // reached the blank line
			}
			if header_value_start(buf, line, hl, 'transfer-encoding') > 0 {
				return err_chunked
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
		}
		i++
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

// body_bounds returns (start, len) of the body inside a response already
// framed to `total` bytes (both 0 when there is no body).
pub fn body_bounds(buf []u8, total int) (int, int) {
	hl := head_len(buf)
	if hl < 0 || total <= hl {
		return 0, 0
	}
	return hl, total - hl
}
