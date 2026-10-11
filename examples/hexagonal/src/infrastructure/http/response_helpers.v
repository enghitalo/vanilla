module http

import core
import hash as wyhash
import strconv
import time

const hex_digits = '0123456789abcdef'

// hex16 encodes the 64-bit wyhash as 16 lowercase hex chars on the stack —
// no `.hex()` string, no allocation.
@[direct_array_access]
fn hex16(h u64) [16]u8 {
	mut buf := [16]u8{}
	for i in 0 .. 16 {
		buf[i] = hex_digits[(h >> ((15 - i) * 4)) & 0xF]
	}
	return buf
}

// Complete responses without a body: const strings appended with
// core.append_str (BEST_PRACTICES §3a).
const http_bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const http_unauthorized = 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const http_server_error = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

// reason_phrase returns the const reason phrase for `status`.
fn reason_phrase(status int) string {
	return match status {
		200 { 'OK' }
		201 { 'Created' }
		400 { 'Bad Request' }
		404 { 'Not Found' }
		500 { 'Internal Server Error' }
		else { 'OK' }
	}
}

// "Date: " (6) + IMF-fixdate (29, "Sun, 06 Nov 1994 08:49:37 GMT") + CRLF (2).
const date_line_len = 37
const date_line_template = 'Date: Xxx, 00 Xxx 0000 00:00:00 GMT\r\n'

// DateCache holds one formatted `Date:` line and re-formats it only when the
// second changes, rewriting just the digits that moved (time.update_http_header,
// as in examples/async_date_timerfd): no calendar math per response. It is
// plain state its owner passes in, never a global — behind a vanilla server,
// give each worker its own (make_state), so it needs no lock.
pub struct DateCache {
mut:
	line [date_line_len]u8
	last i64 // unix second the line holds (0 = not formatted yet)
}

pub fn new_date_cache() DateCache {
	mut dc := DateCache{}
	unsafe { vmemcpy(&dc.line[0], date_line_template.str, date_line_len) }
	return dc
}

// refresh brings the line up to the current second (a no-op within it).
fn (mut dc DateCache) refresh() {
	now := time.unix_now()
	unsafe { time.update_http_header(&dc.line[6], date_line_len - 6, dc.last, now) or {} }
	dc.last = now
}

// The head build_basic_response writes is bounded: a status line of at most
// 44 bytes (11 digits, the longest reason phrase), the 37-byte Date line, 74
// bytes of content type and ETag, at most 20 digits of length and 23 closing
// bytes — under 200.
const max_head_len = 256

// build_basic_response turns the JSON body the caller appended at out[mark..]
// (json.encode_append) into a complete response, in place. The head carries
// the body's length and hash, so it is appended after the body, then moved in
// front of it: copy the head aside (it is bounded, max_head_len), shift the
// body right, copy the head into the gap. No allocation once `out` has
// reached its high-water mark, and `out` is never sliced (a slice would make
// a server drop its write buffer).
pub fn build_basic_response(mut out []u8, mark int, status int, mut dates DateCache) {
	body_len := out.len - mark
	// ETag = 64-bit wyhash hex-encoded on the stack — a cheap, strong opaque
	// validator (same as server.static_assets); a crypto digest here is
	// pure cost, and md5 is broken anyway.
	etag := hex16(wyhash.wyhash_c(unsafe { &u8(out.data) + mark }, u64(body_len), 0))
	dates.refresh()
	head_start := out.len
	core.append_str(mut out, 'HTTP/1.1 ')
	wi(mut out, status)
	out << ` `
	core.append_str(mut out, reason_phrase(status))
	core.append_str(mut out, '\r\n')
	unsafe { out.push_many(&dates.line[0], date_line_len) }
	// The ETag is DQUOTEd on the wire (RFC 9110 §8.8.3).
	core.append_str(mut out, 'Content-Type: application/json\r\nEtag: "')
	unsafe { out.push_many(&etag[0], 16) }
	core.append_str(mut out, '"\r\nContent-Length: ')
	wi(mut out, body_len)
	core.append_str(mut out, '\r\nConnection: close\r\n\r\n')
	head_len := out.len - head_start
	mut head := [max_head_len]u8{}
	unsafe {
		p := &u8(out.data)
		vmemcpy(&head[0], p + head_start, head_len)
		vmemmove(p + mark + head_len, p + mark, body_len)
		vmemcpy(p + mark, &head[0], head_len)
	}
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
