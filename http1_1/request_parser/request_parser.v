module request_parser

const empty_space = u8(` `)
// NOTE: escaped rune literals like `\r` evaluate to the backslash byte (92) in
// this V toolchain, not 13/10 — which silently breaks all request parsing. Use
// explicit numeric byte values for CR (13) and LF (10).
const cr_char = u8(13)
const lf_char = u8(10)
const htab_char = u8(9)
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

// find_byte_idx is the no-Result hot-path twin of find_byte: returns the index of
// `c`, or -1 when absent. Returning a plain int avoids the `!int` Result boxing
// (callgrind showed find_byte's wrapper cost ~3x the underlying memchr on the
// short request line — pure overhead per pipelined request). Used by the framing
// + request-line parsers that run on every request.
@[inline]
fn find_byte_idx(buf &u8, len int, c u8) int {
	p := unsafe { C.memchr(buf, c, len) }
	if p == unsafe { nil } {
		return -1
	}
	return int(unsafe { &u8(p) - buf })
}

// memmem_idx_portable is the Windows stand-in for GNU memmem (msvcrt has no
// equivalent): memchr hops to each candidate first byte (memchr is the
// optimized primitive msvcrt does have), then one memcmp confirms the needle.
// Zero allocation; returns the match index or -1.
@[inline]
fn memmem_idx_portable(buf &u8, len int, bytes_ptr &u8, bytes_len int) int {
	if bytes_len <= 0 || len < bytes_len {
		return -1
	}
	first := unsafe { *bytes_ptr }
	mut pos := 0
	for pos <= len - bytes_len {
		p := unsafe { C.memchr(buf + pos, first, usize(len - bytes_len - pos + 1)) }
		if p == unsafe { nil } {
			return -1
		}
		idx := int(unsafe { &u8(p) - buf })
		if unsafe { C.memcmp(&u8(p), bytes_ptr, bytes_len) } == 0 {
			return idx
		}
		pos = idx + 1
	}
	return -1
}

// find_sequence_idx returns the index of the needle, or -1 — a plain int, no
// `!int` Result boxing on the per-request `\r\n\r\n` scan (see find_byte_idx).
// libc memmem where it exists (AVX2-accelerated via glibc IFUNC); the
// memchr+memcmp twin on Windows. (The old `find_sequence` Result wrapper had
// no callers left and was removed.)
@[inline]
fn find_sequence_idx(buf &u8, len int, bytes_ptr &u8, bytes_len int) int {
	$if windows {
		return memmem_idx_portable(buf, len, bytes_ptr, bytes_len)
	} $else {
		p := unsafe { C.memmem(buf, len, bytes_ptr, bytes_len) }
		if p == unsafe { nil } {
			return -1
		}
		return int(unsafe { &u8(p) - buf })
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
pub fn parse_http1_request_line(mut req HttpRequest) !int {
	end := request_line_end(mut req)
	if end < 0 {
		return error(request_line_error(end))
	}
	return end
}

// Why request_line_end rejected a request line. Plain ints, not error()s: the
// hot path (decode_into) runs it on every request, and an error() boxes a
// MessageError even when the caller discards it — under -gc none, a leak per
// malformed request.
const rl_too_short = -1
const rl_no_space_after_method = -2
const rl_empty_method = -3
const rl_no_target = -4
const rl_no_space_after_target = -5
const rl_no_cr = -6
const rl_no_lf = -7

fn request_line_error(code int) string {
	return match code {
		rl_too_short { 'request line too short' }
		rl_no_space_after_method { 'Missing space after method' }
		rl_empty_method { 'empty method' }
		rl_no_target { 'missing request-target' }
		rl_no_space_after_target { 'Missing space after request-target' }
		rl_no_cr { 'Missing CR' }
		else { 'expected LF after CR' }
	}
}

// request_line_end parses the request line into `req` and returns the index
// just past its CRLF, or a negative rl_* code. The no-Result twin of
// parse_http1_request_line (see find_byte_idx).
@[direct_array_access]
fn request_line_end(mut req HttpRequest) int {
	buf := req.buffer
	len := buf.len
	if len < 12 {
		return rl_too_short
	}

	unsafe {
		b := &buf[0]

		// Find first SP: end of method
		method_len := find_byte_idx(b, len, empty_space)
		if method_len < 0 {
			return rl_no_space_after_method
		}
		if method_len == 0 {
			return rl_empty_method
		}
		req.method = Slice{0, method_len}
		// Skip spaces after method
		mut pos := method_len + 1
		for pos < len && buf[pos] == empty_space {
			pos++
		}
		if pos == len {
			return rl_no_target
		}

		// Find next SP or CR (whichever comes first)
		sp_pos := find_byte_idx(&buf[pos], len - pos, empty_space)
		if sp_pos < 0 {
			return rl_no_space_after_target
		}
		cr_pos := find_byte_idx(&buf[pos], len - pos, cr_char)
		if cr_pos < 0 {
			return rl_no_cr
		}

		path_end := if sp_pos < cr_pos { pos + sp_pos } else { pos + cr_pos }
		req.path = Slice{pos, path_end - pos}

		// If we hit CR directly after path → HTTP/0.9 style (no version)
		if sp_pos > cr_pos {
			if path_end + 1 >= len || buf[path_end + 1] != lf_char {
				return rl_no_lf
			}
			req.version = Slice{0, 0}
			return path_end + 2
		}

		// Otherwise: version follows the second SP
		version_start := path_end + 1
		cr_after_version := find_byte_idx(&buf[version_start], len - version_start, cr_char)
		if cr_after_version < 0 {
			return rl_no_cr
		}
		req.version = Slice{version_start, cr_after_version}

		end_of_line := version_start + cr_after_version
		if end_of_line + 1 >= len || buf[end_of_line + 1] != lf_char {
			return rl_no_lf
		}

		return end_of_line + 2 // position after \r\n
	}
}

// decode_into parses the request head INTO `req` and reports whether it is well
// formed. Returning a bool instead of `!HttpRequest` avoids boxing the big
// HttpRequest struct in a Result on every call — callgrind flagged that
// memset+copy as ~13% of the per-request parse cost. This is the hot-path entry
// point (worker / handler); decode_http_request is the Result-returning wrapper.
@[direct_array_access]
pub fn decode_into(mut req HttpRequest) bool {
	buffer := req.buffer // caller sets req.buffer (it is immutable after construction)

	// header_start is the byte index immediately after the request line's \r\n
	header_start := request_line_end(mut req)
	if header_start < 0 {
		return false
	}

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
		return true
	}

	header_len := find_sequence_idx(&buffer[header_start], buffer.len - header_start,
		&double_crlf[0], double_crlf.len)
	if header_len < 0 {
		return false
	}

	if header_len + header_start + double_crlf.len == buffer.len {
		// No body present
		req.header_fields = Slice{
			start: header_start
			len:   header_len
		}
		req.body = Slice{0, 0}
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
	}
	return true
}

// decode_http_request is the Result-returning wrapper around decode_into, kept for
// tests and ergonomic callers. The hot path should call decode_into directly to
// avoid the HttpRequest-in-Result boxing.
pub fn decode_http_request(buffer []u8) !HttpRequest {
	mut req := HttpRequest{
		buffer: buffer
	}
	if decode_into(mut req) {
		return req
	}
	return error('malformed request head')
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

// field_line_len returns the length of the field line at line_start whose LF is
// `lf` bytes in: the bytes before the LF, minus the CR of the CRLF. Every walker
// in this module splits lines on LF, and the framer answers 400 to a line whose
// LF is not preceded by CR (bare LF, RFC 9112 §2.2), so on the server path the
// CR is always there. Dropping it only when present keeps a buffer that never
// went through the framer (decode_http_request on raw bytes) on the same line
// boundaries: a value ends at its own LF and never runs into the next line.
@[direct_array_access; inline]
fn field_line_len(buf []u8, line_start int, lf int) int {
	if lf > 0 && buf[line_start + lf - 1] == cr_char {
		return lf - 1
	}
	return lf
}

// get_header_value_slice returns the value of `name` as a zero-copy Slice,
// without its leading and trailing OWS (see line_header_value); an empty value
// is a zero-length Slice, not none. Header field names are CASE-INSENSITIVE
// (RFC 9110 §5.1), so `Content-Type`, `content-type` and `CONTENT-TYPE` all match.
@[direct_array_access]
pub fn (req HttpRequest) get_header_value_slice(name string) ?Slice {
	if req.header_fields.len <= 0 {
		return none
	}
	section_end := req.header_fields.start + req.header_fields.len
	mut pos := req.header_fields.start

	for pos <= section_end - 2 {
		lf := find_byte_idx(&req.buffer[pos], section_end + 2 - pos, lf_char)
		if lf < 0 {
			return none
		}
		line_len := field_line_len(req.buffer, pos, lf)
		if line_len <= 0 {
			return none
		}
		if v := line_header_value(req.buffer, pos, line_len, name) {
			// len -1 is `name` followed by SP/HTAB before the colon: not a field
			// line for `name` (see line_header_value).
			if v.len >= 0 {
				return v
			}
		}
		pos += lf + 1
	}

	return none
}

// count_header counts header lines whose name case-insensitively equals `name`.
// Used by validate_http1 to enforce "exactly one Host" (RFC 9112 §3.2). Walks
// the same lines as get_header_value_slice and matches the same ones as
// line_header_value (name, then ':', inside the line), so the two agree.
@[direct_array_access]
pub fn (req HttpRequest) count_header(name string) int {
	if req.header_fields.len <= 0 {
		return 0
	}
	section_end := req.header_fields.start + req.header_fields.len
	mut pos := req.header_fields.start
	mut count := 0
	for pos <= section_end - 2 {
		lf := find_byte_idx(&req.buffer[pos], section_end + 2 - pos, lf_char)
		if lf < 0 {
			break
		}
		line_len := field_line_len(req.buffer, pos, lf)
		if line_len <= 0 {
			break
		}
		if name.len < line_len && ascii_ci_eq(&req.buffer[pos], name.str, name.len)
			&& req.buffer[pos + name.len] == colon_u8 {
			count++
		}
		pos += lf + 1
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
	if req.version.len == 8 && ascii_ci_eq(&req.buffer[req.version.start], c'HTTP/1.1', 8) {
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

	// Find '?' in path using memchr. find_byte_idx (no `!int` Result) instead of
	// find_byte: every not-found return from find_byte calls error(), which allocates a
	// MessageError — a per-request leak under `-gc none` (query parsing runs on every
	// request, several lookups each).
	q_pos := find_byte_idx(&req.buffer[path_start], path_len, question_mark_u8)
	if q_pos < 0 {
		return none // No query string
	}

	// Start of query string (after '?')
	mut pos := path_start + q_pos + 1
	path_end := path_start + path_len

	// Parse query string: key1=val1&key2=val2
	for pos < path_end {
		// Find '=' for this key
		eq_pos := find_byte_idx(&req.buffer[pos], path_end - pos, equal_u8)
		if eq_pos < 0 {
			break // No '=' found, malformed query
		}

		key_len := eq_pos

		// Check if key matches using memcmp
		if key_len == key.len && unsafe { C.memcmp(&req.buffer[pos], &key[0], key.len) } == 0 {
			// Found matching key, extract value
			value_start := pos + eq_pos + 1

			// Find '&' or end of path using memchr
			mut value_len := find_byte_idx(&req.buffer[value_start], path_end - value_start,
				amperstand_u8)
			if value_len < 0 {
				value_len = path_end - value_start // last parameter, no '&'
			}

			return Slice{
				start: value_start
				len:   value_len
			}
		}

		// Skip to next parameter (find '&')
		amp_pos := find_byte_idx(&req.buffer[pos], path_end - pos, amperstand_u8)
		if amp_pos < 0 {
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

// ---- request framing -------------------------------------------------------
//
// The read loop needs to know when a full message has arrived. That decision is
// a PURE function of the bytes received so far, kept here so it can be
// unit-tested by feeding growing prefixes (split-point fuzzing) — no sockets.

// frame_request_length inspects the bytes received so far and returns:
//   -1          -> incomplete; read more bytes
//   total >= 0  -> a complete message occupying exactly `total` bytes is present
// It errors only on genuinely malformed framing (map to 400). Body length comes
// from Content-Length, or from chunked decoding (Transfer-Encoding), or is zero.
pub fn frame_request_length(buf []u8) !int {
	return frame_request_length_lim(buf, 0, 0)
}

// Framing sentinels returned by frame_request_length_lim_idx (the no-Result
// twin). Distinct from -1 (incomplete) and any real length (>= 0); the Result
// wrapper maps each to its HTTP status code.
const frame_err_malformed = -400
const frame_err_body = -413 // body exceeds the configured max_body
const frame_err_header = -431 // header block exceeds the configured max_header

// frame_request_length_lim is frame_request_length with optional size limits
// (0 = unlimited, zero-cost). When a limit is exceeded it returns an error whose
// `.code()` is the HTTP status to send: 431 (header fields too large) or 413
// (payload too large). Other malformed framing carries code 400. Thin Result
// wrapper over the no-Result hot-path twin frame_request_length_lim_idx: cold
// callers (request decode, tests) keep this API, while the per-request drain
// loops call the twin directly to skip the !int boxing.
pub fn frame_request_length_lim(buf []u8, max_header int, max_body int) !int {
	r := frame_request_length_lim_idx(buf, max_header, max_body)
	if r == frame_err_body {
		return error_with_code('body exceeds ${max_body} bytes', 413)
	}
	if r == frame_err_header {
		return error_with_code('header fields exceed ${max_header} bytes', 431)
	}
	if r == frame_err_malformed {
		return error_with_code('malformed request framing', 400)
	}
	return r // >= 0 complete, or -1 incomplete
}

// frame_request_length_lim_idx is the no-Result hot-path twin of
// frame_request_length_lim: it returns a plain int and never constructs a Result,
// so the per-request success path skips the !int boxing (builtin___result_ok,
// which callgrind put at ~5-9% of the pipelined worker's instructions). Mirrors
// find_byte_idx vs find_byte. Returns a length >= 0 (complete — exactly that many
// bytes), -1 (incomplete — wait for more bytes), or a frame_err_* sentinel that
// the Result wrapper maps to 400 / 413 / 431.
@[direct_array_access]
pub fn frame_request_length_lim_idx(buf []u8, max_header int, max_body int) int {
	if buf.len < 4 {
		return -1
	}
	// End of the request line (first LF). Headers start right after it.
	rl := find_byte_idx(&buf[0], buf.len, lf_char)
	if rl < 0 {
		return -1
	}
	// Bare LF (RFC 9112 §2.2): a recipient MAY take a lone LF as a line break,
	// but only safely if every parser on the path agrees. The request-line parser
	// scans to the CR, and a lenient front end may keep the LF inside a value, so
	// a field line one of them hides inside a value (or the HTTP-version) would
	// be a separate field here. Answer 400 instead: every LF of the head must be
	// part of a CRLF. Checked as the walk finds each LF (one compare per line),
	// so no head with a bare LF ever reaches a handler.
	if rl == 0 || buf[rl - 1] != cr_char {
		return frame_err_malformed
	}
	mut pos := rl + 1

	// ONE pass over the header lines: locate the blank-line terminator AND
	// detect Content-Length / Transfer-Encoding as we go. (Two separate header
	// scans here measurably regressed the hot path — keep it to a single walk
	// with a cheap per-line reject.)
	mut content_length := -1
	mut chunked := false // chunked is the FINAL coding of the Transfer-Encoding list
	mut te_seen := false // any Transfer-Encoding line, whatever its codings
	for {
		// Cap the head size so a hostile peer can't grow it without bound.
		if max_header > 0 && pos > max_header {
			return frame_err_header
		}
		if pos >= buf.len {
			return -1
		}
		// Blank line => end of header section.
		if buf[pos] == cr_char {
			if pos + 1 >= buf.len {
				return -1
			}
			if buf[pos + 1] == lf_char {
				body_start := pos + 2
				// RFC 9112 §6.1: a message with BOTH Content-Length and
				// Transfer-Encoding is the classic request-smuggling ambiguity and
				// MUST be rejected. Do it here — the moment both are known — instead
				// of letting the chunked framer run: with a non-chunked body it would
				// return -1 (incomplete) forever and stall the connection until the
				// read timeout, never surfacing the 400 (issue #104).
				//
				// Any Transfer-Encoding decides the framing, not only chunked
				// (issue #184): with Content-Length it is the same ambiguity; when
				// chunked is not the final coding the length cannot be determined,
				// so the server MUST answer 400 and close (§6.3); and an HTTP/1.0
				// message carrying it MUST be treated as faulty framing (§6.1).
				// Framing `Transfer-Encoding: gzip` as bodyless parsed its body as
				// the next request. Cold: te_seen is false on the hot path.
				if te_seen && (!chunked || content_length >= 0 || request_line_is_http10(buf, rl)) {
					return frame_err_malformed
				}
				if chunked {
					// Cold path: the chunked framer still returns a Result; map it
					// to a sentinel (the one boxing here is off the GET hot path).
					return frame_chunked_total(buf, body_start, max_header, max_body) or {
						match err.code() {
							413 { frame_err_body }
							431 { frame_err_header }
							else { frame_err_malformed }
						}
					}
				}
				if content_length >= 0 {
					total := body_start + content_length
					return if buf.len >= total { total } else { -1 }
				}
				return body_start
			}
		}
		line_lf := find_byte_idx(&buf[pos], buf.len - pos, lf_char)
		if line_lf < 0 {
			return -1
		}
		// Bare LF, see the request line above. pos always follows an LF, so an
		// empty line (line_lf == 0) reads that LF here and is rejected too.
		if buf[pos + line_lf - 1] != cr_char {
			return frame_err_malformed
		}
		line_start := pos
		line_len := line_lf - 1 // bytes before the CR
		pos = line_start + line_lf + 1

		// Cheap checks: both reject at byte 0 for the vast majority of headers.
		if v := line_header_value(buf, line_start, line_len, 'Content-Length') {
			if v.len < 0 {
				return frame_err_malformed // whitespace before the colon
			}
			n := parse_content_length(buf, v) or { return frame_err_malformed }
			// Repeated Content-Length lines with differing values are invalid
			// framing: 400 + close (RFC 9112 §6.3). An identical repeat MAY be
			// accepted (RFC 9110 §8.6). Either way the length framed is the
			// FIRST one, the one content_length() reads (issue #184).
			if content_length >= 0 && n != content_length {
				return frame_err_malformed
			}
			content_length = n
			// Reject an over-large body from the declared length, BEFORE buffering it.
			if max_body > 0 && content_length > max_body {
				return frame_err_body
			}
		} else if v := line_header_value(buf, line_start, line_len, 'Transfer-Encoding') {
			if v.len < 0 {
				return frame_err_malformed // whitespace before the colon
			}
			te_seen = true
			r := te_fold(buf, v, chunked)
			if r < 0 {
				return frame_err_malformed
			}
			chunked = r == 1
		}
	}
	return -1
}

// te_fold folds one Transfer-Encoding field value into the framer's running
// coding list (repeated field lines form ONE comma-separated list, RFC 9110
// §5.3). It returns 1 when chunked is now the final coding, 0 when it is not,
// and -1 when a coding follows chunked: chunked not final, or applied twice,
// which RFC 9112 §6.1 forbids (§6.3: 400 + close). Codings are whole tokens,
// compared case-insensitively with the OWS around commas and empty list
// elements skipped. Never a substring test: `xchunked` is not chunked. A line
// that names no coding at all is -1 too: hops disagree on whether an empty
// Transfer-Encoding cancels the framing. Cold: runs only on such a line, and
// noinline keeps the list walk out of the framer's per-line loop (inlined, it
// measurably slowed the Content-Length path).
@[direct_array_access; noinline]
fn te_fold(buf []u8, v Slice, chunked bool) int {
	// The value nearly every chunked request carries: one compare, no list walk.
	if !chunked && v.len == 7 && ascii_ci_eq(&buf[v.start], c'chunked', 7) {
		return 1
	}
	mut last_chunked := chunked
	mut codings := 0
	end := v.start + v.len
	mut i := v.start
	for i < end {
		c := buf[i]
		if c == `,` || c == empty_space || c == htab_char {
			i++
			continue
		}
		start := i
		for i < end && buf[i] != `,` {
			i++
		}
		// Trim trailing OWS; buf[start] is neither OWS nor ',', so this stops there.
		mut stop := i
		for buf[stop - 1] == empty_space || buf[stop - 1] == htab_char {
			stop--
		}
		if last_chunked {
			return -1
		}
		last_chunked = stop - start == 7 && ascii_ci_eq(&buf[start], c'chunked', 7)
		codings++
	}
	if codings == 0 {
		return -1
	}
	return if last_chunked { 1 } else { 0 }
}

// request_line_is_http10 reports whether the request line whose LF is at `rl`
// ends in ` HTTP/1.0` (the version is case-sensitive, RFC 9112 §2.3). Cold:
// the framer asks only once it has seen a Transfer-Encoding line. The minor
// digit goes first, so an HTTP/1.1 chunked request pays one byte compare.
@[direct_array_access; noinline]
fn request_line_is_http10(buf []u8, rl int) bool {
	end := if rl > 0 && buf[rl - 1] == cr_char { rl - 1 } else { rl }
	return end >= 9 && buf[end - 1] == `0` && buf[end - 9] == empty_space
		&& unsafe { C.memcmp(&buf[end - 8], c'HTTP/1.0', 8) } == 0
}

// frame_expected_total returns the full HTTP/1.1 message length (headers + body)
// as soon as it is determinable from the bytes buffered so far: the header
// section must be complete AND the body length known via Content-Length. Returns
// -1 when not yet determinable — headers incomplete, a chunked body (length
// unknown until the terminator), or no Content-Length at all.
//
// This is a pure sizing HINT for the read loop: it lets a large upload grow its
// recv buffer to the exact message size in ONE allocation instead of doubling
// toward it (8K→16K→…→32M is ~12 reallocs + tens of MB of memcpy per request).
// The authoritative framing and limit checks stay in frame_request_length_lim,
// which the read loop still runs once the bytes have actually arrived.
@[direct_array_access]
pub fn frame_expected_total(buf []u8) int {
	if buf.len < 4 {
		return -1
	}
	// find_byte_idx (no Result), not find_byte: the not-found path of find_byte
	// allocates a MessageError, which this per-request framer hits on every
	// incomplete head (and leaks under -gc none). Mirrors frame_request_length_lim.
	rl := find_byte_idx(&buf[0], buf.len, lf_char)
	// A bare LF is the framer's 400 (see frame_request_length_lim_idx); never
	// size a streamed body from a head the framer refuses.
	if rl <= 0 || buf[rl - 1] != cr_char {
		return -1
	}
	mut pos := rl + 1
	mut content_length := -1
	for {
		if pos >= buf.len {
			return -1
		}
		// Blank line => end of header section.
		if buf[pos] == cr_char {
			if pos + 1 >= buf.len {
				return -1
			}
			if buf[pos + 1] == lf_char {
				body_start := pos + 2
				if content_length >= 0 {
					return body_start + content_length
				}
				return -1 // chunked or bodyless — nothing to pre-size against
			}
		}
		line_lf := find_byte_idx(&buf[pos], buf.len - pos, lf_char)
		if line_lf < 0 || buf[pos + line_lf - 1] != cr_char {
			return -1
		}
		line_start := pos
		line_len := line_lf - 1 // bytes before the CR
		pos = line_start + line_lf + 1
		if v := line_header_value(buf, line_start, line_len, 'Content-Length') {
			content_length = parse_content_length(buf, v) or { return -1 }
		}
	}
	return -1
}

// frame_head_len returns the byte offset where the body begins — the length of
// the request head (request line + header section + the terminating CRLFCRLF) —
// or -1 if the head is not yet complete in `buf`. Used by the engine to stream
// (drain) a large body instead of buffering it: head stays, body is discarded.
@[direct_array_access]
pub fn frame_head_len(buf []u8) int {
	if buf.len < 4 {
		return -1
	}
	// find_byte_idx (no Result): see frame_expected_total — avoids the per-call
	// MessageError allocation on the incomplete-head path.
	rl := find_byte_idx(&buf[0], buf.len, lf_char)
	if rl < 0 {
		return -1
	}
	mut pos := rl + 1
	for {
		if pos >= buf.len {
			return -1
		}
		if buf[pos] == cr_char {
			if pos + 1 >= buf.len {
				return -1
			}
			if buf[pos + 1] == lf_char {
				return pos + 2 // past the blank line's CRLF => body start
			}
		}
		line_lf := find_byte_idx(&buf[pos], buf.len - pos, lf_char)
		if line_lf < 0 {
			return -1
		}
		pos = pos + line_lf + 1
	}
	return -1
}

// head_expects_100_continue reports whether the request head buffered in
// `buf[..head_len]` carries `Expect: 100-continue` (RFC 9110 §10.1.1). Scans the
// header lines for an `Expect` field whose value contains `100-continue`
// (case-insensitive). Off the hot path: the backend calls this ONCE per
// connection, and only while a body is still pending (a rare shape), so the walk
// never touches the GET/no-body or fully-buffered request path.
@[direct_array_access]
pub fn head_expects_100_continue(buf []u8, head_len int) bool {
	if head_len <= 0 || head_len > buf.len {
		return false
	}
	// Skip the request line (first LF); Expect can only be a header field.
	rl := find_byte_idx(&buf[0], head_len, lf_char)
	if rl < 0 {
		return false
	}
	mut pos := rl + 1
	for pos < head_len {
		if buf[pos] == cr_char {
			break // blank line => end of headers
		}
		line_lf := find_byte_idx(&buf[pos], head_len - pos, lf_char)
		if line_lf < 0 {
			break
		}
		line_start := pos
		line_len := line_lf - 1 // bytes before the CR
		pos = line_start + line_lf + 1
		if v := line_header_value(buf, line_start, line_len, 'Expect') {
			if ci_contains(buf, v, '100-continue') {
				return true
			}
		}
	}
	return false
}

// content_length returns the request's Content-Length header value, or -1 if it
// is absent or unparseable. Lets a handler answer by declared length even when
// the engine drained (never buffered) the body. It reads the FIRST field line;
// the framer refuses differing repeats (400), so on a request the server framed
// this is the length the body was framed by.
pub fn (req HttpRequest) content_length() int {
	s := req.get_header_value_slice('Content-Length') or { return -1 }
	return parse_content_length(req.buffer, s) or { -1 }
}

// line_header_value returns the value Slice if a header line (line_len bytes
// before CRLF, starting at line_start) has the case-insensitive name `name`
// immediately followed by ':'. The one field-value view: the framer and
// get_header_value_slice both read values through it.
//
// The value excludes the OWS (SP / HTAB, RFC 9110 §5.6.3) before its first and
// after its last non-whitespace byte (RFC 9112 §5.1), and it is bounded by the
// line: it can never reach past line_len into the next field line.
// A Slice with len -1 means `name` is followed by SP/HTAB: malformed, and
// refused by every consumer (parse_content_length errors, te_fold finds no
// coding, ci_contains no match, get_header_value_slice skips the line).
@[direct_array_access; inline]
fn line_header_value(buf []u8, line_start int, line_len int, name string) ?Slice {
	if name.len + 1 > line_len {
		return none
	}
	if !ascii_ci_eq(&buf[line_start], name.str, name.len) {
		return none
	}
	if buf[line_start + name.len] != colon_u8 {
		// `Content-Length : 5` / `Transfer-Encoding\t: chunked`: RFC 9112 §5.1
		// says a server MUST reject whitespace before the colon with 400, since
		// one hop reads the field and another ignores it. Treating the line as
		// absent framed the body as the next request (issue #184), so report it
		// (len -1) for the framer to refuse. Only reached once the name matched.
		after := buf[line_start + name.len]
		if after == empty_space || after == htab_char {
			return Slice{line_start, -1}
		}
		return none
	}
	mut v := line_start + name.len + 1
	mut end := line_start + line_len
	for v < end && (buf[v] == empty_space || buf[v] == htab_char) {
		v++
	}
	for end > v && (buf[end - 1] == empty_space || buf[end - 1] == htab_char) {
		end--
	}
	return Slice{
		start: v
		len:   end - v
	}
}

// max_declared bounds a declared length (Content-Length or a chunk-size). A body
// larger than this is refused outright — no legitimate request needs it, and it
// keeps the value well inside a 32-bit `int` so the accumulator below can never
// overflow into a negative/wrapped value (which previously produced a wrong
// content_length, and for chunk-sizes an out-of-bounds index / smuggling desync).
// ~1 GiB: comfortably above any real upload, far below int overflow.
const max_declared = 1 << 30

fn parse_content_length(buf []u8, s Slice) !int {
	if s.len <= 0 {
		return error('empty Content-Length') // or a malformed line: line_header_value
	}
	// Accumulate in i64 so the arithmetic can't wrap a 32-bit int; reject over the
	// cap. A 32-bit accumulator let a Content-Length of 2147483648 wrap to < 0, so
	// a textually-present header framed as if absent. Checking i64 > cap each step
	// also bounds a long digit run before it can grow without limit.
	mut n := i64(0)
	for i in s.start .. s.start + s.len {
		c := buf[i]
		if c < `0` || c > `9` {
			return error('non-digit in Content-Length')
		}
		n = n * 10 + i64(c - `0`)
		if n > max_declared {
			return error('Content-Length exceeds ${max_declared} bytes')
		}
	}
	return int(n)
}

// ci_contains reports whether the value slice contains `needle` (ASCII, CI).
fn ci_contains(buf []u8, val Slice, needle string) bool {
	if needle.len > val.len {
		return false
	}
	last := val.start + val.len - needle.len
	for i := val.start; i <= last; i++ {
		if ascii_ci_eq(&buf[i], needle.str, needle.len) {
			return true
		}
	}
	return false
}

// hex_digit returns the value of hex digit c, or -1 when c is not one. A plain
// int, not !int: the chunk-size loop ends on the first non-digit, and an
// error() there would box a MessageError on every chunk line.
@[inline]
fn hex_digit(c u8) int {
	return match c {
		`0`...`9` { int(c - `0`) }
		`a`...`f` { int(c - `a` + 10) }
		`A`...`F` { int(c - `A` + 10) }
		else { -1 }
	}
}

// tchar bitmaps (RFC 9110 §5.6.2: DIGIT, ALPHA and !#$%&'*+-.^_`|~) for bytes
// 0-63 and 64-127: a shift and a mask per byte instead of a 20-arm compare.
const chunk_tchar_lo = u64(0x03ff6cfa00000000)
const chunk_tchar_hi = u64(0x57ffffffc7fffffe)

// chunk_tchar reports whether c is a tchar (a token byte).
@[inline]
fn chunk_tchar(c u8) bool {
	if c < 64 {
		return (chunk_tchar_lo >> c) & 1 != 0
	}
	return c < 128 && (chunk_tchar_hi >> (c - 64)) & 1 != 0
}

// chunk_skip_bws skips BWS (SP / HTAB) in buf[i..end] and returns the next index.
@[direct_array_access; inline]
fn chunk_skip_bws(buf []u8, i int, end int) int {
	mut k := i
	for k < end && (buf[k] == empty_space || buf[k] == htab_char) {
		k++
	}
	return k
}

// chunk_ext_ok reports whether buf[start..end] (from just after the chunk-size
// up to the line's CR) is a well-formed chunk-ext (RFC 9112 §7.1.1):
//
//   chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )
//   chunk-ext-name = token, chunk-ext-val = token / quoted-string
//
// Extension semantics are ignored, but the syntax is checked: "skip to the end
// of the line" is where hops disagree about the line end (a bare CR or LF, junk
// after the size), the desync class #109 fixed for the chunk-data CRLF (#185).
@[direct_array_access]
fn chunk_ext_ok(buf []u8, start int, end int) bool {
	mut i := start
	for i < end {
		i = chunk_skip_bws(buf, i, end)
		if i >= end || buf[i] != `;` {
			return false
		}
		i = chunk_skip_bws(buf, i + 1, end)
		name := i
		for i < end && chunk_tchar(buf[i]) {
			i++
		}
		if i == name {
			return false // `;` with no extension name
		}
		eq := chunk_skip_bws(buf, i, end)
		if eq >= end || buf[eq] != `=` {
			continue // no value; any BWS left must lead to the next `;`
		}
		i = chunk_skip_bws(buf, eq + 1, end)
		if i < end && buf[i] == `"` {
			// quoted-string: qdtext / quoted-pair, neither of which admits a
			// control byte other than HTAB.
			i++
			for {
				if i >= end {
					return false // unterminated quoted-string
				}
				mut c := buf[i]
				if c == `"` {
					i++
					break
				}
				if c == 0x5c { // backslash: quoted-pair
					i++
					if i >= end {
						return false
					}
					c = buf[i]
				}
				if (c < 0x20 && c != htab_char) || c == 0x7f {
					return false
				}
				i++
			}
		} else {
			val := i
			for i < end && chunk_tchar(buf[i]) {
				i++
			}
			if i == val {
				return false // `=` with no value
			}
		}
	}
	return true
}

// trailer_line_ok reports whether buf[start..end] (a trailer line without its
// CRLF) is a field-line (RFC 9112 §5): a token field-name, `:`, then a value
// with no control byte but HTAB. Trailer fields are discarded, but the framer
// reads past them, so it only frames past a line every strict hop also reads
// as a field: never a bare CR (RFC 9112 §2.2), obs-fold or a request line.
@[direct_array_access]
fn trailer_line_ok(buf []u8, start int, end int) bool {
	mut i := start
	for i < end && chunk_tchar(buf[i]) {
		i++
	}
	if i == start || i >= end || buf[i] != colon_u8 {
		return false
	}
	i++
	for i < end {
		c := buf[i]
		if (c < 0x20 && c != htab_char) || c == 0x7f {
			return false
		}
		i++
	}
	return true
}

// frame_trailer_section frames the trailer section after the last chunk, from
// `start` (RFC 9112 §7.1.2): `*( field-line CRLF ) CRLF`. Trailer fields are
// not exposed to handlers (a recipient MAY discard them), but their bytes are
// part of the message, so the framer reads past them (§7.1.3). It returns the
// offset just past the closing empty line, -1 until that line has arrived, or
// an error: 400 for a malformed line, 431 once the section outgrows max_header
// (the bound the header section has). The old framer wanted the closing CRLF
// right after the last chunk and returned -1 forever on a trailer (#185).
@[direct_array_access]
fn frame_trailer_section(buf []u8, start int, max_header int) !int {
	mut pos := start
	for {
		if max_header > 0 && pos - start > max_header {
			return error_with_code('trailer section too large', 431)
		}
		if pos >= buf.len {
			return -1
		}
		// The empty line ends the body: checked in place, so the common case (no
		// trailer at all) costs two byte compares, not a memchr.
		if buf[pos] == cr_char {
			if pos + 1 >= buf.len {
				return -1
			}
			if buf[pos + 1] == lf_char {
				return pos + 2
			}
		}
		line_lf := find_byte_idx(&buf[pos], buf.len - pos, lf_char)
		if line_lf < 0 {
			// Unterminated line: every byte buffered past `start` is trailer.
			if max_header > 0 && buf.len - start > max_header {
				return error_with_code('trailer section too large', 431)
			}
			return -1
		}
		line_end := pos + line_lf - 1 // index of the CR before the LF
		if line_lf == 0 || buf[line_end] != cr_char {
			return error_with_code('trailer line not terminated by CRLF', 400)
		}
		if !trailer_line_ok(buf, pos, line_end) {
			return error_with_code('malformed trailer field', 400)
		}
		pos = line_end + 2
	}
	return -1
}

// frame_chunked_total frames a chunked body from body_start (RFC 9112 §7.1):
//
//   chunked-body = *chunk last-chunk trailer-section CRLF
//   chunk        = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
//   last-chunk   = 1*("0") [ chunk-ext ] CRLF
//
// It returns the total message length once the empty line closing the trailer
// section is buffered, -1 if more bytes are needed, or an error whose code is
// the status to send: 400 malformed, 413 body over max_body, 431 trailer
// section over max_header. Every line must end in CRLF: a bare LF, or a bare
// CR anywhere in a chunk-size or trailer line, is a 400, never a line end.
@[direct_array_access]
fn frame_chunked_total(buf []u8, body_start int, max_header int, max_body int) !int {
	// Bound the buffered chunked payload (the total length isn't known up front).
	if max_body > 0 && buf.len - body_start > max_body {
		return error_with_code('body exceeds ${max_body} bytes', 413)
	}
	mut pos := body_start
	for {
		// chunk-size = 1*HEXDIG.
		// Accumulate the chunk-size in i64 so the arithmetic itself can never wrap a
		// 32-bit int, then reject anything over max_declared. A 32-bit accumulator
		// let 0x80000000 wrap NEGATIVE (crlf_at went out of bounds → segfault under
		// @[direct_array_access]) and 0x100000000 wrap to EXACTLY 0 (hijacking the
		// size==0 terminating-chunk branch → smuggling desync). Checking i64 > cap
		// after each digit catches both before size is ever used as an index.
		mut size64 := i64(0)
		mut j := pos
		for j < buf.len {
			d := hex_digit(buf[j])
			if d < 0 {
				break
			}
			size64 = size64 * 16 + d
			if size64 > max_declared {
				return error_with_code('chunk size exceeds ${max_declared} bytes', 400)
			}
			j++
		}
		if j >= buf.len {
			return -1 // the size line has not fully arrived
		}
		// At least one digit: an empty or extension-only (`;ext`) size line is
		// not a last chunk (#185).
		if j == pos {
			return error_with_code('invalid chunk size', 400)
		}
		// The size line ends in CRLF, right after the digits or after a
		// well-formed chunk-ext. A bare LF, a bare CR or junk is never a line end
		// (`5\n`, `5\rZZ\n`, `5;a\rb\r\n`) (#185). Only an extension needs the
		// memchr for its LF; a plain size line is checked in place.
		mut line_end := j // index of the line's CR
		if buf[j] != cr_char {
			if buf[j] != `;` && buf[j] != empty_space && buf[j] != htab_char {
				return error_with_code('invalid chunk size', 400)
			}
			line_lf := find_byte_idx(&buf[j], buf.len - j, lf_char)
			if line_lf < 0 {
				return -1
			}
			line_end = j + line_lf - 1
			if buf[line_end] != cr_char || !chunk_ext_ok(buf, j, line_end) {
				return error_with_code('invalid chunk-size line', 400)
			}
		}
		if line_end + 1 >= buf.len {
			return -1
		}
		if buf[line_end + 1] != lf_char {
			return error_with_code('chunk-size line not terminated by CRLF', 400)
		}
		data_start := line_end + 2
		if size64 == 0 {
			// last-chunk: frame past the trailer section to the closing CRLF.
			return frame_trailer_section(buf, data_start, max_header)
		}
		size := int(size64)
		// chunk-data is followed by a REQUIRED CRLF (RFC 9112 §7.1). Verify those
		// two bytes really are CR LF instead of assuming them — a body like
		// `5\r\nhello0\r\n\r\n` (data runs straight into the next chunk-size, no
		// terminator) would otherwise frame to a bogus length and desync the
		// connection, serving the malformed request as if valid (issue #109).
		crlf_at := data_start + size
		if crlf_at + 1 >= buf.len {
			return -1 // terminator not buffered yet
		}
		if buf[crlf_at] != cr_char || buf[crlf_at + 1] != lf_char {
			return error_with_code('chunk-data not terminated by CRLF', 400)
		}
		next := crlf_at + 2 // data + trailing CRLF
		pos = next
	}
	return -1
}
