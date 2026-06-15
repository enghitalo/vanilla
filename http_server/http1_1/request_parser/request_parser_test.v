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
	// stays strict-but-not-inventive (Invariant 3).
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
	decode_http_request(buffer) or {
		has_error = true
		assert err.msg() == 'Missing CR'
	}
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
	decode_http_request(buffer) or {
		has_error = true
		assert err.msg() == 'Missing header-body delimiter (no blank line terminating the header section)'
	}
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

fn test_get_query_slice_special_characters() {
	buffer := 'GET /api?token=abc-123_xyz HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := decode_http_request(buffer) or { panic(err) }

	token_slice := req.get_query_slice('token'.bytes()) or { panic('Query parameter not found') }
	assert token_slice.to_string(req.buffer) == 'abc-123_xyz'
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

// --- Phase 0: RFC conformance gates ---------------------------------------

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

// --- Phase 1: request framing (pure, split-fuzz testable) ------------------

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

// Split-point fuzzing: the regression guard for the read-loop framing. For a
// full request, EVERY prefix shorter than the message reports incomplete (-1),
// and the exact full length reports complete. No sockets involved.
fn test_frame_split_fuzz() {
	requests := [
		'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
		'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world',
		'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n',
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

// --- Phase 2: size limits (413 / 431) via frame_request_length_lim ----------

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
