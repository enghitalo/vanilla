module client

// Framer is frame_response made resumable, for a response read over several
// recv calls into one growing buffer (#229). It keeps its place between
// calls, so each feed() frames only the bytes that arrived since the last
// one: O(new bytes) per recv, where calling frame_response again re-walks the
// response from byte 0 (quadratic for a chunked body of many small chunks).
// It also applies the rules frame_response leaves to its caller:
//
//   - a response to HEAD has no body, whatever its framing headers say (the
//     codec cannot know the request method, so reset() is told);
//   - 1xx interim responses (100 Continue, 103 Early Hints) are skipped: the
//     final response starts at `start`. 101 Switching Protocols is final;
//   - 204 and 304 have no body;
//   - a body delimited by connection close (no Content-Length, not chunked)
//     completes only at `eof`, and the connection is not reusable;
//   - keep_alive says whether the connection may carry the next request.
//
// Same grammar as frame_response (the helpers are shared): every line ends in
// CRLF, strict chunk-size / chunk-ext / trailer lines, Content-Length and chunk
// sizes capped at 0x7fff0000, and a final transfer coding other than chunked
// is err_malformed (#229 keeps it so; decompression is out of scope).
//
// Usage: reset() before each request, append received bytes to one buffer and
// feed() the whole buffer after every recv. The bytes already fed must not
// change between calls; a caller that drops consumed bytes from the front of
// its buffer resets the framer. No allocation.
pub struct Framer {
mut:
	stage        u8
	head_request bool
	pos          int // first byte not framed yet (a line start in the line stages)
	scan         int // fr_head: where the search for the current line's LF resumes
	need         i64 // fr_body_len: the body's end; fr_chunk_data: the chunk data's end
	end          int // the result once framed (fr_done), or the error (fr_failed)
	dechunked    bool
	body_len     int
	// the head being read
	content_length i64 = -1
	te             bool
	conn_close     bool
	conn_ka        bool
	http10         bool
	bodyless       bool
pub mut:
	// Outputs, written by feed() — read them, don't set them.
	start      int  // offset of the final (non-1xx) response in buf
	head_len   int  // its head, blank line included: the body starts at start + head_len
	status     int  // its status code, once its status line has arrived (else 0)
	keep_alive bool // once framed: the connection may carry the next request
}

// Framer stages.
const fr_head = u8(0)
const fr_body_len = u8(1)
const fr_chunk_size = u8(2)
const fr_chunk_data = u8(3)
const fr_trailers = u8(4)
const fr_until_close = u8(5)
const fr_done = u8(6)
const fr_failed = u8(7)

// err_truncated: feed() was told `eof` before the response was complete — the
// connection closed mid-response (or before any byte of it).
pub const err_truncated = -5

// reset readies the framer for the response to a new request: `head_request`
// when that request is HEAD (its response never has a body).
pub fn (mut f Framer) reset(head_request bool) {
	f = Framer{
		head_request: head_request
	}
}

// feed frames buf (everything received for this exchange so far) from where
// the previous call stopped. `eof`: the peer closed the connection after the
// last byte of buf — over TLS, only a close_notify counts (a bare FIN can be a
// truncation attack, RFC 9112 §9.8). It returns the offset just past the final
// response once it is complete (so the final response is buf[f.start..ret] and
// buf[ret..] is whatever the peer sent after it), `incomplete`,
// `err_malformed` or err_truncated. Once complete or failed it keeps returning
// the same answer.
@[direct_array_access]
pub fn (mut f Framer) feed(buf []u8, eof bool) int {
	for {
		match f.stage {
			fr_head {
				lf := lf_idx(buf, f.scan)
				if lf < 0 {
					f.scan = buf.len
					return f.short(eof)
				}
				// Every line ends in CRLF: a bare LF is err_malformed as soon as it
				// is buffered (frame_response's policy, #186).
				if lf == f.pos || buf[lf - 1] != `\r` {
					return f.fail(err_malformed)
				}
				line_end := lf - 1
				if f.pos == f.start {
					f.status_line(buf)
					if f.status < 100 {
						return f.fail(err_malformed)
					}
				} else if line_end == f.pos {
					f.head_done(lf + 1)
					continue
				} else if !f.field_line(buf, line_end) {
					return f.fail(err_malformed)
				}
				f.pos = lf + 1
				f.scan = f.pos
			}
			fr_body_len {
				if i64(buf.len) < f.need {
					return f.short(eof)
				}
				f.end = int(f.need)
				f.stage = fr_done
			}
			fr_chunk_size {
				data, size := chunk_size_line(buf, f.pos)
				if data == incomplete {
					return f.short(eof)
				}
				if data < 0 {
					return f.fail(data)
				}
				f.pos = data
				if size == 0 {
					f.stage = fr_trailers
				} else {
					f.need = i64(data) + size
					f.stage = fr_chunk_data
				}
			}
			fr_chunk_data {
				// chunk-data, then its REQUIRED CRLF (RFC 9112 §7.1).
				if f.need + 1 >= i64(buf.len) {
					return f.short(eof)
				}
				crlf := int(f.need)
				if buf[crlf] != `\r` || buf[crlf + 1] != `\n` {
					return f.fail(err_malformed)
				}
				f.pos = crlf + 2
				f.stage = fr_chunk_size
			}
			fr_trailers {
				next, last := trailer_line(buf, f.pos)
				if next == incomplete {
					return f.short(eof)
				}
				if next < 0 {
					return f.fail(next)
				}
				f.pos = next
				if last {
					f.end = next
					f.stage = fr_done
				}
			}
			fr_until_close {
				if !eof {
					return incomplete
				}
				f.end = buf.len
				f.stage = fr_done
			}
			else {
				return f.end // fr_done: the offset; fr_failed: the error
			}
		}
	}
	return incomplete
}

// short answers a feed that ran out of bytes: wait for more, unless the peer
// has closed.
@[inline]
fn (mut f Framer) short(eof bool) int {
	return if eof { f.fail(err_truncated) } else { incomplete }
}

fn (mut f Framer) fail(code int) int {
	f.stage = fr_failed
	f.end = code
	f.keep_alive = false
	return code
}

// status_line reads the status line at f.start (its CRLF has arrived).
fn (mut f Framer) status_line(buf []u8) {
	f.status = status_at(buf, f.start)
	if f.status < 0 {
		return
	}
	f.http10 = buf[f.start + 7] == `0`
	f.bodyless = f.head_request || f.status < 200 || f.status == 204 || f.status == 304
}

// field_line reads the field line buf[f.pos..line_end) for the headers that
// decide framing and reuse; false if it is malformed.
fn (mut f Framer) field_line(buf []u8, line_end int) bool {
	if !f.bodyless {
		v, vlen := field_value(buf, f.pos, line_end, 'content-length')
		if v >= 0 {
			n := parse_content_length(buf, v, vlen)
			if n < 0 || (f.content_length >= 0 && f.content_length != n) {
				return false // not 1*DIGIT, too large, or conflicting duplicates
			}
			f.content_length = n
			return true
		}
		te, te_len := field_value(buf, f.pos, line_end, 'transfer-encoding')
		if te >= 0 {
			// The only coding the codec decodes is a lone/final chunked.
			if !value_has_chunked(buf, te, te + te_len) {
				return false
			}
			f.te = true
			return true
		}
	}
	c, c_len := field_value(buf, f.pos, line_end, 'connection')
	if c >= 0 {
		f.connection_options(buf, c, c + c_len)
	}
	return true
}

// connection_options reads the Connection value buf[v..end): a list of
// options (RFC 9110 §7.6.1), of which `close` and `keep-alive` decide reuse.
@[direct_array_access]
fn (mut f Framer) connection_options(buf []u8, v int, end int) {
	mut i := v
	for i < end {
		for i < end && (buf[i] == `,` || buf[i] == ` ` || buf[i] == `\t`) {
			i++
		}
		s := i
		for i < end && buf[i] != `,` && buf[i] != ` ` && buf[i] != `\t` {
			i++
		}
		if ascii_ci_is(buf, s, i, 'close') {
			f.conn_close = true
		} else if ascii_ci_is(buf, s, i, 'keep-alive') {
			f.conn_ka = true
		}
	}
}

// ascii_ci_is reports whether buf[s..e) is `word` (lowercase), ignoring ASCII case.
@[direct_array_access]
fn ascii_ci_is(buf []u8, s int, e int, word string) bool {
	if e - s != word.len {
		return false
	}
	for j in 0 .. word.len {
		mut c := buf[s + j]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != word[j] {
			return false
		}
	}
	return true
}

// head_done ends a head at `body` (just past its blank line): skip a 1xx
// interim response, else settle the final response's framing and reuse.
fn (mut f Framer) head_done(body int) {
	if f.status < 200 && f.status != 101 {
		// An interim response: the final one follows (RFC 9110 §15.2).
		f.start = body
		f.pos = body
		f.scan = body
		f.status = 0
		f.content_length = -1
		f.te = false
		f.conn_close = false
		f.conn_ka = false
		f.http10 = false
		f.bodyless = false
		return
	}
	f.head_len = body - f.start
	f.pos = body
	// HTTP/1.1 is persistent unless the response says `close`; HTTP/1.0 only
	// with `keep-alive` (RFC 9112 §9.3). A 101 hands the connection to another
	// protocol. A message with both Transfer-Encoding and Content-Length, or an
	// HTTP/1.0 one with Transfer-Encoding, may be a smuggling attempt: framed by
	// Transfer-Encoding but never reused (RFC 9112 §6.1, §6.3).
	f.keep_alive = if f.http10 { f.conn_ka && !f.conn_close } else { !f.conn_close }
	if f.status == 101 || (f.te && (f.content_length >= 0 || f.http10)) {
		f.keep_alive = false
	}
	if f.bodyless {
		f.end = body
		f.stage = fr_done
	} else if f.te {
		f.stage = fr_chunk_size
	} else if f.content_length >= 0 {
		f.need = i64(body) + f.content_length
		f.stage = fr_body_len
	} else {
		// Delimited by connection close (RFC 9112 §6.3 rule 8).
		f.keep_alive = false
		f.stage = fr_until_close
	}
}

// is_chunked reports whether the framed response's body is chunk-framed.
pub fn (f &Framer) is_chunked() bool {
	return f.te && !f.bodyless
}

// header_value is the package-level header_value for the final response's
// head (after any 1xx interim): (start, len) of the first `name` field's value
// (lowercase name), a view into buf, or (-1, 0). Valid once head_len is set.
pub fn (f &Framer) header_value(buf []u8, name string) (int, int) {
	if f.head_len == 0 {
		return -1, 0
	}
	return header_value_in(buf, f.start, f.start + f.head_len, name)
}

// body_in_place returns the decoded body of a framed response as one view into
// buf. A chunked body is first de-chunked IN PLACE: the chunk data is moved
// down over the chunk framing, so no second buffer is needed (append_body
// copies into one). The bytes between the end of the view and the end of the
// response are left stale, and the raw chunk framing is gone, so frame the
// response before calling this; calling it again returns the same view. Empty
// while the response is not framed.
@[direct_array_access]
pub fn (mut f Framer) body_in_place(mut buf []u8) []u8 {
	if f.stage != fr_done {
		return no_body
	}
	body := f.start + f.head_len
	if f.is_chunked() && !f.dechunked {
		mut w := body
		mut pos := body
		for {
			data, size := chunk_size_line(buf, pos)
			if data < 0 || size == 0 {
				break // framed already: the last chunk
			}
			if w != data {
				unsafe { vmemmove(&u8(buf.data) + w, &u8(buf.data) + data, isize(size)) }
			}
			w += int(size)
			pos = data + int(size) + 2 // past the data and its CRLF
		}
		f.body_len = w - body
		f.dechunked = true
	} else if !f.is_chunked() {
		f.body_len = f.end - body
	}
	if f.body_len == 0 {
		return no_body
	}
	return unsafe { (&u8(buf.data) + body).vbytes(f.body_len) }
}

// valid_token reports whether s is a token (RFC 9110 §5.6.2): a method or a
// field name. Check anything interpolated into a request head.
@[direct_array_access]
pub fn valid_token(s string) bool {
	if s.len == 0 {
		return false
	}
	for i in 0 .. s.len {
		if !chunk_tchar(s[i]) {
			return false
		}
	}
	return true
}

// valid_target reports whether s can be a request-target: non-empty, visible
// ASCII only (VCHAR, RFC 5234). No SP, CR, LF, NUL or other control byte that
// would end the request line early or add a line, and no raw non-ASCII byte
// (a URI percent-encodes it).
@[direct_array_access]
pub fn valid_target(s string) bool {
	if s.len == 0 {
		return false
	}
	for i in 0 .. s.len {
		if s[i] <= 0x20 || s[i] >= 0x7f {
			return false
		}
	}
	return true
}

// valid_field_value reports whether v can be sent as a field value (RFC 9110
// §5.5): no CR, LF or NUL, which would end the field line or the head early,
// and no other control byte but HTAB. obs-text (0x80-0xff) passes.
@[direct_array_access]
pub fn valid_field_value(v []u8) bool {
	for i in 0 .. v.len {
		c := v[i]
		if (c < 0x20 && c != `\t`) || c == 0x7f {
			return false
		}
	}
	return true
}
