module request_parser

const empty_space = u8(` `)
const cr_char = u8(`\r`)
const lf_char = u8(`\n`)
const crlf = [u8(`\r`), `\n`]!
const double_crlf = [u8(`\r`), `\n`, `\r`, `\n`]!

const colon_u8 = u8(`:`)
const slash_u8 = u8(`/`)
const question_mark_u8 = u8(`?`)
const amperstand_u8 = u8(`&`)
const equal_u8 = u8(`=`)

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
		if p == nil {
			return error('byte not found')
		}
		return int(&u8(p) - buf)
	}
}

@[inline]
fn find_sequence(buf &u8, len int, bytes_ptr &u8, bytes_len int) !int {
	unsafe {
		p := C.memmem(buf, len, bytes_ptr, bytes_len)
		if p == nil {
			return error('bytes not found')
		}
		return int(&u8(p) - buf)
	}
}

// Fast comparison of two byte slices
@[inline]
fn bytes_equal(a &u8, a_len int, b &u8, b_len int) bool {
	if a_len != b_len {
		return false
	}
	unsafe {
		return C.memcmp(a, b, a_len) == 0
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

	header_len := find_sequence(&buffer[header_start], buffer.len - header_start, &double_crlf[0],
		double_crlf.len) or {
		return error("Missing header-body delimiter. Non-header HTTP/1.0 aren't supported.")
	}

	if header_len + header_start + double_crlf.len == buffer.len {
		// No body present
		req.header_fields = Slice{
			start: header_start
			len:   header_len
		}
		req.body = Slice{0, 0}
		return req
	} else {
		// Body present
		req.header_fields = Slice{
			start: header_start
			len:   header_len
		}
		body_start := header_start + header_len + double_crlf.len
		req.body = Slice{
			start: body_start
			len:   buffer.len - body_start
		}
		return req
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
		line_len := find_byte(&req.buffer[pos], req.header_fields.start + req.header_fields.len + 2 - pos,
			lf_char) or { return none } - 1
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

// get_query_slice extracts a query parameter value as a Slice (ZERO ALLOCATIONS)
// Example: GET /users?id=123&format=json
//   get_query_slice('id'.bytes()) -> Slice pointing to "123"
pub fn (req HttpRequest) get_query_slice(key []u8) ?Slice {
	path_start := req.path.start
	path_len := req.path.len

	// Find '?' in path using memchr
	q_pos := find_byte(&req.buffer[path_start], path_len, question_mark_u8) or {
		return none // No query string
	}

	// Start of query string (after '?')
	mut pos := path_start + q_pos + 1
	path_end := path_start + path_len

	// Parse query string: key1=val1&key2=val2
	for pos < path_end {
		// Find '=' for this key
		eq_pos := find_byte(&req.buffer[pos], path_end - pos, equal_u8) or {
			break // No '=' found, malformed query
		}

		key_len := eq_pos

		// Check if key matches using memcmp
		if key_len == key.len && unsafe { C.memcmp(&req.buffer[pos], &key[0], key.len) } == 0 {
			// Found matching key, extract value
			value_start := pos + eq_pos + 1

			// Find '&' or end of path using memchr
			value_len := find_byte(&req.buffer[value_start], path_end - value_start, amperstand_u8) or {
				// Last parameter, no '&' found
				path_end - value_start
			}

			return Slice{
				start: value_start
				len:   value_len
			}
		}

		// Skip to next parameter (find '&')
		amp_pos := find_byte(&req.buffer[pos], path_end - pos, amperstand_u8) or {
			break // Last parameter, no match
		}
		pos += amp_pos + 1
	}

	return none
}

// Deprecated: Use get_query_slice instead for zero-copy performance
pub fn (req HttpRequest) get_query(key string) Slice {
	return req.get_query_slice(key.bytes()) or { Slice{0, 0} }
}
