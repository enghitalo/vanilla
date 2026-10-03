module main

import core
import strconv

fn C.memchr(s voidptr, c int, n usize) voidptr

// Response framing, appended straight into the connection's write buffer: a
// const head (a string, appended with core.append_str), the body written in
// place, then its Content-Length digits patched into the head. No intermediate
// body buffer, no copy into `out`, no `${}` — nothing allocated per response
// (BEST_PRACTICES §1, §3).

const json_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const json_201_head = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: '
const json_400_head = 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: '
const keep_alive_tail = '\r\nConnection: keep-alive\r\n\r\n'

// Body remembers where, in `out`, the open Content-Length value and the body
// of the response being written start.
struct Body {
	digits_at int
	start     int
}

// begin_json appends a 200 JSON head whose Content-Length value is left open.
// Append the body, then close it with end_json.
@[inline]
fn begin_json(mut out []u8) Body {
	core.append_str(mut out, json_200_head)
	digits_at := out.len
	core.append_str(mut out, keep_alive_tail)
	return Body{digits_at, out.len}
}

// end_json writes the body's length into the head: the digits go in at
// digits_at, moving the tail and the body (a few dozen bytes) right by their
// count. `out` is the connection's reused buffer, so once it has grown to its
// high-water mark the extra room costs nothing.
fn end_json(mut out []u8, b Body) {
	mut digits := [20]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	n := strconv.write_dec(out.len - b.start, mut view)
	moved := out.len - b.digits_at
	unsafe {
		out.grow_len(n)
		vmemmove(&u8(out.data) + b.digits_at + n, &u8(out.data) + b.digits_at, moved)
		vmemcpy(&u8(out.data) + b.digits_at, &digits[0], n)
	}
}

// json_field appends a 200 JSON response whose body is `pre`, `value` as a
// JSON string, then `post`: `{"id":"42"}` from ('{"id":', '42', '}').
fn json_field(mut out []u8, pre string, value string, post string) {
	b := begin_json(mut out)
	core.append_str(mut out, pre)
	json_string(mut out, value)
	core.append_str(mut out, post)
	end_json(mut out, b)
}

// fixed_json frames a body that never changes, once at init, for a const.
fn fixed_json(head string, body string) string {
	mut out := []u8{cap: head.len + 24 + keep_alive_tail.len + body.len}
	core.append_str(mut out, head)
	digits_at := out.len
	core.append_str(mut out, keep_alive_tail)
	start := out.len
	core.append_str(mut out, body)
	end_json(mut out, Body{digits_at, start})
	return out.bytestr()
}

// json_string appends `s` as a quoted JSON string. Params come raw from the
// URL, so a `"` or `\` must be escaped, or it would break or forge the
// document (BEST_PRACTICES §8). Bytes are compared by value: 34 `"`, 92 `\`,
// 10 LF, 13 CR, 9 TAB (escaped rune literals are unreliable in byte compares,
// see docs/V_PERF_TOOLBOX.md).
@[direct_array_access]
fn json_string(mut out []u8, s string) {
	out << u8(34)
	for i in 0 .. s.len {
		c := s[i]
		match c {
			34 { core.append_str(mut out, '\\"') }
			92 { core.append_str(mut out, '\\\\') }
			10 { core.append_str(mut out, '\\n') }
			13 { core.append_str(mut out, '\\r') }
			9 { core.append_str(mut out, '\\t') }
			else {
				if c < 0x20 {
					// other control bytes: \u00XX (RFC 8259)
					core.append_str(mut out, '\\u00')
					out << hex_digit(c >> 4)
					out << hex_digit(c & 0x0f)
				} else {
					out << c
				}
			}
		}
	}
	out << u8(34)
}

@[inline]
fn hex_digit(n u8) u8 {
	return if n < 10 { `0` + n } else { `a` + (n - 10) }
}

// drop_body truncates the response appended into `out` from `start` to its
// head: a HEAD request served by a GET branch gets GET's headers (its
// Content-Length included) and no body (RFC 9110 §9.3.2).
fn drop_body(mut out []u8, start int) {
	unsafe {
		mut i := start
		for i + 3 < out.len {
			q := C.memchr(&u8(out.data) + i, `\r`, usize(out.len - 3 - i))
			if q == nil {
				return
			}
			i = int(&u8(q) - &u8(out.data))
			if out[i + 1] == `\n` && out[i + 2] == `\r` && out[i + 3] == `\n` {
				out.len = i + 4
				return
			}
			i++
		}
	}
}
