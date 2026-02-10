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
	// HTTP/1.0 does not require Host header
	// But I don't want to support HTTP/1.0 so it is a error now :)
	buffer := 'POST /api/resource HTTP/1.0\r\n\r\n'.bytes()
	mut has_error := false
	req := decode_http_request(buffer) or {
		has_error = true
		assert err.msg() == "Missing header-body delimiter. Non-header HTTP/1.0 aren't supported."
		return
	}
	assert has_error, 'Expected error for HTTP/1.0 request without Host header'

	assert req.method.to_string(req.buffer) == 'POST'
	assert req.path.to_string(req.buffer) == '/api/resource'
	assert req.version.to_string(req.buffer) == 'HTTP/1.0'
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
	// Request that never finishes headers
	buffer := 'GET / HTTP/1.1\r\nHost: example.com\r\n'.bytes()
	mut has_error := false
	req := decode_http_request(buffer) or {
		has_error = true
		assert err.msg() == "Missing header-body delimiter. Non-header HTTP/1.0 aren't supported."
		return
	}
	assert has_error, 'Expected error for missing header-body delimiter'
	// Based on our implementation, if no \r\n\r\n is found,
	// body should be empty and headers go to the end.
	assert req.body.len == 0
	assert req.header_fields.to_string(req.buffer) == 'Host: example.com'
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
