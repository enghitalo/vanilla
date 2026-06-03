module request_parser

const empty_space = u8(` `)
// NOTE: escaped rune literals like `\r` evaluate to the backslash byte (92) in
// this V toolchain, not 13/10 — which silently breaks all request parsing. Use
// explicit numeric byte values for CR (13) and LF (10).
const cr_char = u8(13)
const lf_char = u8(10)
const crlf = [u8(13), 10]!
const double_crlf = [u8(13), 10, 13, 10]!

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

	// RFC 9112 §2.1: the header section is `*( field-line CRLF )` and MAY be
	// empty. An empty section means the terminating blank-line CRLF sits right
	// at header_start (e.g. `GET / HTTP/1.1\r\n\r\n`). Handle it explicitly —
	// otherwise the double-CRLF search below never matches and a syntactically
	// valid request is wrongly rejected.
	if header_start + 1 < buffer.len && buffer[header_start] == cr_char
		&& buffer[header_start + 1] == lf_char {
		req.header_fields = Slice{
			start: header_start
			len:   0
		}
		body_start := header_start + crlf.len
		req.body = if body_start < buffer.len {
			Slice{
				start: body_start
				len:   buffer.len - body_start
			}
		} else {
			Slice{0, 0}
		}
		return req
	}

	header_len := find_sequence(&buffer[header_start], buffer.len - header_start, &double_crlf[0],
		double_crlf.len) or {
		return error('Missing header-body delimiter (no blank line terminating the header section)')
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

// ascii_ci_eq compares `len` bytes case-insensitively (ASCII only — HTTP header
// names are ASCII per RFC 9110 §5.1). No allocation, no lowercase copy: fold each
// byte inline. Kept tight because it runs on the header hot path.
@[direct_array_access; inline]
fn ascii_ci_eq(a &u8, b &u8, len int) bool {
	unsafe {
		for i in 0 .. len {
			x := a[i] ^ b[i]
			if x != 0 {
				// Bytes differ. The ONLY acceptable difference is the ASCII
				// case bit (0x20) on a letter — everything else is a mismatch.
				// This keeps the common (equal) byte to a single branch.
				if x != 0x20 {
					return false
				}
				c := a[i] | 0x20
				if c < `a` || c > `z` {
					return false
				}
			}
		}
	}
	return true
}

// get_header_value_slice returns the value of `name` as a zero-copy Slice.
// Header field names are CASE-INSENSITIVE (RFC 9110 §5.1), so `Content-Type`,
// `content-type` and `CONTENT-TYPE` all match.
@[direct_array_access]
pub fn (req HttpRequest) get_header_value_slice(name string) ?Slice {
	if req.header_fields.len <= 0 {
		return none
	}
	section_end := req.header_fields.start + req.header_fields.len
	mut pos := req.header_fields.start

	for pos <= section_end - 2 {
		line_start := pos
		// line_len = bytes before CRLF (the `-1` drops the CR before the LF).
		line_len := find_byte(&req.buffer[pos], section_end + 2 - pos, lf_char) or { return none } - 1
		if line_len <= 0 {
			return none
		}
		next_line := line_start + line_len + 2

		// Name must fit in the line and be followed immediately by ':'.
		if name.len > line_len || !ascii_ci_eq(&req.buffer[line_start], name.str, name.len)
			|| req.buffer[line_start + name.len] != colon_u8 {
			pos = next_line
			continue
		}

		// Skip optional whitespace after the colon (RFC 9112 §5).
		mut vpos := line_start + name.len + 1
		for vpos < req.buffer.len && req.buffer[vpos] == empty_space {
			vpos++
		}
		mut vend := vpos
		for vend < req.buffer.len && req.buffer[vend] != cr_char {
			vend++
		}
		return Slice{
			start: vpos
			len:   vend - vpos
		}
	}

	return none
}

// count_header counts header lines whose name case-insensitively equals `name`.
// Used by validate_http1 to enforce "exactly one Host" (RFC 9112 §3.2).
@[direct_array_access]
pub fn (req HttpRequest) count_header(name string) int {
	if req.header_fields.len <= 0 {
		return 0
	}
	section_end := req.header_fields.start + req.header_fields.len
	mut pos := req.header_fields.start
	mut count := 0
	for pos <= section_end - 2 {
		line_start := pos
		line_len := find_byte(&req.buffer[pos], section_end + 2 - pos, lf_char) or { break } - 1
		if line_len <= 0 {
			break
		}
		if name.len <= line_len && ascii_ci_eq(&req.buffer[line_start], name.str, name.len)
			&& req.buffer[line_start + name.len] == colon_u8 {
			count++
		}
		pos = line_start + line_len + 2
	}
	return count
}

// validate_http1 enforces the HTTP/1.1 MUSTs that require a 400 response. Call
// it after decode_http_request and map the returned error to 400 Bad Request.
//
// Kept separate from parsing on purpose: a parse-free fast responder pays
// nothing, and servers that DO process requests stay strictly conformant
// (Invariant 3). No new behavior is invented — only what the RFCs mandate.
pub fn (req HttpRequest) validate_http1() ! {
	// RFC 9112 §3.2: an HTTP/1.1 request MUST contain exactly one Host field;
	// a server MUST respond 400 to a request that lacks Host or has more than one.
	if req.version.len == 8 && ascii_ci_eq(&req.buffer[req.version.start], 'HTTP/1.1'.str, 8) {
		if req.count_header('Host') != 1 {
			return error('HTTP/1.1 request must have exactly one Host header (RFC 9112 §3.2)')
		}
	}
	// RFC 9112 §6.1: Content-Length and Transfer-Encoding must not both appear
	// (the classic request-smuggling ambiguity) — reject when they do.
	if req.get_header_value_slice('Content-Length') != none
		&& req.get_header_value_slice('Transfer-Encoding') != none {
		return error('Content-Length together with Transfer-Encoding is forbidden (RFC 9112 §6.1)')
	}
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
