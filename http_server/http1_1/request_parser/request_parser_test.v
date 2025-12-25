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
