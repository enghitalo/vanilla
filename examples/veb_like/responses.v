module main

import strings

// json_response builds an HTTP/1.1 response with a JSON body and a CORRECT
// Content-Length (computed from the body, never hand-counted — a mismatch makes
// clients hang or over-read).
fn json_response(status string, json_body string) []u8 {
	return 'HTTP/1.1 ${status}\r\nContent-Type: application/json\r\nContent-Length: ${json_body.len}\r\nConnection: keep-alive\r\n\r\n${json_body}'.bytes()
}

// text_response builds a plain-text 200 with a correct Content-Length.
fn text_response(body string) []u8 {
	return 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
}

// json_str quotes and escapes an arbitrary string into a JSON string literal.
// Route params and query values are raw bytes from the URL — interpolating them
// into JSON unescaped is an injection bug (a `"` or `\` breaks/forges the doc).
fn json_str(s string) string {
	mut b := strings.new_builder(s.len + 2)
	b.write_u8(`"`)
	for c in s {
		match c {
			`"` {
				b.write_string('\\"')
			}
			`\\` {
				b.write_string('\\\\')
			}
			`\n` {
				b.write_string('\\n')
			}
			`\r` {
				b.write_string('\\r')
			}
			`\t` {
				b.write_string('\\t')
			}
			else {
				if c < 0x20 {
					// Other control chars must be \u00XX-escaped per RFC 8259.
					b.write_string('\\u00')
					b.write_u8(hex_digit(c >> 4))
					b.write_u8(hex_digit(c & 0x0f))
				} else {
					b.write_u8(c)
				}
			}
		}
	}
	b.write_u8(`"`)
	return b.str()
}

@[inline]
fn hex_digit(n u8) u8 {
	return if n < 10 { `0` + n } else { `a` + (n - 10) }
}
