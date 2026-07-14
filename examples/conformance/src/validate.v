module main

import http_server.http1_1.request_parser

// Conformance verdict for a decoded request. The handler maps each to a status.
enum Verdict {
	ok            // serve the route
	bad_request   // 400: malformed per RFC 9112/9110 MUSTs
	not_supported // 505: HTTP version this server does not speak
	not_impl      // 501: unknown transfer-coding
}

// classify runs the RFC checks the stdlib parser does not already enforce and
// returns the verdict. It is intentionally strict: every rejection maps to a
// MUST in RFC 9112 (framing/§3-§6) or RFC 9110 (§5 field syntax). See the
// per-check comments for the spec reference.
//
// Layering: the framer (frame_request_length_lim) has already rejected the
// grossest framing errors (missing CRLF, over-limit head/body, bad chunk-size,
// invalid Content-Length digits) before the handler ever runs — those arrive as
// a 400 from the backend, never reaching here. This function covers the checks
// that require the parsed header view: version gate, Host rules, CL/TE conflict,
// field-name/value syntax, obsolete folding, and unknown transfer-codings.
fn classify(req request_parser.HttpRequest) Verdict {
	buf := req.buffer

	// --- HTTP version (RFC 9112 §2.3) ---------------------------------------
	// Accept only HTTP/1.0 and HTTP/1.1. A recognizable-but-unsupported version
	// (e.g. HTTP/2.0 sent over a 1.1 connection) is 505; anything else is 400.
	if req.version.len != 0 {
		if !version_is(buf, req.version, 'HTTP/1.1') && !version_is(buf, req.version, 'HTTP/1.0') {
			if req.version.len >= 5 && ascii_ci_prefix(buf, req.version.start, 'HTTP/') {
				return .not_supported
			}
			return .bad_request
		}
	} else {
		// HTTP/0.9-style request line (no version). Not supported here.
		return .bad_request
	}

	// --- RFC MUSTs already implemented in the stdlib parser -----------------
	// Host exactly-once for HTTP/1.1 (§3.2) and Content-Length+Transfer-Encoding
	// conflict (§6.1). Reuse the library check rather than re-implementing it.
	req.validate_http1() or { return .bad_request }

	// --- Duplicate Content-Length (RFC 9112 §6.3) ---------------------------
	// A message with more than one Content-Length field-line is malformed and
	// MUST be rejected — the classic smuggling vector where two lengths disagree.
	// The framer keys off the FIRST Content-Length and frames the body to it,
	// treating the rest as pipelined, so it never rejects this on its own; count
	// the header here. (`Content-Length: 5\r\nContent-Length: 5` — same value
	// repeated — is technically allowed by §6.3, but we reject any repeat: it is
	// safer and no legitimate client sends it.)
	if req.count_header('Content-Length') > 1 {
		return .bad_request
	}

	// --- Transfer-Encoding coding check (RFC 9112 §6.1 / §7) ----------------
	// If Transfer-Encoding is present its final coding MUST be "chunked", and a
	// server MUST reject an unrecognized coding. The framer only acts on chunked;
	// it treats "nonsense" or "chunked, gzip" as a bodyless request, so we gate
	// them here (501 for unknown coding, 400 for chunked-not-final).
	if te := req.get_header_value_slice('Transfer-Encoding') {
		match transfer_encoding_ok(buf, te) {
			.ok {
				// chunked, final — fine
			}
			.not_impl {
				return .not_impl
			}
			else {
				return .bad_request
			}
		}
	}

	// --- Field-line syntax (RFC 9110 §5, RFC 9112 §5) -----------------------
	if !header_syntax_ok(req) {
		return .bad_request
	}

	return .ok
}

// version_is reports whether the version slice equals `want` (case-sensitive:
// the version token is `HTTP/` + DIGIT "." DIGIT, upper-case per RFC 9112 §2.3).
@[direct_array_access]
fn version_is(buf []u8, v request_parser.Slice, want string) bool {
	if v.len != want.len {
		return false
	}
	for i in 0 .. want.len {
		if buf[v.start + i] != want[i] {
			return false
		}
	}
	return true
}

@[direct_array_access]
fn ascii_ci_prefix(buf []u8, start int, prefix string) bool {
	for i in 0 .. prefix.len {
		if (buf[start + i] | 0x20) != (prefix[i] | 0x20) {
			return false
		}
	}
	return true
}

// transfer_encoding_ok validates the Transfer-Encoding list: the final coding
// must be "chunked" and every coding must be recognized. Returns .ok, .not_impl
// (unknown coding), or .bad_request (chunked present but not final).
@[direct_array_access]
fn transfer_encoding_ok(buf []u8, te request_parser.Slice) Verdict {
	// Split the comma list into trimmed tokens; check the last is chunked and no
	// token is unknown. Only "chunked" is a coding this server frames; "gzip",
	// "deflate", "compress" are recognized codings but we don't decode them as a
	// request body, so a non-final chunked (e.g. "chunked, gzip") is malformed
	// framing (400) and a lone unknown coding is 501.
	mut tokens := [][]u8{}
	mut start := te.start
	end := te.start + te.len
	for i := te.start; i <= end; i++ {
		if i == end || buf[i] == `,` {
			mut s := start
			mut e := i
			for s < e && (buf[s] == ` ` || buf[s] == `\t`) {
				s++
			}
			for e > s && (buf[e - 1] == ` ` || buf[e - 1] == `\t`) {
				e--
			}
			if e > s {
				tokens << unsafe { (&buf[s]).vbytes(e - s) }
			}
			start = i + 1
		}
	}
	if tokens.len == 0 {
		return .bad_request
	}
	// The final coding must be chunked (RFC 9112 §6.1).
	last := tokens[tokens.len - 1]
	if !token_ci_eq(last, 'chunked') {
		// last coding is not chunked: either an unknown final coding (501) or a
		// known-but-unframed one (still can't delimit the body) → treat unknown as
		// 501, otherwise 400.
		if is_known_coding(last) {
			return .bad_request
		}
		return .not_impl
	}
	// chunked must appear exactly once and be final: any earlier chunked or any
	// unknown earlier coding is malformed.
	for i in 0 .. tokens.len - 1 {
		t := tokens[i]
		if token_ci_eq(t, 'chunked') {
			return .bad_request // chunked not final
		}
		if !is_known_coding(t) {
			return .not_impl
		}
		// a known non-chunked coding before chunked ("gzip, chunked") is legal
		// framing-wise; we accept the request (we don't decode the body).
	}
	return .ok
}

@[inline]
fn is_known_coding(t []u8) bool {
	return token_ci_eq(t, 'chunked') || token_ci_eq(t, 'gzip') || token_ci_eq(t, 'deflate')
		|| token_ci_eq(t, 'compress') || token_ci_eq(t, 'x-gzip')
}

@[direct_array_access]
fn token_ci_eq(t []u8, want string) bool {
	if t.len != want.len {
		return false
	}
	for i in 0 .. want.len {
		if (t[i] | 0x20) != (want[i] | 0x20) {
			return false
		}
	}
	return true
}

// header_syntax_ok walks each field-line and rejects the malformed shapes that
// RFC 9110 §5 / RFC 9112 §5 forbid and that the framer does not itself reject:
//   * obsolete line folding (leading SP/HTAB) — RFC 9112 §5.2
//   * empty or non-tchar field-name — RFC 9110 §5.1
//   * whitespace between field-name and ':' — RFC 9112 §5.1
//   * control bytes (incl. NUL) in the field-value — RFC 9110 §5.5
//   * whitespace inside the Host field-value — RFC 9112 §3.2 (authority syntax)
@[direct_array_access]
fn header_syntax_ok(req request_parser.HttpRequest) bool {
	hs := req.header_fields
	if hs.len <= 0 {
		return true
	}
	buf := req.buffer
	section_end := hs.start + hs.len
	mut pos := hs.start
	for pos < section_end {
		// Obsolete folding: a continuation line begins with SP or HTAB.
		if buf[pos] == ` ` || buf[pos] == `\t` {
			return false
		}
		// Find the LF ending this line; line_end excludes the trailing CR.
		mut lf := pos
		for lf < buf.len && buf[lf] != 10 {
			lf++
		}
		if lf >= buf.len {
			break
		}
		line_end := if lf > pos && buf[lf - 1] == 13 { lf - 1 } else { lf }

		// Locate the name/value colon.
		mut colon := -1
		for i := pos; i < line_end; i++ {
			if buf[i] == `:` {
				colon = i
				break
			}
		}
		if colon < 0 || colon == pos {
			return false // no colon, or empty field-name
		}
		// field-name must be all tchar (this rejects an embedded space too).
		for i := pos; i < colon; i++ {
			if !is_tchar(buf[i]) {
				return false
			}
		}
		// No whitespace directly before the colon.
		if buf[colon - 1] == ` ` || buf[colon - 1] == `\t` {
			return false
		}
		// field-value: reject controls (0x00-0x1F except HTAB) and DEL.
		for i := colon + 1; i < line_end; i++ {
			c := buf[i]
			if (c < 0x20 && c != `\t`) || c == 0x7f {
				return false
			}
		}
		// Host authority MUST NOT contain internal whitespace.
		if colon - pos == 4 && ascii_ci_prefix(buf, pos, 'host') {
			mut vs := colon + 1
			for vs < line_end && (buf[vs] == ` ` || buf[vs] == `\t`) {
				vs++
			}
			for i := vs; i < line_end; i++ {
				if buf[i] == ` ` || buf[i] == `\t` {
					return false
				}
			}
		}
		pos = lf + 1
	}
	return true
}

// is_tchar reports whether c is an RFC 9110 §5.6.2 token character.
@[inline]
fn is_tchar(c u8) bool {
	if (c >= `0` && c <= `9`) || (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) {
		return true
	}
	return c in [u8(`!`), `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, `\``, `|`, `~`]
}
