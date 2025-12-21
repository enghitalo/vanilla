module request_parser

const empty_space = u8(` `)
const cr_char = u8(`\r`)
const lf_char = u8(`\n`)

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
	method  Slice
	path    Slice // TODO: change to request_target (rfc9112)
	version Slice
	// header_fields Slice
	// body Slice
}

fn C.memchr(s &u8, c int, n usize) &u8

// libc memchr is AVX2-accelerated via glibc IFUNC
@[inline]
fn find_byte(buf &u8, len int, c u8) int {
	unsafe {
		p := C.memchr(buf, c, len)
		if p == voidptr(nil) {
			return -1
		}
		return int(p - buf)
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
pub fn parse_http1_request_line(mut req HttpRequest) ! {
	unsafe {
		buf := &req.buffer[0]
		len := req.buffer.len

		if len < 12 {
			return error('Too short')
		}

		// METHOD
		pos1 := find_byte(buf, len, empty_space)
		if pos1 <= 0 {
			return error('Invalid method')
		}
		req.method = Slice{0, pos1}

		// PATH - skip any extra spaces
		mut pos2 := pos1 + 1
		for pos2 < len && buf[pos2] == empty_space {
			pos2++
		}
		if pos2 >= len {
			return error('Missing path')
		}

		path_start := pos2
		space_pos := find_byte(buf + pos2, len - pos2, empty_space)
		cr_pos := find_byte(buf + pos2, len - pos2, cr_char)

		if space_pos < 0 && cr_pos < 0 {
			return error('Invalid request line')
		}

		// pick earliest delimiter
		mut path_len := 0
		mut delim_pos := 0
		if space_pos >= 0 && (cr_pos < 0 || space_pos < cr_pos) {
			path_len = space_pos
			delim_pos = pos2 + space_pos
		} else {
			path_len = cr_pos
			delim_pos = pos2 + cr_pos
		}

		req.path = Slice{path_start, path_len}

		// VERSION
		if buf[delim_pos] == cr_char {
			// No HTTP version specified
			req.version = Slice{delim_pos, 0}
		} else {
			version_start := delim_pos + 1
			cr := find_byte(buf + version_start, len - version_start, cr_char)
			if cr < 0 {
				return error('Missing CR')
			}
			req.version = Slice{version_start, cr}
			delim_pos = version_start + cr
		}

		// Validate CRLF
		if delim_pos + 1 >= len || buf[delim_pos + 1] != lf_char {
			return error('Invalid CRLF')
		}
	}
}

pub fn decode_http_request(buffer []u8) !HttpRequest {
	mut req := HttpRequest{
		buffer: buffer
	}

	parse_http1_request_line(mut req)!
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
	mut pos := req.version.start + req.version.len + 2 // Start after request line (CRLF)
	if pos >= req.buffer.len {
		return none
	}

	for pos < req.buffer.len {
		if unsafe {
			vmemcmp(&req.buffer[pos], name.str, name.len)
		} == 0 {
			pos += name.len
			if req.buffer[pos] != `:` {
				return none
			}
			pos++
			for pos < req.buffer.len && (req.buffer[pos] == ` ` || req.buffer[pos] == `\t`) {
				pos++
			}
			if pos >= req.buffer.len {
				return none
			}
			mut start := pos
			for pos < req.buffer.len && req.buffer[pos] != `\r` {
				pos++
			}
			return Slice{
				start: start
				len:   pos - start
			}
		}
		if req.buffer[pos] == `\r` {
			pos++
			if pos < req.buffer.len && req.buffer[pos] == `\n` {
				pos++
			}
		} else {
			pos++
		}
	}

	return none
}
