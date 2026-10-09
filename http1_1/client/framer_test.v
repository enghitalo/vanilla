module client

// Framer tests (#229): the resumable framer must give the same verdict
// whatever way the bytes were split across recv calls, and apply the
// method / 1xx / close-delimited / keep-alive rules frame_response leaves to
// its caller.

const ch_head = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'

struct FramerCase {
	resp         string
	head_request bool
	eof          bool // the peer closes right after resp
	end          int  // expected feed() result on the whole buffer
	status       int
	keep_alive   bool
	body         string
}

fn framer_cases() []FramerCase {
	cl := 'HTTP/1.1 200 OK\r\nContent-Length: 5 \r\nX-A:\tb\t\r\n\r\nhello'
	chunked := '${ch_head}${'0'.repeat(15)}4;a="b;c" ;d\r\nWiki\r\n5\r\npedia\r\n0;z\r\nX-Checksum: abc\r\nX-B: c\r\n\r\n'
	interim := 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\n'
	created := 'HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok'
	next := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
	no_content := 'HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n'
	not_modified := 'HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n'
	head_cl := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n'
	close_11 := 'HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello'
	close_10 := 'HTTP/1.0 200 OK\r\n\r\nhello'
	close_empty := 'HTTP/1.1 200 OK\r\n\r\n'
	return [
		FramerCase{
			resp:       cl
			end:        cl.len
			status:     200
			keep_alive: true
			body:       'hello'
		},
		FramerCase{
			resp:       chunked
			end:        chunked.len
			status:     200
			keep_alive: true
			body:       'Wikipedia'
		},
		// pipelined: the second response is left over
		FramerCase{
			resp:       chunked + next
			end:        chunked.len
			status:     200
			keep_alive: true
			body:       'Wikipedia'
		},
		FramerCase{
			resp:       interim + created
			end:        interim.len + created.len
			status:     201
			keep_alive: true
			body:       'ok'
		},
		FramerCase{
			resp:       no_content
			end:        no_content.len
			status:     204
			keep_alive: true
		},
		FramerCase{
			resp:       not_modified
			end:        not_modified.len
			status:     304
			keep_alive: true
		},
		// HEAD: complete at the head, whatever the framing headers say
		FramerCase{
			resp:         head_cl
			head_request: true
			end:          head_cl.len
			status:       200
			keep_alive:   true
		},
		FramerCase{
			resp:         '${ch_head}${next}'
			head_request: true
			end:          ch_head.len
			status:       200
			keep_alive:   true
		},
		// close-delimited: complete at eof only, never reused
		FramerCase{
			resp:   close_11
			eof:    true
			end:    close_11.len
			status: 200
			body:   'hello'
		},
		FramerCase{
			resp:   close_10
			eof:    true
			end:    close_10.len
			status: 200
			body:   'hello'
		},
		FramerCase{
			resp:   close_empty
			eof:    true
			end:    close_empty.len
			status: 200
		},
	]
}

fn check_framed(f &Framer, c FramerCase, got int, what string) {
	assert got == c.end, '${what}: ${c.resp.bytes()} framed to ${got}, want ${c.end}'
	assert f.status == c.status, what
	assert f.keep_alive == c.keep_alive, what
}

// Every split of every response frames to the same result as the whole
// buffer: fed byte by byte on one framer, and fed in two steps at every cut.
// A strict prefix is never complete and never an error.
fn test_framer_every_split() {
	for c in framer_cases() {
		full := c.resp.bytes()
		mut whole := Framer{}
		whole.reset(c.head_request)
		check_framed(whole, c, whole.feed(full, c.eof), 'whole')
		mut decoded := full.clone()
		assert whole.body_in_place(mut decoded).bytestr() == c.body, c.resp
		// One framer, one more byte per feed (the worst-case recv pattern).
		mut f := Framer{}
		f.reset(c.head_request)
		mut got := incomplete
		for n in 0 .. full.len + 1 {
			got = f.feed(unsafe { full[..n] }, c.eof && n == full.len)
			if n < c.end || (c.eof && n < full.len) {
				assert got == incomplete, 'prefix ${n} of ${full} framed to ${got}'
			}
		}
		check_framed(f, c, got, 'byte by byte')
		assert f.start == whole.start && f.head_len == whole.head_len
		// Two feeds, split at every cut.
		for cut in 0 .. full.len {
			mut g := Framer{}
			g.reset(c.head_request)
			first := g.feed(unsafe { full[..cut] }, false)
			assert first == incomplete || first == c.end, 'cut ${cut}: ${first}'
			check_framed(g, c, g.feed(full, c.eof), 'cut ${cut}')
		}
	}
}

// What frame_response frames, the Framer frames to the same total.
fn test_framer_agrees_with_frame_response() {
	for r in [
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok',
		'${ch_head}5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n',
		'${ch_head}2\r\nok\r\n0\r\nX-Trailer: done\r\n\r\n',
		'HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\nabc',
		'HTTP/1.1 204 No Content\r\nX-A: b\r\n\r\n',
	] {
		buf := r.bytes()
		mut f := Framer{}
		f.reset(false)
		assert f.feed(buf, false) == frame_response(buf), r
	}
	// ...and rejects what frame_response rejects (the shared grammar).
	for b in ['5\nhello\r\n0\r\n\r\n', '5\r\nhello0\r\n\r\n', 'zz\r\nhi\r\n0\r\n\r\n',
		'5\r\nhello\r\n0\r\nX-A : b\r\n\r\n', '${'0'.repeat(16)}5\r\nhello\r\n0\r\n\r\n'] {
		buf := (ch_head + b).bytes()
		mut f := Framer{}
		f.reset(false)
		assert f.feed(buf, false) == err_malformed, b
		assert frame_response(buf) == err_malformed, b
	}
	for h in ['HTTP/1.1 200 OK\nContent-Length: 2\r\n\r\nok', 'ICY 200 OK\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 2147418113\r\n\r\n', 'HTTP/1.1 100 Continue\n\r\n',
		'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nX: a\n\r\n'] {
		mut f := Framer{}
		f.reset(false)
		assert f.feed(h.bytes(), false) == err_malformed, h
	}
}

// A non-chunked final transfer coding stays err_malformed (RFC 9112 §6.3 would
// read it as close-delimited; the codec cannot decode it either way).
fn test_framer_te_not_chunked_is_malformed() {
	for te in ['chunked, gzip', 'gzip', 'xchunked'] {
		buf := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: ${te}\r\n\r\n5\r\nhello\r\n0\r\n\r\n'.bytes()
		mut f := Framer{}
		f.reset(false)
		assert f.feed(buf, false) == err_malformed, te
		assert f.feed(buf, true) == err_malformed, 'an error sticks: ${te}'
		assert !f.keep_alive
	}
}

// The keep-alive verdict (RFC 9112 §9.3): HTTP/1.1 unless `close`; HTTP/1.0
// only with `keep-alive`; never for a close-delimited body, a 101, or framing
// that may be smuggling.
fn test_framer_keep_alive() {
	cases := {
		'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n':                                               true
		'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n':                          false
		'HTTP/1.1 200 OK\r\nConnection: Keep-Alive, CLOSE\r\nContent-Length: 0\r\n\r\n':              false
		'HTTP/1.1 200 OK\r\nConnection: upgrade\r\nConnection:\tclose \r\nContent-Length: 0\r\n\r\n': false
		'HTTP/1.1 200 OK\r\nConnection: closed\r\nContent-Length: 0\r\n\r\n':                         true
		'HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n':                                       false
		'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n':                                               false
		'HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n':                     true
		'HTTP/1.0 200 OK\r\nConnection: keep-alive, close\r\nContent-Length: 0\r\n\r\n':              false
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n':        false
		'HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n':   false
		'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n':      false
	}
	for r, want in cases {
		buf := r.bytes()
		mut f := Framer{}
		f.reset(false)
		assert f.feed(buf, false) == buf.len, r
		assert f.keep_alive == want, r
	}
}

// eof before the response is complete is err_truncated, in every stage —
// including a connection closed before any byte of the response.
fn test_framer_truncated() {
	full := '${ch_head}5\r\nhello\r\n0\r\n\r\n'
	for r in ['', 'HTTP/1.1 2', 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel',
		'${ch_head}5\r\nhel', '${ch_head}5\r\nhello\r', full[..full.len - 1]] {
		mut f := Framer{}
		f.reset(false)
		assert f.feed(r.bytes(), false) == incomplete, r
		assert f.feed(r.bytes(), true) == err_truncated, r
		assert !f.keep_alive
	}
}

// 1xx interim responses are skipped; the final response's head is where
// status, head_len and header_value look.
fn test_framer_skips_interim_responses() {
	interim := 'HTTP/1.1 100 Continue\r\nX-Which: interim\r\n\r\n'
	final := 'HTTP/1.1 413 Content Too Large\r\nX-Which: final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
	mut buf := (interim + final).bytes()
	mut f := Framer{}
	f.reset(false)
	assert f.feed(buf, false) == buf.len
	assert f.start == interim.len
	assert f.head_len == final.len
	assert f.status == 413
	assert !f.keep_alive
	s, l := f.header_value(buf, 'x-which')
	assert buf[s..s + l].bytestr() == 'final'
	assert f.body_in_place(mut buf).len == 0
}

// The in-place de-chunk gives the same bytes as append_body, leaves what
// follows the response untouched, and is idempotent.
fn test_framer_body_in_place_matches_append_body() {
	next := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
	for g in [
		'5;name=value\r\nhello\r\n0\r\n\r\n',
		'5 ; a = "x \\" y\t" ;b\r\nhello\r\n6\r\n world\r\n0\r\n\r\n',
		'A\r\n0123456789\r\n1\r\n!\r\n0\r\nX-A: b\r\n\r\n',
		'0\r\n\r\n',
		'${'0'.repeat(15)}5\r\nhello\r\n000;x=1\r\nX-Sig:\t"a, b" \r\n\r\n',
	] {
		resp := ch_head + g
		mut want := []u8{}
		assert append_body(mut want, resp.bytes(), resp.len)
		mut buf := (resp + next).bytes()
		mut f := Framer{}
		f.reset(false)
		framed := f.feed(buf, false)
		assert framed == resp.len, g
		assert f.is_chunked()
		body := f.body_in_place(mut buf)
		assert body == want, g
		assert f.body_in_place(mut buf) == want, 'twice: ${g}'
		assert buf[framed..].bytestr() == next, g
	}
	// A Content-Length body is a view, untouched.
	mut cl := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP'.bytes()
	mut fc := Framer{}
	fc.reset(false)
	assert fc.feed(cl, false) == cl.len - 4
	assert fc.body_in_place(mut cl).bytestr() == 'hello'
	// Not framed yet: no body.
	mut fi := Framer{}
	fi.reset(false)
	assert fi.feed(cl[..20], false) == incomplete
	assert fi.body_in_place(mut cl).len == 0
}

// A zero Framer behaves as reset(false).
fn test_framer_zero_value() {
	buf := 'HTTP/1.1 200 OK\r\n\r\nx'.bytes()
	mut f := Framer{}
	assert f.feed(buf, false) == incomplete // close-delimited, not Content-Length: 0
	assert f.feed(buf, true) == buf.len
}

// Anything interpolated into a request head is checked first: a CR or LF in a
// target, method, field name or value would add a line (header injection).
fn test_head_validation() {
	assert valid_token('GET')
	assert valid_token('X-Request-Id')
	assert valid_token("!#$%&'*+-.^_`|~09azAZ")
	for bad in ['', 'GET ', 'G\r\nET', 'X:A', 'a(b)', 'caf\xc3\xa9', 'x\x00'] {
		assert !valid_token(bad), bad
	}
	assert valid_target('/v1/charges?q=a&b=%20c')
	assert valid_target('*')
	assert valid_target('http://example.com/x')
	for bad in ['', '/v1/charges?q=a\r\nX-Injected: 1', '/a b', '/a\tb', '/a\x00', '/a\x7f', '/caf\xc3\xa9'] {
		assert !valid_target(bad), bad
	}
	assert valid_field_value('Bearer abc.def'.bytes())
	assert valid_field_value('a\tb, "c"'.bytes())
	assert valid_field_value('caf\xc3\xa9'.bytes())
	assert valid_field_value([]u8{})
	for bad in ['a\r\nX-Injected: 1', 'a\nb', 'a\rb', 'a\x00b', 'a\x01b', 'a\x7fb'] {
		assert !valid_field_value(bad.bytes()), bad
	}
}
