module request_parser

const empty_space = u8(` `)
const cr_char = u8(`\r`)
const lf_char = u8(`\n`)
const crlf = [u8(`\r`), `\n`]!
const double_crlf = [u8(`\r`), `\n`, `\r`, `\n`]!

pub struct Slice {
pub:
	start int
	len   int
}

// TODO make fields immutable
pub struct HttpRequest {
pub:
	buffer []u8
pub mut:
	method        Slice
	path          Slice // TODO: change to request_target (rfc9112)
	version       Slice
	header_fields Slice
	body          Slice
}

fn C.memchr(buf &u8, char int, len usize) &u8
fn C.memmem(haystack &u8, h_len usize, needle &u8, n_len usize) &u8

// libc memchr is AVX2-accelerated via glibc IFUNC
@[inline]
fn find_byte(buf &u8, len int, c u8) !int {
	unsafe {
		p := C.memchr(buf, c, len)
		if p == voidptr(nil) {
			return error('byte not found')
		}
		return int(&u8(p) - buf)
	}
}

fn find_sequence(buf &u8, len int, bytes_ptr &u8, bytes_len int) !int {
	unsafe {
		p := C.memmem(buf, len, bytes_ptr, bytes_len)
		if p == voidptr(nil) {
			return error('bytes not found')
		}
		return int(&u8(p) - buf)
	}
}

// spec: https://datatracker.ietf.org/doc/rfc9112/
// request-line is the start-line for for requests
// According to RFC 9112, the request line is structured as:
// `request-line   = method SP request-target SP HTTP-version`
// where:
// METHOD is the HTTP method (e.g., GET, POST)
// SP is a single space character
// REQUEST-TARGET is the path or resource being requested
// HTTP-VERSION is the version of HTTP being used (e.g., HTTP/1.1)
// CRLF is a carriage return followed by a line feed
@[direct_array_access]
pub fn parse_http1_request_line(mut req HttpRequest) !int {
	buf := req.buffer
	len := buf.len
	if len < 12 {
		return error('request line too short')
	}

	unsafe {
		b := &buf[0]

		// Find first SP: end of method
		method_len := find_byte(b, len, empty_space) or {
			return error('Missing space after method')
		}
		if method_len == 0 {
			return error('empty method')
		}
		req.method = Slice{0, method_len}
		// Skip spaces after method
		mut pos := method_len + 1
		for pos < len && buf[pos] == empty_space {
			pos++
		}
		if pos == len {
			return error('missing request-target')
		}

		// Find next SP or CR (whichever comes first)
		sp_pos := find_byte(&buf[pos], len - pos, empty_space) or {
			return error('Missing space after request-target')
		}
		cr_pos := find_byte(&buf[pos], len - pos, cr_char) or { return error('Missing CR') }

		path_end := if sp_pos < cr_pos { pos + sp_pos } else { pos + cr_pos }
		req.path = Slice{pos, path_end - pos}

		// If we hit CR directly after path → HTTP/0.9 style (no version)
		if sp_pos > cr_pos {
			if path_end + 1 >= len || buf[path_end + 1] != lf_char {
				return error('expected LF after CR')
			}
			req.version = Slice{0, 0}
			return path_end + 2
		}

		// Otherwise: version follows the second SP
		version_start := path_end + 1
		cr_after_version := find_byte(&buf[version_start], len - version_start, cr_char) or {
			return error('Missing CR')
		}
		req.version = Slice{version_start, cr_after_version}

		end_of_line := version_start + cr_after_version
		if end_of_line + 1 >= len || buf[end_of_line + 1] != lf_char {
			return error('expected LF after CR')
		}

		return end_of_line + 2 // position after \r\n
	}
}

pub fn decode_http_request(buffer []u8) !HttpRequest {
	mut req := HttpRequest{
		buffer: buffer
	}

	// header_start is the byte index immediately after the request line's \r\n
	header_start := parse_http1_request_line(mut req)!

	// Find the end of the header block (\r\n\r\n)
	mut body_start := -1
	for i := header_start; i <= buffer.len - 4; i++ {
		if buffer[i] == cr_char && buffer[i + 1] == lf_char && buffer[i + 2] == cr_char
			&& buffer[i + 3] == lf_char {
			body_start = i + 4

			// The header fields slice covers everything from header_start
			// up to (but not including) the final double CRLF
			req.header_fields = Slice{
				start: header_start
				len:   i - header_start
			}
			break
		}
	}

	if body_start != -1 {
		req.body = Slice{
			start: body_start
			len:   buffer.len - body_start
		}
	} else {
		// If no body delimiter found, assume headers go to end or body is missing
		req.header_fields = Slice{header_start, buffer.len - header_start - 2}
		req.body = Slice{0, 0}
	}

	return req
}

// Helper function to convert Slice to string for debugging
pub fn (slice Slice) to_string(buffer []u8) string {
	if slice.len <= 0 {
		return ''
	}
	return buffer[slice.start..slice.start + slice.len].bytestr()
}

@[direct_array_access]
pub fn (req HttpRequest) get_header_value_slice(name string) ?Slice {
	mut pos := req.header_fields.start

	if pos >= req.buffer.len {
		return none
	}

	for pos <= req.header_fields.start + req.header_fields.len - 2 {
		line_len := find_byte(&req.buffer[pos], req.header_fields.len + 2 - (pos - req.header_fields.start),
			lf_char)! - 1
		if line_len <= 0 {
			return none
		}
		if unsafe {
			vmemcmp(&req.buffer[pos], name.str, name.len)
		} != 0 {
			pos += line_len + 2
			continue
		} else {
			pos += name.len
			if req.buffer[pos] != `:` {
				pos = line_len + 1
				continue
			}
			pos++
			for pos < req.buffer.len && req.buffer[pos] == empty_space {
				pos++
			}
			if pos >= req.buffer.len {
				return none
			}
			mut start := pos
			for pos < req.buffer.len && req.buffer[pos] != cr_char {
				pos++
			}
			return Slice{
				start: start
				len:   pos - start
			}
		}
	}

	return none
}
