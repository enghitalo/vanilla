module main

import strconv

// Response framing — const heads/tails around the two dynamic byte ranges:
// the Content-Length digits and the body. Nothing is `${}`-interpolated:
// interpolation allocates an intermediate string per fragment per request
// (and calls `.str()` on ints); appending consts and writing the length
// digits in place costs ONE exact-size noscan allocation per response.
const json_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()
const json_201_head = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: '.bytes()
const keep_alive_tail = '\r\nConnection: keep-alive\r\n\r\n'.bytes()

// json_ok frames `body` as a 200 response with a CORRECT Content-Length
// (computed from the body, never hand-counted — a mismatch makes clients hang
// or over-read).
fn json_ok(body []u8) []u8 {
	return frame(json_200_head, body)
}

// json_created frames `body` as a 201 response (same discipline).
fn json_created(body []u8) []u8 {
	return frame(json_201_head, body)
}

// frame = head const + Content-Length digits + tail const + body. The body is
// built BEFORE the head so the length is known when the header is written —
// that ordering is what lets the whole response land in one exact-size buffer
// (20 spare bytes cover the length digits).
fn frame(head []u8, body []u8) []u8 {
	mut out := []u8{cap: head.len + 20 + keep_alive_tail.len + body.len}
	out << head
	wi(mut out, body.len)
	out << keep_alive_tail
	out << body
	return out
}

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

// json_escape_into writes `s` into `out` as a quoted JSON string literal.
// Route params and wildcards are raw bytes from the URL — reflecting them into
// JSON unescaped is an injection bug (a `"` or `\` breaks/forges the doc).
// The escaped bytes go STRAIGHT into the caller's body builder — no
// intermediate string per param (the old json_str built one, which was then
// interpolated into the body, which was then interpolated into the response:
// three allocations deep per param per request).
// Byte comparisons use numeric values (34 `"`, 92 `\`, 10 LF, 13 CR, 9 TAB):
// escaped rune literals (`\n` and friends) are unreliable in byte compares
// (see docs/V_PERF_TOOLBOX.md gotchas); '\\n' inside ordinary string literals
// is fine.
@[direct_array_access]
fn json_escape_into(mut out []u8, s []u8) {
	out << u8(34) // opening '"'
	for c in s {
		match c {
			34 { // '"'
				ws(mut out, '\\"')
			}
			92 { // '\'
				ws(mut out, '\\\\')
			}
			10 { // LF
				ws(mut out, '\\n')
			}
			13 { // CR
				ws(mut out, '\\r')
			}
			9 { // TAB
				ws(mut out, '\\t')
			}
			else {
				if c < 0x20 {
					// Other control chars must be \u00XX-escaped per RFC 8259.
					ws(mut out, '\\u00')
					out << hex_digit(c >> 4)
					out << hex_digit(c & 0x0f)
				} else {
					out << c
				}
			}
		}
	}
	out << u8(34) // closing '"'
}

@[inline]
fn hex_digit(n u8) u8 {
	return if n < 10 { `0` + n } else { `a` + (n - 10) }
}
