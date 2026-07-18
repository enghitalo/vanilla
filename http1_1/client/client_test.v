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
	assert frame_response('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'.bytes()) == err_chunked
	assert frame_response('HTTP/1.1 200 OK\r\nDate: x\r\n\r\n'.bytes()) == err_until_close
	assert frame_response('ICY 200 OK\r\n\r\n'.bytes()) == err_malformed
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n'.bytes()) == err_malformed
	assert frame_response('HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n'.bytes()) == err_malformed
}

fn test_case_insensitive_content_length() {
	buf := 'HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\nabc'.bytes()
	assert frame_response(buf) == buf.len
}
