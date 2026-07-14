module main

// Handler-level conformance tests: feed raw request bytes to handle_request and
// assert the status line, mirroring the checks an external probe (h1spec) makes.
// This runs the SAME logic the probe exercises, but without a socket — so it is
// deterministic and immune to the backend half-close behavior (see README).

fn status_of(req string) int {
	mut out := []u8{}
	handle_request(req.bytes(), -1, mut out) or { return -1 }
	// Parse "HTTP/1.1 NNN ..." → NNN.
	if out.len < 12 {
		return 0
	}
	s := out.bytestr()
	parts := s.split(' ')
	if parts.len < 2 {
		return 0
	}
	return parts[1].int()
}

fn test_simple_get_accepted() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n') == 200
}

fn test_post_with_content_length() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello') == 200
}

fn test_unknown_path_404() {
	assert status_of('GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n') == 404
}

fn test_invalid_version_rejected() {
	s := status_of('GET / HTTP/2.0\r\nHost: localhost\r\n\r\n')
	assert s == 400 || s == 505
}

fn test_missing_host_rejected() {
	assert status_of('GET / HTTP/1.1\r\n\r\n') == 400
}

fn test_duplicate_host_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\nHost: example.com\r\n\r\n') == 400
}

fn test_invalid_host_value_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: bad host\r\n\r\n') == 400
}

fn test_invalid_header_name_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\nBad Header: value\r\n\r\n') == 400
}

fn test_obsolete_folding_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\n  continued\r\n\r\n') == 400
}

fn test_space_before_colon_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost : localhost\r\n\r\n') == 400
}

fn test_null_in_header_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: local\x00host\r\n\r\n') == 400
}

fn test_duplicate_content_length_rejected() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nhello!!') == 400
}

fn test_cl_te_conflict_rejected() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 400
}

fn test_unknown_transfer_coding_rejected() {
	s := status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: nonsense\r\n\r\nhello')
	assert s == 400 || s == 501
}

fn test_chunked_not_final_rejected() {
	// "chunked, gzip" — chunked is not the final coding.
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 400
}

fn test_valid_chunked_accepted() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 200
}

fn test_head_has_no_body() {
	mut out := []u8{}
	handle_request('HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), -1, mut out) or {
		assert false, 'HEAD handler errored: ${err}'
		return
	}
	s := out.bytestr()
	idx := s.index('\r\n\r\n') or {
		assert false, 'no header terminator in HEAD response'
		return
	}
	body := s[idx + 4..]
	assert body.len == 0, 'HEAD response must have empty body, got ${body.len} bytes'
}

fn test_unsupported_method_405() {
	assert status_of('DELETE / HTTP/1.1\r\nHost: localhost\r\n\r\n') == 405
}

fn test_error_response_is_self_delimiting() {
	// Every 400 must carry Content-Length (or chunked / Connection: close).
	mut out := []u8{}
	handle_request('get / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), -1, mut out) or {}
	s := out.bytestr().to_lower()
	assert s.contains('content-length:') || s.contains('transfer-encoding: chunked')
		|| s.contains('connection: close')
}

fn test_connection_close_honored() {
	mut out := []u8{}
	handle_request('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes(), -1, mut
		out) or {}
	assert out.bytestr().to_lower().contains('connection: close')
}
