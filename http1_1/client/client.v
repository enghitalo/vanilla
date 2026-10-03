module client

// HTTP/1.1 CLIENT codec — the mirror image of request_parser/ + response/
// (issue #122 Client story): a request SERIALIZER and a response PARSER,
// pure bytes-in/bytes-out. No sockets, no event loop, no allocation — the
// same discipline as the server-side codecs. Composition happens in the
// caller: transport.dial_* → send → event_loop.watch_fd + .suspend → recv →
// Framer.feed (framer.v; see examples/mesh), or frame_response for a response
// that is buffered whole. Per the #122 client study, callers
// POOL connections per worker (make_state — a dial costs ~4× a request) and
// prefer unix_socket_path transports (2.3–2.7× TCP loopback).
import strconv

// no_body is the empty-body argument for write_request, allocated once.
pub const no_body = []u8{}

// frame_response return codes (mirrors request_parser's negative-int
// convention: -1 incomplete, other negatives are hard errors).
pub const incomplete = -1
// status line unparseable / conflicting or invalid framing headers /
// malformed chunked encoding
pub const err_malformed = -2
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
// line (i.e. the body offset), `incomplete` (-1) while the head is still
// incomplete, or err_malformed for a bare LF. It walks the head LF to LF
// under the same rules as frame_response (every LF closes a CRLF), so the
// two always agree on where the head ends, including for a HEAD exchange
// framed with head_len alone.
@[direct_array_access]
pub fn head_len(buf []u8) int {
	mut pos := 0
	for {
		lf := lf_idx(buf, pos)
		if lf < 0 {
			return incomplete
		}
		if lf == 0 || buf[lf - 1] != `\r` {
			return err_malformed
		}
		if lf - 1 == pos && pos > 0 {
			return lf + 1 // the blank line
		}
		pos = lf + 1
	}
	return incomplete
}

// status_code parses the status line ('HTTP/1.x NNN ...') and returns the
// 3-digit code, or -1 if the line is not a valid HTTP/1 status line.
@[inline]
pub fn status_code(buf []u8) int {
	return status_at(buf, 0)
}

// status_at is status_code for the status line that starts at buf[p].
@[direct_array_access; inline]
fn status_at(buf []u8, p int) int {
	// 'HTTP/1.x ' is 9 bytes; the code is 3 more.
	if buf.len - p < 12 {
		return -1
	}
	if buf[p] != `H` || buf[p + 1] != `T` || buf[p + 2] != `T` || buf[p + 3] != `P`
		|| buf[p + 4] != `/` || buf[p + 5] != `1` || buf[p + 6] != `.` || buf[p + 7] < `0`
		|| buf[p + 7] > `9` || buf[p + 8] != ` ` {
		return -1
	}
	d0, d1, d2 := buf[p + 9], buf[p + 10], buf[p + 11]
	if d0 < `1` || d0 > `9` || d1 < `0` || d1 > `9` || d2 < `0` || d2 > `9` {
		return -1
	}
	// status-code is exactly 3 digits, then SP (or the line's CR when an
	// upstream omits the empty reason-phrase).
	if buf.len - p > 12 && buf[p + 12] != ` ` && buf[p + 12] != `\r` {
		return -1
	}
	return int(d0 - `0`) * 100 + int(d1 - `0`) * 10 + int(d2 - `0`)
}

fn C.memchr(buf &u8, char int, len usize) &u8

// lf_idx returns the index of the first LF at/after `from`, or -1. memchr
// (vectorized in glibc), so the head walk hops line to line instead of
// testing every byte.
@[inline]
fn lf_idx(buf []u8, from int) int {
	if from >= buf.len {
		return -1
	}
	base := unsafe { &u8(buf.data) + from }
	p := unsafe { C.memchr(base, int(`\n`), usize(buf.len - from)) }
	if p == unsafe { nil } {
		return -1
	}
	return from + int(unsafe { p - base })
}

// field_value returns (start, len) of the value of the field line
// buf[line_start..line_end) (line_end: the index of its CR) when the line's
// name is `name` (given lowercase; ASCII case-insensitive match) immediately
// followed by ':', else (-1, 0). The one field-value view: frame_response and
// header_value both read values through it, so the framer and the caller
// always see the same value. It excludes the OWS (SP / HTAB, RFC 9110 §5.6.3)
// before its first and after its last non-whitespace byte (RFC 9112 §5.1), and
// it is bounded by the line: it never reaches into the next field line.
@[direct_array_access]
fn field_value(buf []u8, line_start int, line_end int, name string) (int, int) {
	if line_end - line_start <= name.len {
		return -1, 0
	}
	for j in 0 .. name.len {
		mut c := buf[line_start + j]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != name[j] {
			return -1, 0
		}
	}
	if buf[line_start + name.len] != `:` {
		return -1, 0
	}
	mut v := line_start + name.len + 1
	mut e := line_end
	for v < e && (buf[v] == ` ` || buf[v] == `\t`) {
		v++
	}
	for e > v && (buf[e - 1] == ` ` || buf[e - 1] == `\t`) {
		e--
	}
	return v, e - v
}

// frame_response returns the TOTAL byte length (head + body, chunk framing
// included) of the first complete response buffered in `buf`, or a negative
// code: `incomplete` while more bytes are needed, `err_malformed` /
// `err_until_close` for responses that cannot be framed. Both framings are
// handled: Content-Length and Transfer-Encoding: chunked (the trailer section
// after the last chunk is framed past; its fields are discarded). Keep-alive
// pipelining works the same way as on the server: consume `total` bytes,
// compact, frame again.
//
// Every line of the head must end in CRLF. RFC 9112 §2.2 lets a recipient
// take a bare LF as a line break, but a hop that does splits the head
// differently, so a bare LF on the status line, a field line or the blank line
// is err_malformed as soon as it is buffered: the server framer's policy (#186).
@[direct_array_access]
pub fn frame_response(buf []u8) int {
	// ONE pass over the head, LF to LF: find the blank line that ends it and
	// read Content-Length / Transfer-Encoding on the way.
	mut lf := lf_idx(buf, 0)
	if lf < 0 {
		return incomplete
	}
	if lf == 0 || buf[lf - 1] != `\r` {
		return err_malformed
	}
	st := status_code(buf)
	if st < 100 {
		return err_malformed
	}
	// Bodyless by status (RFC 9110): 1xx interim, 204, 304. (A HEAD response
	// is also bodyless, but only the caller knows the request method — frame
	// HEAD exchanges with head_len directly.) Their field lines are still
	// walked, for the bare-LF check.
	bodyless := st < 200 || st == 204 || st == 304
	mut content_length := i64(-1)
	mut chunked := false
	mut pos := lf + 1
	for {
		lf = lf_idx(buf, pos)
		if lf < 0 {
			return incomplete
		}
		// pos follows an LF, so a bare-LF blank line reads that LF here and is
		// rejected too.
		if buf[lf - 1] != `\r` {
			return err_malformed
		}
		line_end := lf - 1 // the CR
		if line_end == pos {
			break // the blank line: the head is lf + 1 bytes
		}
		if !bodyless {
			v, vlen := field_value(buf, pos, line_end, 'content-length')
			if v >= 0 {
				n := parse_content_length(buf, v, vlen)
				if n < 0 {
					return err_malformed
				}
				if content_length >= 0 && content_length != n {
					return err_malformed // conflicting duplicates
				}
				content_length = n
			} else {
				te, te_len := field_value(buf, pos, line_end, 'transfer-encoding')
				if te >= 0 {
					// The only coding the codec decodes is a lone/final
					// chunked (RFC 9112 §6.1); anything else cannot be framed.
					if !value_has_chunked(buf, te, te + te_len) {
						return err_malformed
					}
					chunked = true
				}
			}
		}
		pos = lf + 1
	}
	hl := lf + 1
	if bodyless {
		return hl
	}
	if chunked {
		// TE wins over any (smuggling-suspect) Content-Length — same
		// precedence the server enforces (RFC 9112 §6.3).
		return frame_chunked_body(buf, hl)
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

// parse_content_length reads the Content-Length value buf[v..v + vlen) (OWS
// already trimmed, #186): 1*DIGIT, capped at 0x7fff0000. -1 when it is not one.
@[direct_array_access; inline]
fn parse_content_length(buf []u8, v int, vlen int) i64 {
	if vlen == 0 {
		return -1
	}
	mut n := i64(0)
	for d in v .. v + vlen {
		if buf[d] < `0` || buf[d] > `9` {
			return -1 // non-numeric value
		}
		n = n * 10 + i64(buf[d] - `0`)
		if n > 0x7fff_0000 {
			return -1
		}
	}
	return n
}

// value_has_chunked reports whether the final transfer coding of the
// Transfer-Encoding value buf[v..end) (the trimmed view) is `chunked` (ASCII
// case-insensitive): the value is `chunked` or ends in `, chunked` (OWS
// allowed around the comma). A response whose final coding is not chunked is
// delimited by connection close (RFC 9112 §6.3), so `chunked, gzip` or
// `xchunked` must not be framed as chunk frames. A bare CR anywhere in the
// value makes it invalid (RFC 9112 §2.2).
@[direct_array_access]
fn value_has_chunked(buf []u8, v int, end int) bool {
	needle := 'chunked'
	if end - v < needle.len {
		return false
	}
	for i in v .. end {
		if buf[i] == `\r` {
			return false
		}
	}
	s := end - needle.len
	for j in 0 .. needle.len {
		mut c := buf[s + j]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != needle[j] {
			return false
		}
	}
	mut k := s
	for k > v && (buf[k - 1] == ` ` || buf[k - 1] == `\t`) {
		k--
	}
	return k == v || buf[k - 1] == `,`
}

@[inline]
fn hex_digit(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

// tchar bitmaps (RFC 9110 §5.6.2: DIGIT, ALPHA and !#$%&'*+-.^_`|~) for bytes
// 0-63 and 64-127: a shift and a mask per byte instead of a 20-arm compare.
// Same tables as the server's chunked framer.
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
	for k < end && (buf[k] == ` ` || buf[k] == `\t`) {
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
// after the size). The server's chunked framer applies the same grammar (#185).
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
				if c == `\\` { // quoted-pair
					i++
					if i >= end {
						return false
					}
					c = buf[i]
				}
				if (c < 0x20 && c != `\t`) || c == 0x7f {
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
// as a field: never a bare CR (RFC 9112 §2.2), obs-fold or a status line that
// would swallow the next pipelined response.
@[direct_array_access]
fn trailer_line_ok(buf []u8, start int, end int) bool {
	mut i := start
	for i < end && chunk_tchar(buf[i]) {
		i++
	}
	if i == start || i >= end || buf[i] != `:` {
		return false
	}
	i++
	for i < end {
		c := buf[i]
		if (c < 0x20 && c != `\t`) || c == 0x7f {
			return false
		}
		i++
	}
	return true
}

// trailer_line frames one line of the trailer section (RFC 9112 §7.1.2) at
// `pos`: the offset just past it, `incomplete` until it has arrived, or
// err_malformed for a line that does not end in CRLF or is not a field-line.
// The bool is true for the empty line that ends the message.
@[direct_array_access; inline]
fn trailer_line(buf []u8, pos int) (int, bool) {
	if pos >= buf.len {
		return incomplete, false
	}
	// The empty line ends the body: checked in place, so the common case
	// (no trailer at all) costs two byte compares, not a memchr.
	if buf[pos] == `\r` {
		if pos + 1 >= buf.len {
			return incomplete, false
		}
		if buf[pos + 1] == `\n` {
			return pos + 2, true
		}
	}
	lf := lf_idx(buf, pos)
	if lf < 0 {
		return incomplete, false
	}
	line_end := lf - 1 // the CR before the LF
	if lf == pos || buf[line_end] != `\r` {
		return err_malformed, false // bare LF
	}
	if !trailer_line_ok(buf, pos, line_end) {
		return err_malformed, false
	}
	return lf + 1, false
}

// frame_trailer_section frames the trailer section after the last chunk, from
// `start` (RFC 9112 §7.1.2): `*( field-line CRLF ) CRLF`. It returns the
// offset just past the closing empty line (the message total), `incomplete`
// until that line has arrived, or err_malformed (see trailer_line).
fn frame_trailer_section(buf []u8, start int) int {
	mut pos := start
	for {
		next, last := trailer_line(buf, pos)
		if next < 0 || last {
			return next
		}
		pos = next
	}
	return incomplete
}

// chunk_size_line frames the chunk-size line at `pos` (RFC 9112 §7.1):
// `chunk-size [ chunk-ext ] CRLF`. It returns the offset of the chunk data
// (just past the line's CRLF) and the chunk size, or (`incomplete` /
// err_malformed, 0). chunk-size = 1*HEXDIG, at most 16 digits (leading zeros
// included), checked per digit so the verdict never depends on how the line
// was segmented. The accumulator is i64 with a hard cap so a hostile size can
// neither wrap negative nor hijack the zero-chunk branch (the request_parser
// #109 lessons, applied here too).
@[direct_array_access; inline]
fn chunk_size_line(buf []u8, pos int) (int, i64) {
	mut size := i64(0)
	mut j := pos
	for j < buf.len {
		d := hex_digit(buf[j])
		if d < 0 {
			break
		}
		size = size * 16 + i64(d)
		if size > 0x7fff_0000 || j - pos >= 16 {
			return err_malformed, 0
		}
		j++
	}
	if j >= buf.len {
		return incomplete, 0 // the size line has not fully arrived
	}
	// At least one digit: an empty or extension-only (`;ext`) size line is
	// not a last chunk.
	if j == pos {
		return err_malformed, 0
	}
	// The size line ends in CRLF, right after the digits or after a
	// well-formed chunk-ext. A bare LF, a bare CR or junk is never a line
	// end (`5\n`, `5\rZZ\n`, `5;a\nX`). Only an extension needs the memchr
	// for its LF; a plain size line is checked in place.
	mut line_end := j // the line's CR
	if buf[j] != `\r` {
		if buf[j] != `;` && buf[j] != ` ` && buf[j] != `\t` {
			return err_malformed, 0
		}
		lf := lf_idx(buf, j)
		if lf < 0 {
			return incomplete, 0
		}
		line_end = lf - 1
		if buf[line_end] != `\r` || !chunk_ext_ok(buf, j, line_end) {
			return err_malformed, 0
		}
	}
	if line_end + 1 >= buf.len {
		return incomplete, 0
	}
	if buf[line_end + 1] != `\n` {
		return err_malformed, 0
	}
	return line_end + 2, size
}

// frame_chunked_body frames a chunked body from `body_start` (RFC 9112 §7.1):
//
//   chunked-body = *chunk last-chunk trailer-section CRLF
//   chunk        = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
//   last-chunk   = 1*("0") [ chunk-ext ] CRLF
//
// It returns the total message length once the empty line closing the
// trailer section is buffered, `incomplete` while more bytes are needed, or
// err_malformed. Every line must end in CRLF: a bare LF, or a bare CR anywhere
// in a chunk-size or trailer line, is err_malformed, never a line end — the
// rules the server's chunked framer applies (#185).
@[direct_array_access]
fn frame_chunked_body(buf []u8, body_start int) int {
	mut pos := body_start
	for {
		data_start, size := chunk_size_line(buf, pos)
		if data_start < 0 {
			return data_start
		}
		if size == 0 {
			// last-chunk: frame past the trailer section to the closing CRLF.
			return frame_trailer_section(buf, data_start)
		}
		// chunk-data + REQUIRED CRLF (RFC 9112 §7.1) — verified, not assumed.
		crlf_at := i64(data_start) + size
		if crlf_at + 1 >= i64(buf.len) {
			return incomplete
		}
		if buf[int(crlf_at)] != `\r` || buf[int(crlf_at) + 1] != `\n` {
			return err_malformed
		}
		pos = int(crlf_at) + 2
	}
	return incomplete
}

// body_bounds returns (start, len) of the RAW body region inside a response
// already framed to `total` bytes (both 0 when there is no body). For a
// chunked response the region still carries the chunk framing — use
// append_body for the decoded bytes.
pub fn body_bounds(buf []u8, total int) (int, int) {
	hl := head_len(buf)
	if hl < 0 || total <= hl {
		return 0, 0
	}
	return hl, total - hl
}

// is_chunked reports whether the (complete-headed) response declares
// Transfer-Encoding — i.e. whether the body region is chunk-framed.
@[direct_array_access]
pub fn is_chunked(buf []u8) bool {
	hl := head_len(buf)
	if hl < 0 {
		return false
	}
	s, _ := header_value_from(buf, hl, 'transfer-encoding')
	return s >= 0
}

// header_value returns (start, len) of the first `name` header's value in
// the response head, or (-1, 0) when absent. `name` must be lowercase; the
// match is ASCII case-insensitive. The bounds are a zero-copy view into buf,
// without the value's leading and trailing OWS; an empty value is (start, 0).
pub fn header_value(buf []u8, name string) (int, int) {
	hl := head_len(buf)
	if hl < 0 {
		return -1, 0
	}
	return header_value_from(buf, hl, name)
}

// header_value_from is header_value with the head walk already paid — every
// path that has `hl` in hand goes through here so the head is scanned once.
// `hl` comes from head_len, which only returns a length when every line of the
// head ends in CRLF, so each value ends at its own line's CR and never runs
// into the next field line (#186).
@[inline]
fn header_value_from(buf []u8, hl int, name string) (int, int) {
	return header_value_in(buf, 0, hl, name)
}

// header_value_in is header_value_from for the head buf[start..end): a framed
// head (every line ends in CRLF) that need not start at offset 0.
@[direct_array_access]
fn header_value_in(buf []u8, start int, end int, name string) (int, int) {
	mut pos := lf_idx(buf, start) + 1 // past the status line
	for pos > 0 && pos < end - 2 {
		lf := lf_idx(buf, pos)
		s, l := field_value(buf, pos, lf - 1, name)
		if s >= 0 {
			return s, l
		}
		pos = lf + 1
	}
	return -1, 0
}

// append_body appends the DECODED body of a framed response into `out`: the
// raw bytes for a Content-Length body, the de-chunked data for a chunked
// one — a single call that works against any upstream. Returns false only
// if the (already-framed) chunk structure fails to re-parse.
@[direct_array_access]
pub fn append_body(mut out []u8, buf []u8, total int) bool {
	// One head walk serves the bounds AND the framing question.
	hl := head_len(buf)
	if hl < 0 {
		return false // not a framed response
	}
	if total <= hl {
		return true // no body
	}
	start := hl
	raw_len := total - hl
	te, _ := header_value_from(buf, hl, 'transfer-encoding')
	if te < 0 {
		unsafe { out.push_many(&u8(buf.data) + start, raw_len) }
		return true
	}
	mut pos := start
	for pos < total {
		// chunk-size, then any chunk-ext (frame_response checked its syntax,
		// BWS included) up to the line's CR. The cap keeps a size that never
		// went through frame_response from wrapping.
		mut size := i64(0)
		mut j := pos
		for j < total {
			d := hex_digit(buf[j])
			if d < 0 {
				break
			}
			size = size * 16 + i64(d)
			if size > 0x7fff_0000 {
				return false
			}
			j++
		}
		if j == pos || j >= total
			|| (buf[j] != `\r` && buf[j] != `;` && buf[j] != ` ` && buf[j] != `\t`) {
			return false // no chunk-size, or junk after it
		}
		for j < total && buf[j] != `\r` {
			j++
		}
		data := j + 2
		if size == 0 {
			return true // trailers (if any) carry no body data
		}
		if i64(data) + size > i64(total) {
			return false
		}
		unsafe { out.push_many(&u8(buf.data) + data, int(size)) }
		pos = data + int(size) + 2 // past data + CRLF
	}
	return true
}
