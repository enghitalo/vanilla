module request_parser

fn test_parse_http1_request_line_valid_request() {
	buffer := 'GET /path/to/resource HTTP/1.1\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	parse_http1_request_line(mut req) or { panic(err) }

	assert req.method.to_string(req.buffer) == 'GET'
	assert req.path.to_string(req.buffer) == '/path/to/resource'
	assert req.version.to_string(req.buffer) == 'HTTP/1.1'
}

fn test_parse_http1_request_line_invalid_request() {
	buffer := 'INVALID REQUEST LINE'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	mut has_error := false
	parse_http1_request_line(mut req) or {
		has_error = true
		assert err.msg() == 'Missing CR'
	}
	assert has_error, 'Expected error for invalid request line'
}

fn test_decode_http_request_valid_request() {
	// A zero-header HTTP/1.0 request is valid SYNTAX (RFC 9112 §2.1) and must
	// parse. Refusing to *serve* HTTP/1.0 is a server policy (respond 505 HTTP
	// Version Not Supported, RFC 9110 §15.6.6) — never a parse error. The parser
	// stays strict-but-not-inventive.
	buffer := 'POST /api/resource HTTP/1.0\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic('HTTP/1.0 zero-header should parse: ${err}') }
	assert req.method.to_string(req.buffer) == 'POST'
	assert req.path.to_string(req.buffer) == '/api/resource'
	assert req.version.to_string(req.buffer) == 'HTTP/1.0'
	assert req.header_fields.len == 0
}

fn test_decode_http_request_invalid_request() {
	buffer := 'INVALID REQUEST LINE'.bytes()

	mut has_error := false
	decode_http_request(buffer) or { has_error = true }
	assert has_error, 'Expected error for invalid request'
}

fn test_decode_http_request_with_headers_and_body() {
	raw := 'POST /submit HTTP/1.1\r\n' + 'Host: localhost\r\n' +
		'Content-Type: application/json\r\n' + 'Content-Length: 18\r\n' + '\r\n' +
		'{"status": "ok"}'

	buffer := raw.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	assert req.method.to_string(req.buffer) == 'POST'
	assert req.path.to_string(req.buffer) == '/submit'

	// Verify Header Fields block
	// Should contain everything between the first \r\n and the \r\n\r\n
	header_str := req.header_fields.to_string(req.buffer)
	assert header_str == 'Host: localhost\r\nContent-Type: application/json\r\nContent-Length: 18'

	// Verify Body
	assert req.body.to_string(req.buffer) == '{"status": "ok"}'
}

fn test_decode_http_request_no_body() {
	// A GET request usually ends with \r\n\r\n and no body
	buffer := 'GET /index.html HTTP/1.1\r\nUser-Agent: V\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	assert req.header_fields.to_string(req.buffer) == 'User-Agent: V'
	assert req.body.len == 0
}

fn test_decode_http_request_malformed_no_double_crlf() {
	// A header line with no terminating blank line is an incomplete message and
	// must be rejected (there is no header/body delimiter).
	buffer := 'GET / HTTP/1.1\r\nHost: example.com\r\n'.bytes()
	mut has_error := false
	decode_http_request(buffer) or { has_error = true }
	assert has_error, 'Expected error for missing header-body delimiter'
}

fn test_get_header_value_slice_existing_header() {
	buffer := 'GET / HTTP/1.1\r\nHost: example.com\r\nContent-Type: text/html\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	host_slice := req.get_header_value_slice('Host') or { panic('Header not found') }
	assert host_slice.to_string(req.buffer) == 'example.com'

	content_type_slice := req.get_header_value_slice('Content-Type') or {
		panic('Header not found')
	}
	assert content_type_slice.to_string(req.buffer) == 'text/html'
}

fn test_get_header_value_slice_non_existing_header() {
	buffer := 'GET / HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	assert req.get_header_value_slice('Content-Type') == none
}

fn test_get_header_value_slice_with_extra_spaces() {
	buffer := 'GET / HTTP/1.1\r\nAuthorization:   Bearer token123\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	auth_slice := req.get_header_value_slice('Authorization') or { panic('Header not found') }
	assert auth_slice.to_string(req.buffer) == 'Bearer token123'
}

fn test_get_header_value_slice_empty_value() {
	buffer := 'GET / HTTP/1.1\r\nX-Custom: \r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	custom_slice := req.get_header_value_slice('X-Custom') or { panic('Header not found') }
	assert custom_slice.to_string(req.buffer) == ''
}

// issue #186: OWS (SP / HTAB) before and after a field value is not part of it
// (RFC 9112 §5.1, RFC 9110 §5.6.3). Whitespace inside the value stays.
fn test_get_header_value_slice_trims_ows() {
	cases := [
		['Authorization: Bearer x \r\n', 'Authorization', 'Bearer x'],
		['Content-Type:\tapplication/json\t\r\n', 'Content-Type', 'application/json'],
		['Origin: https://app.example \t\r\n', 'Origin', 'https://app.example'],
		['X-List: \t a , b \t \r\n', 'X-List', 'a , b'],
		['X-Tight:v\r\n', 'X-Tight', 'v'],
	]
	for c in cases {
		req := decode_http_request('GET / HTTP/1.1\r\nHost: h\r\n${c[0]}\r\n'.bytes()) or {
			panic(err)
		}
		v := req.get_header_value_slice(c[1]) or { panic('${c[1]} not found') }
		assert v.to_string(req.buffer) == c[2], 'raw line ${c[0]}'
	}
}

// issues #184 + #186: a line with whitespace between the name and the colon is
// not a field line for that name. The framer refuses it only for Content-Length
// and Transfer-Encoding; for any other name the app sees no such field instead
// of line_header_value's len -1 "malformed" marker.
fn test_get_header_value_slice_skips_whitespace_before_colon() {
	for line in ['X-Foo : bar\r\n', 'X-Foo\t: bar\r\n'] {
		req := decode_http_request('GET / HTTP/1.1\r\nHost: h\r\n${line}\r\n'.bytes()) or {
			panic(err)
		}
		assert req.get_header_value_slice('X-Foo') == none, 'raw line ${line}'
	}
	req := decode_http_request('GET / HTTP/1.1\r\nHost: h\r\nX-Foo : bad\r\nX-Foo: good\r\n\r\n'.bytes()) or {
		panic(err)
	}
	v := req.get_header_value_slice('X-Foo') or { panic('the well-formed X-Foo line must be found') }
	assert v.to_string(req.buffer) == 'good'
}

// issue #186: an empty value, with or without OWS, is a zero-length Slice, not none.
fn test_get_header_value_slice_empty_value_with_ows() {
	for line in ['X-Empty:\r\n', 'X-Empty: \t \r\n', 'X-Empty:\t\r\n'] {
		req := decode_http_request('GET / HTTP/1.1\r\nHost: h\r\n${line}\r\n'.bytes()) or {
			panic(err)
		}
		v := req.get_header_value_slice('X-Empty') or { panic('empty value must not be none') }
		assert v.len == 0
	}
}

// issue #186: content_length() reads the value through the same trimmed view.
fn test_content_length_accessor_trims_ows() {
	req := decode_http_request('POST / HTTP/1.1\r\nHost: h\r\nContent-Length:\t5 \r\n\r\nhello'.bytes()) or {
		panic(err)
	}
	assert req.content_length() == 5
}

// issue #186: on bytes that never went through the framer, a value still ends at
// its own LF: it never contains the LF or the next field line, and
// get_header_value_slice and count_header walk the same lines. (The server never
// gets here: the framer answers 400 to a bare LF, see test_frame_bare_lf_rejected.)
fn test_get_header_value_slice_bounded_by_line() {
	req :=
		decode_http_request('GET / HTTP/1.1\r\nHost: a\r\nX-Foo: a\nX-Forwarded-For: 1.2.3.4\r\n\r\n'.bytes()) or {
			panic(err)
		}
	foo := req.get_header_value_slice('X-Foo') or { panic('X-Foo') }
	assert foo.to_string(req.buffer) == 'a'
	xff := req.get_header_value_slice('X-Forwarded-For') or { panic('X-Forwarded-For') }
	assert xff.to_string(req.buffer) == '1.2.3.4'
	assert req.count_header('X-Forwarded-For') == 1
	assert req.count_header('X-Foo') == 1
}

fn test_parse_http1_request_line_multiple_spaces_after_method() {
	buffer := 'GET   /path HTTP/1.1\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	parse_http1_request_line(mut req) or { panic(err) }

	assert req.method.to_string(req.buffer) == 'GET'
	assert req.path.to_string(req.buffer) == '/path'
	assert req.version.to_string(req.buffer) == 'HTTP/1.1'
}

fn test_parse_http1_request_line_http09_style() {
	// HTTP/0.9 style: no version, just method and path
	// This implementation doesn't support HTTP/0.9, so it should error
	buffer := 'GET /index.html\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	mut has_error := false
	parse_http1_request_line(mut req) or {
		has_error = true
		assert err.msg() == 'Missing space after request-target'
	}
	assert has_error, 'Expected error for HTTP/0.9 style request'
}

fn test_parse_http1_request_line_too_short() {
	buffer := 'GET\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	mut has_error := false
	parse_http1_request_line(mut req) or {
		has_error = true
		assert err.msg() == 'request line too short'
	}
	assert has_error, 'Expected error for too short request'
}

fn test_parse_http1_request_line_empty_method() {
	buffer := ' /path HTTP/1.1\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	mut has_error := false
	parse_http1_request_line(mut req) or {
		has_error = true
		assert err.msg() == 'empty method'
	}
	assert has_error, 'Expected error for empty method'
}

fn test_parse_http1_request_line_missing_space_after_method() {
	buffer := 'GET\r\n'.bytes()
	mut req := HttpRequest{
		buffer: buffer
	}

	mut has_error := false
	parse_http1_request_line(mut req) or {
		has_error = true
		assert err.msg() == 'request line too short'
	}
	assert has_error, 'Expected error for missing space after method'
}

fn test_get_query_slice_single_parameter() {
	buffer := 'GET /users?id=123 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	id_slice := req.get_query_slice('id'.bytes()) or { panic('Query parameter not found') }
	assert id_slice.to_string(req.buffer) == '123'
}

fn test_get_query_slice_multiple_parameters() {
	buffer := 'GET /search?query=test&page=2&limit=50 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	query_slice := req.get_query_slice('query'.bytes()) or { panic('Query parameter not found') }
	assert query_slice.to_string(req.buffer) == 'test'

	page_slice := req.get_query_slice('page'.bytes()) or { panic('Query parameter not found') }
	assert page_slice.to_string(req.buffer) == '2'

	limit_slice := req.get_query_slice('limit'.bytes()) or { panic('Query parameter not found') }
	assert limit_slice.to_string(req.buffer) == '50'
}

fn test_get_query_slice_last_parameter() {
	buffer := 'GET /api?first=1&second=2&last=3 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	last_slice := req.get_query_slice('last'.bytes()) or { panic('Query parameter not found') }
	assert last_slice.to_string(req.buffer) == '3'
}

fn test_get_query_slice_no_query_string() {
	buffer := 'GET /users HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	result := req.get_query_slice('id'.bytes())
	assert result == none
}

fn test_get_query_slice_non_existing_parameter() {
	buffer := 'GET /users?id=123 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	result := req.get_query_slice('name'.bytes())
	assert result == none
}

fn test_get_query_slice_empty_value() {
	buffer := 'GET /search?query= HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	query_slice := req.get_query_slice('query'.bytes()) or { panic('Query parameter not found') }
	assert query_slice.to_string(req.buffer) == ''
}

fn test_get_query_slice_empty_key() {
	// An element starting with '=' has an empty key; an empty lookup key must not
	// match it (it used to index key[0] on an empty array: a panic that ended the
	// process).
	for target in ['/a?=x', '/a?a=1&=x', '/a?=', '/a?b=2'] {
		buffer := 'GET ${target} HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
		req := decode_http_request(buffer) or { panic(err) }
		assert req.get_query_slice([]u8{}) == none, target
		assert req.get_query('') == Slice{0, 0}, target
	}
}

fn test_get_query_slice_empty_value_at_buffer_end() {
	// A hand-built request whose path ends the buffer: the empty value's start is
	// one past the last byte, which must not be indexed.
	buffer := '/s?q='.bytes()
	req := HttpRequest{
		buffer: buffer
		path:   Slice{0, buffer.len}
	}
	value := req.get_query_slice('q'.bytes()) or { panic('Query parameter not found') }
	assert value.len == 0
	assert req.get_query('q').len == 0
}

fn test_get_query_matches_get_query_slice() {
	buffer := 'GET /api?id=42&name=v HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	assert req.get_query('name').to_string(req.buffer) == 'v'
	assert req.get_query('missing') == Slice{0, 0}
}

fn test_get_query_slice_special_characters() {
	buffer := 'GET /api?token=abc-123_xyz HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	token_slice := req.get_query_slice('token'.bytes()) or { panic('Query parameter not found') }
	assert token_slice.to_string(req.buffer) == 'abc-123_xyz'
}

fn test_has_query() {
	// target, key, has_query, get_query_slice (`none` when absent)
	cases := [
		['/a?debug', 'debug', 'true', 'none'],
		['/a?debug=', 'debug', 'true', ''],
		['/a?debug=1', 'debug', 'true', '1'],
		['/a?debug&id=5', 'debug', 'true', 'none'],
		['/a?debug&id=5', 'id', 'true', '5'],
		['/a?id=5&debug', 'debug', 'true', 'none'],
		['/a?id=5&debug&x=1', 'x', 'true', '1'],
		['/a?debug&debug=2', 'debug', 'true', '2'],
		['/a?&&debug&', 'debug', 'true', 'none'],
		['/a?a=b=c', 'a', 'true', 'b=c'],
		['/a?debugx=1', 'debug', 'false', 'none'],
		['/a?debugx', 'debug', 'false', 'none'],
		['/a?xdebug', 'debug', 'false', 'none'],
		['/a?deb', 'debug', 'false', 'none'],
		['/a?id=debug', 'debug', 'false', 'none'],
		['/a?=debug', 'debug', 'false', 'none'],
		['/a?', 'debug', 'false', 'none'],
		['/a', 'debug', 'false', 'none'],
		['/debug', 'debug', 'false', 'none'],
		['/a?a=b=c', 'a=b', 'false', 'none'],
		['/a?a=b', 'a=b', 'false', 'none'],
		['/a?a&b=1', 'a&b', 'false', 'none'],
		['/a?debug', '', 'false', 'none'],
		['/a?=x', '', 'false', 'none'],
	]
	for c in cases {
		buffer := 'GET ${c[0]} HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
		req := decode_http_request(buffer) or { panic(err) }
		key := c[1].bytes()
		assert req.has_query(key) == (c[2] == 'true'), '${c[0]} ${c[1]}'
		if s := req.get_query_slice(key) {
			assert s.to_string(req.buffer) == c[3], '${c[0]} ${c[1]}'
		} else {
			assert c[3] == 'none', '${c[0]} ${c[1]}'
		}
	}
}

fn test_has_query_bare_key_at_buffer_end() {
	// A hand-built request whose path ends the buffer with a bare key.
	buffer := '/s?a=1&flag'.bytes()
	req := HttpRequest{
		buffer: buffer
		path:   Slice{0, buffer.len}
	}
	assert req.has_query('flag'.bytes())
	assert req.get_query_slice('flag'.bytes()) == none
	assert req.has_query('a'.bytes())
	assert !req.has_query('fla'.bytes())
	assert !req.has_query('flagx'.bytes())
}

fn test_get_query_deprecated() {
	buffer := 'GET /users?id=456 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	id_slice := req.get_query('id')
	assert id_slice.to_string(req.buffer) == '456'
}

fn test_get_query_deprecated_not_found() {
	buffer := 'GET /users HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	result := req.get_query('id')
	assert result.len == 0
}

// --- RFC conformance gates ------------------------------------------------

fn test_decode_zero_header_request() {
	// RFC 9112 §2.1: zero field-lines is valid syntax. Must parse, not error.
	buffer := 'GET / HTTP/1.1\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic('zero-header should parse: ${err}') }
	assert req.path.to_string(req.buffer) == '/'
	assert req.header_fields.len == 0
	assert req.body.len == 0
}

fn test_decode_zero_header_with_body() {
	buffer := 'POST /x HTTP/1.1\r\n\r\nhello'.bytes()
	req := decode_http_request(buffer) or { panic('zero-header+body should parse: ${err}') }
	assert req.header_fields.len == 0
	assert req.body.to_string(req.buffer) == 'hello'
}

fn test_get_header_value_case_insensitive() {
	// RFC 9110 §5.1: field names are case-insensitive.
	buffer :=
		'GET / HTTP/1.1\r\nHost: example.com\r\ncontent-type: text/html\r\nACCEPT: */*\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	a := req.get_header_value_slice('Content-Type') or { panic('Content-Type') }
	assert a.to_string(req.buffer) == 'text/html'
	b := req.get_header_value_slice('CONTENT-TYPE') or { panic('CONTENT-TYPE') }
	assert b.to_string(req.buffer) == 'text/html'
	c := req.get_header_value_slice('accept') or { panic('accept') }
	assert c.to_string(req.buffer) == '*/*'
	d := req.get_header_value_slice('host') or { panic('host') }
	assert d.to_string(req.buffer) == 'example.com'
}

fn test_get_header_prefix_does_not_false_match() {
	// 'Host' must not match 'Hostname'; the colon-follows check enforces it.
	buffer := 'GET / HTTP/1.1\r\nHostname: nope\r\nHost: real.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	h := req.get_header_value_slice('Host') or { panic('Host') }
	assert h.to_string(req.buffer) == 'real.com'
}

fn test_count_header() {
	buffer := 'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\nAccept: x\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	assert req.count_header('host') == 2
	assert req.count_header('Accept') == 1
	assert req.count_header('Missing') == 0
}

fn test_validate_http1_ok() {
	buffer := 'GET / HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	req.validate_http1() or { panic('valid request rejected: ${err}') }
}

fn test_validate_http1_missing_host() {
	// RFC 9112 §3.2: HTTP/1.1 without Host => 400.
	buffer := 'GET / HTTP/1.1\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	if _ := req.validate_http1() {
		assert false, 'missing Host must be rejected'
	}
}

fn test_validate_http1_duplicate_host() {
	buffer := 'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	if _ := req.validate_http1() {
		assert false, 'duplicate Host must be rejected'
	}
}

fn test_validate_http1_cl_te_conflict() {
	// RFC 9112 §6.1: Content-Length + Transfer-Encoding => reject (smuggling).
	buffer :=
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }
	if _ := req.validate_http1() {
		assert false, 'CL+TE must be rejected'
	}
}

// --- Request framing (pure, split-fuzz testable) ---------------------------

fn test_frame_no_body() {
	req := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert frame_request_length(req)! == req.len // complete, ends at \r\n\r\n
}

fn test_frame_zero_header() {
	req := 'GET / HTTP/1.1\r\n\r\n'.bytes()
	assert frame_request_length(req)! == req.len
}

fn test_frame_content_length() {
	req := 'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	assert frame_request_length(req)! == req.len
	// one byte short of the body => incomplete
	assert frame_request_length(req[..req.len - 1])! == -1
	// headers only => incomplete
	short := 'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n'.bytes()
	assert frame_request_length(short)! == -1
}

fn test_frame_chunked() {
	req :=
		'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n'.bytes()
	assert frame_request_length(req)! == req.len
	assert frame_request_length(req[..req.len - 1])! == -1 // missing final CRLF
}

// issue #104: Content-Length + Transfer-Encoding together must be REJECTED at
// the framing layer (400), not stall as "incomplete". The framer previously
// committed to chunked framing and, with a non-chunked body, returned -1 forever
// (stalling the connection until the read timeout) so the 400 never surfaced.
fn test_frame_cl_te_conflict_rejected() {
	// TE + CL with a plain (non-chunked) body: must be a hard 400, not -1.
	req :=
		'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello'.bytes()
	if _ := frame_request_length(req) {
		assert false, 'CL+TE must be rejected (#104)'
	} else {
		assert err.code() == 400, 'CL+TE must map to 400, got ${err.code()}'
	}
	// Header order must not matter, and it must reject as soon as the blank line
	// is seen — even before any body bytes arrive.
	no_body :=
		'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n'.bytes()
	if _ := frame_request_length(no_body) {
		assert false, 'CL+TE (no body yet) must be rejected (#104)'
	} else {
		assert err.code() == 400
	}
}

// issue #184: framings that hops can resolve differently must be REJECTED by
// the framer (400 + close), never resolved on its own: a non-chunked or
// obfuscated Transfer-Encoding framed as bodyless served the body as a second
// request; differing Content-Lengths framed by the last value while
// content_length() read the first; whitespace before the colon hid the field.
const ambiguous_heads = [
	// Transfer-Encoding whose final coding is not chunked (RFC 9112 §6.3).
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: identity\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: nonsense\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding:\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, gzip\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: xchunked\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunkedx\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked;x=1\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n',
	// A Transfer-Encoding line naming no coding: does it cancel the chunked?
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: \r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: ,\r\n\r\n',
	// chunked applied twice (RFC 9112 §6.1), in one line or across two.
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, chunked\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n',
	// Any Transfer-Encoding with Content-Length, not only chunked (§6.1, §6.3).
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: gzip, chunked\r\n\r\n',
	// Transfer-Encoding on HTTP/1.0 is faulty framing (RFC 9112 §6.1).
	'POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n',
	'POST / HTTP/1.0\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n',
	// Whitespace between the field-name and the colon (RFC 9112 §5.1).
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding : chunked\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding\t: chunked\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length : 5\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\ncontent-length\t: 5\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length : 5\r\n\r\n',
	// Repeated Content-Length with differing values, in either order (§6.3).
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 0\r\n\r\n',
	'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\ncontent-length: 6\r\n\r\n',
]

fn test_frame_ambiguous_framing_rejected() {
	for head in ambiguous_heads {
		// The head alone is enough: the verdict must not wait for body bytes
		// (waiting would stall the connection, the #104 failure mode).
		req := head.bytes()
		if got := frame_request_length(req) {
			assert false, 'must be rejected, framed to ${got}: ${head}'
		} else {
			assert err.code() == 400, 'must map to 400, got ${err.code()}: ${head}'
		}
		assert frame_request_length_lim_idx(req, 0, 0) == -400, head
		// A body (or a pipelined request after it) changes nothing.
		with_body := (head + '5\r\nhello\r\n0\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: a\r\n\r\n').bytes()
		assert frame_request_length_lim_idx(with_body, 0, 0) == -400, head
		// No split point may ever frame the message as complete.
		for split in 1 .. with_body.len {
			r := frame_request_length_lim_idx(with_body[..split], 0, 0)
			assert r == -1 || r == -400, 'prefix ${split} framed to ${r}: ${head}'
		}
	}
}

// The token-list reading must not reject what RFC 9112 accepts: chunked as the
// final coding, matched case-insensitively, with OWS around commas, empty list
// elements, and the codings spread over several field lines.
fn test_frame_transfer_encoding_list_accepted() {
	body := '5\r\nhello\r\n0\r\n\r\n'
	for te in [
		'Transfer-Encoding: chunked\r\n',
		'Transfer-Encoding: Chunked\r\n',
		'transfer-encoding: CHUNKED\r\n',
		'Transfer-Encoding: chunked \r\n',
		'Transfer-Encoding: gzip, chunked\r\n',
		'Transfer-Encoding: gzip,chunked\r\n',
		'Transfer-Encoding:  gzip \t,\t chunked\r\n',
		'Transfer-Encoding: , gzip,, chunked,\r\n',
		'Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n',
	] {
		req := ('POST / HTTP/1.1\r\nHost: a\r\n' + te + '\r\n' + body).bytes()
		assert frame_request_length(req)! == req.len, te
		assert frame_request_length(req[..req.len - 1])! == -1, te
	}
	// The version gate reads the request line's version, not its target.
	req := ('POST /HTTP/1.0 HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n' + body).bytes()
	assert frame_request_length(req)! == req.len
}

// An identical repeated Content-Length MAY be accepted (RFC 9110 §8.6): it
// frames by that one value, and content_length() reports the same value.
fn test_frame_identical_content_length_repeat_accepted() {
	for head in [
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\ncontent-length: 005\r\n\r\n',
	] {
		req := (head + 'hello').bytes()
		assert frame_request_length(req)! == req.len, head
		assert frame_request_length(req[..req.len - 1])! == -1, head
		decoded := decode_http_request(req)!
		assert decoded.content_length() == 5, head
		assert decoded.body.len == 5, head
	}
}

// Whitespace before the colon is rejected only on the framing fields, where it
// changes the message boundary; on any other field it is left to the
// app-level validator (examples/conformance), so the per-line cost stays nil.
fn test_frame_ws_before_colon_scope() {
	host := 'GET / HTTP/1.1\r\nHost : a\r\n\r\n'.bytes()
	assert frame_request_length(host)! == host.len
	// A longer field-name that starts with a framing name is a different field.
	other := 'GET / HTTP/1.1\r\nHost: a\r\nContent-Length-X : 5\r\nTransfer-Encodings: gzip\r\n\r\n'.bytes()
	assert frame_request_length(other)! == other.len
	// The sizing hint must not read a length out of the malformed line either.
	assert frame_expected_total('POST / HTTP/1.1\r\nContent-Length : 5\r\n\r\nhello'.bytes()) == -1
}

// issue #109: chunk-data MUST be followed by CRLF (RFC 9112 §7.1). A body where
// the data runs straight into the next token (no terminator) must be rejected
// 400, not framed to a bogus length that desyncs the connection.
fn test_frame_chunked_missing_terminator() {
	// `5\r\nhello0\r\n\r\n`: the 5-byte "hello" chunk is NOT followed by CRLF.
	req :=
		'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello0\r\n\r\n'.bytes()
	if _ := frame_request_length(req) {
		assert false, 'chunk-data without a CRLF terminator must be rejected (#109)'
	} else {
		assert err.code() == 400, 'missing chunk terminator must map to 400, got ${err.code()}'
	}
	// A correctly-terminated single chunk still frames exactly.
	ok :=
		'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n'.bytes()
	assert frame_request_length(ok)! == ok.len
}

// issue #185: the chunked framer and the trailer section / strict size lines.
const chunked_head = 'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'

// frame_chunked_code frames chunked_head + body and returns the result, or the
// negated error code (-400 / -413 / -431) when the framer rejects it.
fn frame_chunked_code(body string, max_header int, max_body int) int {
	return frame_request_length_lim((chunked_head + body).bytes(), max_header, max_body) or {
		-err.code()
	}
}

// A trailer section (RFC 9112 §7.1.2) is framed past, to its closing CRLF. The
// framer used to want that CRLF right after the last chunk, so a trailer field
// left the request "incomplete" forever (a hang with default Limits, a 408
// with a read timeout).
fn test_frame_chunked_trailer() {
	one := (chunked_head + '5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n').bytes()
	assert frame_request_length(one)! == one.len
	several := (chunked_head + '5\r\nhello\r\n0\r\nX-Checksum: abc\r\nX-Sig:\t"a, b" \r\n' +
		'Expires: Wed, 21 Oct 2015 07:28:00 GMT\r\nX-Empty:\r\n\r\n').bytes()
	assert frame_request_length(several)! == several.len
	// A trailer field the server must not act on is still just framed past.
	cl := (chunked_head + '5\r\nhello\r\n0\r\nContent-Length: 50\r\n\r\n').bytes()
	assert frame_request_length(cl)! == cl.len
	// The last chunk may carry an extension and leading zeros.
	ext := (chunked_head + '5\r\nhello\r\n000;x=1\r\nX-A: b\r\n\r\n').bytes()
	assert frame_request_length(ext)! == ext.len
	// Pipelined: only the first message, trailer included, is framed.
	next := 'GET /b HTTP/1.1\r\nHost: x\r\n\r\n'
	two := (one.bytestr() + next).bytes()
	assert frame_request_length(two)! == one.len
}

// The trailer section is bounded by max_header (431), like the header section,
// whether its oversized line is complete or still unterminated.
fn test_frame_chunked_trailer_limit() {
	big := '5\r\nhello\r\n0\r\nX-Pad: ' + 'a'.repeat(200) + '\r\n\r\n'
	assert frame_chunked_code(big, 128, 0) == -431
	unterminated := '5\r\nhello\r\n0\r\nX-Pad: ' + 'a'.repeat(200)
	assert frame_chunked_code(unterminated, 128, 0) == -431
	many := '5\r\nhello\r\n0\r\n' + 'X-A: b\r\n'.repeat(40) + '\r\n'
	assert frame_chunked_code(many, 128, 0) == -431
	// Under the limit it frames; 0 = unlimited.
	assert frame_chunked_code(big, 1024, 0) == chunked_head.len + big.len
	assert frame_chunked_code(big, 0, 0) == chunked_head.len + big.len
	// max_body still bounds the whole chunked body, trailer included (413).
	assert frame_chunked_code(big, 0, 64) == -413
	// The no-Result twin carries the same sentinel.
	t := frame_request_length_lim_idx((chunked_head + big).bytes(), 128, 0)
	assert t < -1 && -t == 431
}

// chunk-size = 1*HEXDIG [ chunk-ext ] CRLF (RFC 9112 §7.1). Each of these was
// framed before #185 (the first two as the LAST chunk); each is now a 400.
fn test_frame_chunked_strict_size_line() {
	bad := [
		'\r\n\r\n', // empty chunk-size
		';ext\r\n\r\n', // extension, no size
		';ext\r\nhello\r\n0\r\n\r\n',
		'5\nhello\r\n0\r\n\r\n', // bare LF ends the size line
		'5\rZZ\nhello\r\n0\r\n\r\n', // junk between CR and LF
		'5\rZZ\r\nhello\r\n0\r\n\r\n', // bare CR, then junk
		'5;a\rb\r\nhello\r\n0\r\n\r\n', // bare CR inside an extension
		'5;a\nhello\r\n0\r\n\r\n', // bare LF after an extension
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
	]
	for b in bad {
		assert frame_chunked_code(b, 0, 0) == -400, 'must be 400: ${b.bytes()}'
	}
}

// Trailer lines follow the same rules: CRLF line ends, field-line syntax.
fn test_frame_chunked_malformed_trailer() {
	bad := [
		'5\r\nhello\r\n0\r\n\n', // bare LF closes the trailer section
		'5\r\nhello\r\n0\r\nX-A: b\n\r\n', // bare LF ends a trailer line
		'5\r\nhello\r\n0\r\nX-A: b\rc\r\n\r\n', // bare CR in a value
		'5\r\nhello\r\n0\r\nX-A: b\r\r\nGET /s HTTP/1.1\r\nHost: x\r\n\r\n',
		'5\r\nhello\r\n0\r\nX-A: b\r\n c\r\n\r\n', // obs-fold
		'5\r\nhello\r\n0\r\nGET /s HTTP/1.1\r\n\r\n', // not a field-line
		'5\r\nhello\r\n0\r\n: b\r\n\r\n', // empty field-name
		'5\r\nhello\r\n0\r\nX-A : b\r\n\r\n', // SP before the colon
		'5\r\nhello\r\n0\r\nX-A: b\x00\r\n\r\n', // NUL in a value
	]
	for b in bad {
		assert frame_chunked_code(b, 0, 0) == -400, 'must be 400: ${b.bytes()}'
	}
}

// What stays accepted: extensions (RFC 9112 §7.1.1, incl. BWS and a quoted
// value), upper- and lower-case hex, leading zeros.
fn test_frame_chunked_allowed_shapes() {
	good := [
		'5;name=value\r\nhello\r\n0\r\n\r\n',
		'5;a;b=c;d="q"\r\nhello\r\n0\r\n\r\n',
		'5 ; a = "x \\" y\t" ;b\r\nhello\r\n0\r\n\r\n',
		'A\r\n0123456789\r\n0\r\n\r\n',
		'a\r\n0123456789\r\n0\r\n\r\n',
		'0005\r\nhello\r\n0;last\r\n\r\n',
		'0\r\n\r\n',
	]
	for g in good {
		assert frame_chunked_code(g, 0, 0) == chunked_head.len + g.len, 'must frame: ${g}'
	}
}

// Overflow hardening (found by adversarial review of the #109 change). V's `int`
// is 32-bit signed; a chunk-size or Content-Length that overflows it must be
// rejected 400, never wrapped: a wrap-to-negative chunk size made crlf_at go
// out of bounds (segfault under -prod's @[direct_array_access]); a wrap-to-zero
// (0x100000000) hijacked the size==0 terminating branch (smuggling desync); an
// overflowing Content-Length framed a present header as absent.
fn test_frame_chunk_size_overflow_negative() {
	// 0x80000000 = 2^31 wraps to a negative int without the cap.
	req := 'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n80000000\r\nAB'.bytes()
	if _ := frame_request_length(req) {
		assert false, 'overflowing chunk size must be rejected, not wrapped'
	} else {
		assert err.code() == 400
	}
}

fn test_frame_chunk_size_overflow_to_zero() {
	// 0x100000000 = 2^32 wraps to EXACTLY 0 without the cap → must NOT be treated
	// as a terminating chunk that frames the message early.
	req :=
		'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n100000000\r\n\r\nSMUGGLED'.bytes()
	if got := frame_request_length(req) {
		assert false, 'chunk size 0x100000000 must be rejected, framed to ${got} (smuggling)'
	} else {
		assert err.code() == 400
	}
}

fn test_frame_content_length_overflow() {
	// 2147483648 = 2^31 overflows a 32-bit int; must be rejected, not wrapped < 0.
	req := 'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 2147483648\r\n\r\n'.bytes()
	if _ := frame_request_length(req) {
		assert false, 'overflowing Content-Length must be rejected'
	} else {
		assert err.code() == 400
	}
}

fn test_frame_incomplete_request_line() {
	assert frame_request_length('GET / HTT'.bytes())! == -1
	assert frame_request_length('GET'.bytes())! == -1
}

fn test_frame_malformed_content_length() {
	req := 'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n'.bytes()
	if _ := frame_request_length(req) {
		assert false, 'non-numeric Content-Length must error'
	}
}

// issue #186: OWS around the Content-Length value is valid (RFC 9112 §5.1 +
// §6.2) and must frame, not 400. Same for Transfer-Encoding.
fn test_frame_content_length_with_ows() {
	for cl in ['Content-Length: 5 ', 'Content-Length:\t5', 'Content-Length: \t5\t ', 'Content-Length:5'] {
		req := 'POST /x HTTP/1.1\r\nHost: x\r\n${cl}\r\n\r\nhello'.bytes()
		assert frame_request_length_lim(req, 0, 0)! == req.len, cl
		assert frame_request_length_lim(req[..req.len - 1], 0, 0)! == -1, cl
		assert frame_expected_total(req[..req.len - 2]) == req.len, cl
	}
	te := 'POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:\tchunked \r\n\r\n5\r\nhello\r\n0\r\n\r\n'.bytes()
	assert frame_request_length(te)! == te.len
	// Only OWS is trimmed: a value that is all OWS is still an empty Content-Length.
	empty := 'POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: \t \r\n\r\n'.bytes()
	if _ := frame_request_length(empty) {
		assert false, 'an all-OWS Content-Length must be rejected'
	} else {
		assert err.code() == 400
	}
}

// issue #186: a bare LF in the head is answered 400 (RFC 9112 §2.2 lets a
// recipient choose; rejecting keeps vanilla from seeing a field line that another
// hop read as part of a value). Covers field lines, the request line and the
// blank line, and rejects as soon as the bare LF is buffered: not -1 (wait).
fn test_frame_bare_lf_rejected() {
	heads := [
		'GET / HTTP/1.1\r\nHost: a\r\nX-Foo: a\nX-Forwarded-For: 1.2.3.4\r\n\r\n',
		'GET / HTTP/1.1\nHost: a\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\n\nX: b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\nX-Foo: a\nX',
		'\nGET / HTTP/1.1\r\nHost: a\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nX-Foo: a\nContent-Length: 5\r\n\r\nhello',
	]
	for h in heads {
		got := frame_request_length_lim_idx(h.bytes(), 0, 0)
		assert got == frame_err_malformed, '${h.replace('\r', '\\r').replace('\n', '\\n')} framed to ${got}'
	}
	// frame_expected_total sizes the streamed-body path: it must not frame a
	// head the framer refuses.
	big := 'POST / HTTP/1.1\r\nHost: a\r\nX-Foo: a\nContent-Length: 100000\r\n\r\n'.bytes()
	assert frame_expected_total(big) == -1
}

// head_expects_100_continue detects `Expect: 100-continue` in a buffered head so
// the backend can prompt the client (RFC 9110 §10.1.1). Case-insensitive on both
// the field-name and the value; must not false-match another header or a request
// that merely mentions the token in a different field.
fn test_head_expects_100_continue() {
	// Present (exact) — head_len is the whole buffer (head only, no body yet).
	h1 := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()
	assert head_expects_100_continue(h1, h1.len)
	// Case-insensitive name + value.
	h2 := 'POST / HTTP/1.1\r\nHost: x\r\nEXPECT: 100-Continue\r\n\r\n'.bytes()
	assert head_expects_100_continue(h2, h2.len)
	// Absent.
	h3 := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n'.bytes()
	assert !head_expects_100_continue(h3, h3.len)
	// The token in a DIFFERENT header must not match.
	h4 := 'POST / HTTP/1.1\r\nHost: x\r\nX-Note: 100-continue please\r\n\r\n'.bytes()
	assert !head_expects_100_continue(h4, h4.len)
	// A prefix that hasn't reached the header yet: no false positive.
	assert !head_expects_100_continue('POST / HTTP/1.1\r\n'.bytes(), 17)
}

// Split-point fuzzing: the regression guard for the read-loop framing. For a
// full request, EVERY prefix shorter than the message reports incomplete (-1),
// and the exact full length reports complete. No sockets involved.
fn test_frame_split_fuzz() {
	requests := [
		'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
		'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world',
		'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n',
		// #185: extensions, a quoted value and a trailer section — no prefix may
		// be a 400 or framed early.
		'POST /t HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4;a="b;c"\r\nWiki\r\n0;z\r\nX-Checksum: abc\r\nX-B: c\r\n\r\n',
	]
	for r in requests {
		full := r.bytes()
		for split in 1 .. full.len {
			assert frame_request_length(full[..split])! == -1, 'prefix ${split}/${full.len} should be incomplete'
		}
		assert frame_request_length(full)! == full.len, 'full message should be complete'
	}
}

// Over-read (pipelined second request present): frame returns only the FIRST
// message's length, so the read loop knows where it ends.
fn test_frame_pipelined_returns_first() {
	two := 'GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	first := 'GET /a HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert frame_request_length(two)! == first.len
}

// --- Size limits (413 / 431) via frame_request_length_lim -------------------

fn test_frame_limit_body_413() {
	// Content-Length over the limit must be rejected with status 413, BEFORE
	// the body is buffered (here only headers are present).
	req := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\n'.bytes()
	if _ := frame_request_length_lim(req, 0, 1024) {
		assert false, 'over-limit body must be rejected'
	} else {
		assert err.code() == 413
	}
}

fn test_frame_limit_body_ok_when_under() {
	req := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc'.bytes()
	assert frame_request_length_lim(req, 0, 1024)! == req.len
}

fn test_frame_limit_header_431() {
	// A head larger than the limit, with no terminator yet, must yield 431.
	big := 'GET / HTTP/1.1\r\nX-Pad: ' + 'a'.repeat(2000) + '\r\n'
	if _ := frame_request_length_lim(big.bytes(), 64, 0) {
		assert false, 'over-limit header must be rejected'
	} else {
		assert err.code() == 431
	}
}

fn test_frame_limits_zero_is_unlimited() {
	// 0/0 must behave exactly like the unlimited framer.
	req := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	assert frame_request_length_lim(req, 0, 0)! == req.len
	assert frame_request_length(req)! == req.len
}

fn test_frame_expected_total() {
	// Full message: total == header end + Content-Length.
	full := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	assert frame_expected_total(full) == full.len

	// The key case: headers are complete but only part of the body has arrived.
	// The total must already be known so the read loop can pre-size in one alloc.
	partial := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\nhel'.bytes()
	assert frame_expected_total(partial) == (partial.len - 3) + 1000

	// Header section not yet terminated -> not determinable.
	no_end := 'POST /u HTTP/1.1\r\nContent-Length: 5\r\n'.bytes()
	assert frame_expected_total(no_end) == -1

	// Chunked body -> length unknown until the terminator.
	chunked := 'POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'.bytes()
	assert frame_expected_total(chunked) == -1

	// No Content-Length, no body -> nothing to pre-size against.
	nobody := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert frame_expected_total(nobody) == -1
}

// --- The no-Result hot-path twin frame_request_length_lim_idx -----------------
// The drain loops call this directly to skip !int boxing. It must agree with the
// Result wrapper: length >= 0 (complete), -1 (incomplete), or a frame_err_*
// sentinel = the negated HTTP status (-413 / -431 / -400).
fn test_frame_idx_complete_and_incomplete() {
	req := 'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert frame_request_length_lim_idx(req, 0, 0) == req.len
	assert frame_request_length_lim_idx(req[..req.len - 1], 0, 0) == -1 // missing last LF
	assert frame_request_length_lim_idx('GET'.bytes(), 0, 0) == -1
	// body via Content-Length
	withbody := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc'.bytes()
	assert frame_request_length_lim_idx(withbody, 0, 0) == withbody.len
}

fn test_frame_idx_error_sentinels() {
	// 413: declared body over the limit (sentinel -413, so -total == 413).
	over_body := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\n'.bytes()
	t413 := frame_request_length_lim_idx(over_body, 0, 1024)
	assert t413 < -1 && -t413 == 413
	// 431: header block over the limit.
	big := ('GET / HTTP/1.1\r\nX-Pad: ' + 'a'.repeat(2000) + '\r\n').bytes()
	t431 := frame_request_length_lim_idx(big, 64, 0)
	assert t431 < -1 && -t431 == 431
	// 400: malformed Content-Length.
	bad := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n'.bytes()
	t400 := frame_request_length_lim_idx(bad, 0, 0)
	assert t400 < -1 && -t400 == 400
}

// The wrapper must still surface the same .code()s after routing through _idx.
fn test_frame_wrapper_codes_match_idx() {
	over_body := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\n'.bytes()
	if _ := frame_request_length_lim(over_body, 0, 1024) {
		assert false, 'over-limit body must error'
	} else {
		assert err.code() == 413
	}
}
