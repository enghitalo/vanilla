module client

// Pure codec tests — no sockets (docs/BEST_PRACTICES.md §9): serialize
// requests byte-exactly, frame canned/split responses, and reject the
// unframeable shapes with their distinct codes.

fn test_write_get_is_byte_exact() {
	mut out := []u8{}
	write_get(mut out, '/users/1', 'svc.local')
	assert out.bytestr() == 'GET /users/1 HTTP/1.1\r\nHost: svc.local\r\n\r\n'
}

fn test_write_request_with_body_and_extra_headers() {
	mut out := []u8{}
	write_request(mut out, 'POST', '/ingest', 'b', 'Accept: application/json\r\n',
		'{"n":42}'.bytes())
	assert out.bytestr() == 'POST /ingest HTTP/1.1\r\nHost: b\r\nAccept: application/json\r\nContent-Length: 8\r\n\r\n{"n":42}'
}

fn test_frame_complete_response() {
	buf := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
	total := frame_response(buf)
	assert total == buf.len
	assert status_code(buf) == 200
	start, len := body_bounds(buf, total)
	assert buf[start..start + len].bytestr() == 'ok'
}

fn test_frame_incomplete_head_and_body() {
	full := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	// Any strict prefix must frame as incomplete — head-split AND body-split.
	for cut in [10, full.len - 4, full.len - 1] {
		assert frame_response(full[..cut]) == incomplete, 'cut=${cut}'
	}
	assert frame_response(full) == full.len
}

fn test_frame_pipelined_keepalive() {
	one := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'.bytes()
	mut two := []u8{}
	two << one
	two << one
	total := frame_response(two)
	assert total == one.len // frames the FIRST response only
	assert frame_response(two[total..]) == one.len
}

fn test_frame_bodyless_statuses() {
	for st in ['204 No Content', '304 Not Modified', '100 Continue'] {
		mut buf := []u8{}
		ws(mut buf, 'HTTP/1.1 ')
		ws(mut buf, st)
		ws(mut buf, '\r\nDate: x\r\n\r\n')
		assert frame_response(buf) == buf.len, st
	}
}

fn test_frame_error_codes() {
	assert frame_response('HTTP/1.1 200 OK\r\nDate: x\r\n\r\n'.bytes()) == err_until_close
	assert frame_response('ICY 200 OK\r\n\r\n'.bytes()) == err_malformed
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n'.bytes()) == err_malformed
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n'.bytes()) == err_malformed
	// gzip cannot be decoded by a length-framing codec
	assert frame_response('HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nx'.bytes()) == err_malformed
}

const chunked_head = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'

fn test_frame_chunked_complete_and_decoded() {
	// two chunks + extension on the first size line
	buf := '${chunked_head}5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'.bytes()
	total := frame_response(buf)
	assert total == buf.len
	assert is_chunked(buf)
	mut body := []u8{}
	assert append_body(mut body, buf, total)
	assert body.bytestr() == 'hello world'
}

fn test_frame_chunked_split_is_incomplete() {
	full := '${chunked_head}5\r\nhello\r\n0\r\n\r\n'.bytes()
	for cut in [chunked_head.len + 1, full.len - 6, full.len - 1] {
		assert frame_response(full[..cut]) == incomplete, 'cut=${cut}'
	}
	assert frame_response(full) == full.len
}

fn test_frame_chunked_trailers_skipped() {
	buf := '${chunked_head}2\r\nok\r\n0\r\nX-Trailer: done\r\n\r\n'.bytes()
	total := frame_response(buf)
	assert total == buf.len
	mut body := []u8{}
	assert append_body(mut body, buf, total)
	assert body.bytestr() == 'ok'
}

fn test_frame_chunked_malformed() {
	// non-hex chunk size
	assert frame_response('${chunked_head}zz\r\nhi\r\n0\r\n\r\n'.bytes()) == err_malformed
	// data not terminated by CRLF (the #109 desync shape)
	assert frame_response('${chunked_head}5\r\nhello0\r\n\r\n'.bytes()) == err_malformed
}

fn test_header_value_lookup() {
	buf :=
		'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: "abc"\r\nContent-Length: 2\r\n\r\nok'.bytes()
	s, l := header_value(buf, 'content-type')
	assert buf[s..s + l].bytestr() == 'application/json'
	e, el := header_value(buf, 'etag')
	assert buf[e..e + el].bytestr() == '"abc"'
	m, _ := header_value(buf, 'x-missing')
	assert m == -1
}

fn test_case_insensitive_content_length() {
	buf := 'HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\nabc'.bytes()
	assert frame_response(buf) == buf.len
}

// The field-value view (#186 policy, mirrored from the server's request
// parser): OWS (SP / HTAB) before and after a value is not part of it
// (RFC 9112 §5.1, RFC 9110 §5.6.3); whitespace inside the value stays.
fn test_header_value_trims_ows() {
	cases := [
		['X-A: a \r\n', 'a'],
		['X-A:\ta\t\r\n', 'a'],
		['X-A: \t a , b \t \r\n', 'a , b'],
		['X-A:a\r\n', 'a'],
		['X-A: Bearer x.y \r\n', 'Bearer x.y'],
	]
	for c in cases {
		buf := 'HTTP/1.1 200 OK\r\n${c[0]}Content-Length: 0\r\n\r\n'.bytes()
		s, l := header_value(buf, 'x-a')
		assert s >= 0, c[0]
		assert buf[s..s + l].bytestr() == c[1], c[0]
	}
}

// An empty value, with or without OWS, is found with a zero length, not -1.
fn test_header_value_empty_with_ows() {
	for line in ['X-Empty:\r\n', 'X-Empty: \t \r\n', 'X-Empty:\t\r\n'] {
		buf := 'HTTP/1.1 204 No Content\r\n${line}\r\n'.bytes()
		s, l := header_value(buf, 'x-empty')
		assert s >= 0, line
		assert l == 0, line
	}
}

// A value ends at its own line: it never contains the CR or the next field
// line. A head with a bare LF does not frame (head_len is err_malformed), so
// no value is read from it: header_value never sees a field line that another
// hop reads as part of a value.
fn test_header_value_bounded_by_line() {
	buf := 'HTTP/1.1 200 OK\r\nX-Foo: a\r\nX-Bar: b\r\n\r\n'.bytes()
	s, l := header_value(buf, 'x-foo')
	assert buf[s..s + l].bytestr() == 'a'
	b, bl := header_value(buf, 'x-bar')
	assert buf[b..b + bl].bytestr() == 'b'
	for bad in ['HTTP/1.1 200 OK\r\nX-Foo: a\nX-Bar: b\r\n\r\n',
		'HTTP/1.1 200 OK\r\nX-Foo: a\n\nX-Bar: b\r\n\r\n'] {
		for name in ['x-foo', 'x-bar'] {
			m, _ := header_value(bad.bytes(), name)
			assert m == -1, '${name} in ${bad.bytes()}'
		}
		assert !is_chunked(bad.bytes())
	}
}

// OWS around the Content-Length value is valid (RFC 9112 §5.1 + §6.2) and must
// frame, not be err_malformed. Same for Transfer-Encoding.
fn test_frame_content_length_with_ows() {
	for cl in ['Content-Length: 5 ', 'Content-Length:\t5', 'Content-Length: \t5\t ', 'Content-Length:5'] {
		buf := 'HTTP/1.1 200 OK\r\n${cl}\r\n\r\nhello'.bytes()
		total := frame_response(buf)
		assert total == buf.len, cl
		assert frame_response(buf[..buf.len - 1]) == incomplete, cl
		mut body := []u8{}
		assert append_body(mut body, buf, total), cl
		assert body.bytestr() == 'hello', cl
	}
	te := '${chunked_head.replace('Transfer-Encoding: chunked', 'Transfer-Encoding:\tchunked ')}5\r\nhello\r\n0\r\n\r\n'.bytes()
	assert frame_response(te) == te.len
	// Only OWS is trimmed: a value that is all OWS is still an empty Content-Length,
	// and a non-digit inside the value is still rejected.
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: \t \r\n\r\n'.bytes()) == err_malformed
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: 5 5\r\n\r\nhello'.bytes()) == err_malformed
	// Duplicates compare the trimmed values.
	dup := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length:\t5 \r\n\r\nhello'.bytes()
	assert frame_response(dup) == dup.len
}

// A bare LF in the head is err_malformed (RFC 9112 §2.2 lets a recipient
// choose; rejecting keeps the client from seeing a field line, or a head end,
// that another hop does not). Covers the status line, field lines and the blank
// line, and rejects as soon as the bare LF is buffered: never `incomplete`.
fn test_frame_bare_lf_rejected() {
	heads := [
		'HTTP/1.1 200 OK\nContent-Length: 2\r\n\r\nok',
		'HTTP/1.1 200 OK\r\nX: a\nContent-Length: 2\r\n\r\nok',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\nok',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\nokHTTP/1.1 200 OK\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\n\r\nok',
		'\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok',
		'HTTP/1.1 200 OK\r\nX: a\nContent-Length: 2', // head still incomplete
		// The TE value used to run into the next line and find 'chunked' there.
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\nX: chunked\r\n\r\n0\r\n\r\n',
		// Bodyless statuses walk their field lines too.
		'HTTP/1.1 204 No Content\r\nX: a\n\r\n',
		'HTTP/1.1 100 Continue\n\r\n',
	]
	for h in heads {
		got := frame_response(h.bytes())
		assert got == err_malformed, '${h.bytes()} framed to ${got}'
	}
}

// chunk-size = 1*HEXDIG [ chunk-ext ] CRLF (RFC 9112 §7.1, §7.1.1): the server
// framer's rules (#185). Every one of these is err_malformed.
fn test_frame_chunked_strict_size_line() {
	bad := [
		'\r\n\r\n', // empty chunk-size
		';ext\r\n\r\n', // extension, no size
		'5\nhello\r\n0\r\n\r\n', // bare LF ends the size line
		'5\rZZ\nhello\r\n0\r\n\r\n', // junk between CR and LF
		'5;a\rb\r\nhello\r\n0\r\n\r\n', // bare CR inside an extension
		'5;a\nXXXXX\r\nhello\r\n0\r\n\r\n', // bare LF after an extension
		'5\r\nhello\r\n0\n\r\n', // bare LF ends the last-chunk line
		' 5\r\nhello\r\n0\r\n\r\n', // leading SP
		'5 \r\nhello\r\n0\r\n\r\n', // trailing SP (BWS only precedes `;`)
		'+5\r\nhello\r\n0\r\n\r\n',
		'0x5\r\nhello\r\n0\r\n\r\n',
		'5;\r\nhello\r\n0\r\n\r\n', // `;` with no name
		'5;bad[=x\r\nhello\r\n0\r\n\r\n', // non-token name
		'5;\x00ext\r\nhello\r\n0\r\n\r\n', // NUL in an extension
		'5;a=\r\nhello\r\n0\r\n\r\n', // `=` with no value
		'5;a="x\r\nhello\r\n0\r\n\r\n', // unterminated quoted-string
		'5;a="x\x01"\r\nhello\r\n0\r\n\r\n', // control byte in a quoted-string
		'5;a \r\nhello\r\n0\r\n\r\n', // trailing BWS after a name
		'5;a=b c\r\nhello\r\n0\r\n\r\n', // two tokens, no `;`
		'${'0'.repeat(16)}5\r\nhello\r\n0\r\n\r\n', // 17 digits
	]
	for b in bad {
		buf := (chunked_head + b).bytes()
		assert frame_response(buf) == err_malformed, 'must be malformed: ${b.bytes()}'
	}
}

// Trailer lines follow the same rules: CRLF line ends, field-line syntax. Each
// of the pipelined shapes used to swallow the next response as trailer lines.
fn test_frame_chunked_malformed_trailer() {
	next := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
	bad := [
		'5\r\nhello\r\n0\r\n\n', // bare LF closes the trailer section
		'5\r\nhello\r\n0\r\n\n${next}',
		'5\r\nhello\r\n0\r\nX-A: b\n\r\n', // bare LF ends a trailer line
		'5\r\nhello\r\n0\r\nX-A: b\rc\r\n\r\n', // bare CR in a value
		'5\r\nhello\r\n0\r\nX-A: b\r\r\n${next}',
		'5\r\nhello\r\n0\r\nX-A: b\r\n c\r\n\r\n', // obs-fold
		'5\r\nhello\r\n0\r\nHTTP/1.1 200 OK\r\n\r\n', // not a field-line
		'5\r\nhello\r\n0\r\n: b\r\n\r\n', // empty field-name
		'5\r\nhello\r\n0\r\nX-A : b\r\n\r\n', // SP before the colon
		'5\r\nhello\r\n0\r\nX-A: b\x00\r\n\r\n', // NUL in a value
	]
	for b in bad {
		buf := (chunked_head + b).bytes()
		assert frame_response(buf) == err_malformed, 'must be malformed: ${b.bytes()}'
	}
}

// What stays accepted, and decodes: extensions (RFC 9112 §7.1.1, incl. BWS and
// a quoted value), upper- and lower-case hex, leading zeros, trailer fields.
fn test_frame_chunked_allowed_shapes() {
	good := [
		['5;name=value\r\nhello\r\n0\r\n\r\n', 'hello'],
		['5;a;b=c;d="q"\r\nhello\r\n0\r\n\r\n', 'hello'],
		['5 ; a = "x \\" y\t" ;b\r\nhello\r\n0\r\n\r\n', 'hello'],
		['5\t;a\r\nhello\r\n0\r\n\r\n', 'hello'],
		['A\r\n0123456789\r\n0\r\n\r\n', '0123456789'],
		['a\r\n0123456789\r\n0\r\n\r\n', '0123456789'],
		['${'0'.repeat(15)}5\r\nhello\r\n0;last\r\n\r\n', 'hello'],
		['0\r\n\r\n', ''],
		['5\r\nhello\r\n000;x=1\r\nX-A: b\r\nX-Sig:\t"a, b" \r\nX-Empty:\r\n\r\n', 'hello'],
	]
	for g in good {
		buf := (chunked_head + g[0]).bytes()
		total := frame_response(buf)
		assert total == buf.len, 'must frame: ${g[0]}'
		mut body := []u8{}
		assert append_body(mut body, buf, total), g[0]
		assert body.bytestr() == g[1], g[0]
	}
}

// A trailer section ends the message at its closing CRLF: a pipelined response
// behind it is framed on its own.
fn test_frame_chunked_trailer_then_pipelined() {
	first := '${chunked_head}5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n'
	next := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
	buf := (first + next).bytes()
	total := frame_response(buf)
	assert total == first.len
	assert frame_response(buf[total..]) == next.len
}

// Every strict prefix of a valid response is `incomplete`: never err_malformed,
// never framed early. The verdict must not depend on how bytes were segmented.
fn test_frame_split_fuzz() {
	responses := [
		'HTTP/1.1 200 OK\r\nContent-Length: 5 \r\nX-A:\tb\t\r\n\r\nhello',
		'HTTP/1.1 204 No Content\r\nX-A: b\r\n\r\n',
		'${chunked_head}${'0'.repeat(15)}4;a="b;c" ;d\r\nWiki\r\n0;z\r\nX-Checksum: abc\r\nX-B: c\r\n\r\n',
	]
	for r in responses {
		full := r.bytes()
		assert frame_response(full) == full.len, r
		for cut in 0 .. full.len {
			got := frame_response(full[..cut])
			assert got == incomplete, 'prefix ${cut} of ${r.bytes()} framed to ${got}'
		}
	}
}

// The tchar bitmaps match RFC 9110 §5.6.2 for every byte.
fn test_chunk_tchar_table() {
	specials := "!#$%&'*+-.^_`|~"
	for c in 0 .. 256 {
		b := u8(c)
		want := (b >= `0` && b <= `9`) || (b >= `a` && b <= `z`) || (b >= `A` && b <= `Z`)
			|| specials.index_u8(b) >= 0
		assert chunk_tchar(b) == want, 'byte ${c}'
	}
}

// The final transfer coding must be chunked (RFC 9112 §6.3): a response whose
// final coding is anything else is delimited by close, not by chunk frames.
fn test_frame_te_final_coding() {
	body := '5\r\nhello\r\n0\r\n\r\n'
	for te in ['chunked', 'CHUNKED', 'gzip, chunked', 'gzip ,\tchunked', 'gzip,chunked'] {
		buf := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: ${te}\r\n\r\n${body}'.bytes()
		assert frame_response(buf) == buf.len, te
	}
	for te in ['chunked, gzip', 'xchunked', 'gzip chunked', 'chunked,', 'gzip\r, chunked', 'chunked;q=1'] {
		buf := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: ${te}\r\n\r\n${body}'.bytes()
		assert frame_response(buf) == err_malformed, te
	}
}

// head_len (which frames HEAD exchanges, and backs body_bounds / append_body)
// applies the bare-LF policy too, and agrees with frame_response on where the
// head ends for every response frame_response accepts.
fn test_head_len_matches_frame_response() {
	assert head_len('HTTP/1.1 200 OK\r\nX: a\n\nHTTP/1.1 200 OK\r\n\r\n'.bytes()) == err_malformed
	assert head_len('HTTP/1.1 200 OK\nX: a\r\n\r\n'.bytes()) == err_malformed
	assert head_len('HTTP/1.1 200 OK\r\nX: a\r\n'.bytes()) == incomplete
	responses := [
		'HTTP/1.1 200 OK\r\nContent-Length: 5 \r\nX-A: b\r\r\n\r\nhello',
		'HTTP/1.1 204 No Content\r\nX-A: b\r\n\r\n',
		'${chunked_head}5;a=1\r\nhello\r\n0\r\nX-C: d\r\n\r\n',
	]
	for r in responses {
		buf := r.bytes()
		total := frame_response(buf)
		assert total == buf.len, r
		hl := head_len(buf)
		assert hl == (r.index('\r\n\r\n') or { -1 }) + 4, r
		start, len := body_bounds(buf, total)
		if total > hl {
			assert start == hl && start + len == total, r
		}
	}
	// append_body refuses a head that does not frame.
	mut out := []u8{}
	assert !append_body(mut out, 'HTTP/1.1 200 OK\nContent-Length: 2\r\n\r\nok'.bytes(), 36)
}

// status-line = HTTP-version SP 3DIGIT SP reason-phrase (RFC 9112 §4).
fn test_status_line_shape() {
	assert status_code('HTTP/1.1 200 OK\r\n'.bytes()) == 200
	assert status_code('HTTP/1.0 404 \r\n'.bytes()) == 404
	assert status_code('HTTP/1.1 200\r\n'.bytes()) == 200
	assert status_code('HTTP/1.\r 200 OK\r\n'.bytes()) == -1
	assert status_code('HTTP/1.x 200 OK\r\n'.bytes()) == -1
	assert status_code('HTTP/1.1 2000 OK\r\n'.bytes()) == -1
	assert frame_response('HTTP/1.1 2000 OK\r\nContent-Length: 0\r\n\r\n'.bytes()) == err_malformed
}

// append_body on bytes it is handed without frame_response: junk after the
// chunk-size is an error, not decoded.
fn test_append_body_rejects_junk_size() {
	buf := '${chunked_head}5zz\r\nhello\r\n0\r\n\r\n'.bytes()
	mut out := []u8{}
	assert !append_body(mut out, buf, buf.len)
}
