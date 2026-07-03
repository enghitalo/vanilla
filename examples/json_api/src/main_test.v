module main

import http_server.http1_1.request_parser

// SOLUTION: pure body-parsing unit tests + raw-request E2E through serve().
// JSON decode and multipart parsing are pure over the body bytes, and the
// handler is a pure function of the raw request bytes, so everything here runs
// without a socket (BEST_PRACTICES §9).
//
// Body FRAMING (a body split across TCP segments) is the core's job and is
// regression-tested there: request_parser_test.v's test_frame_split_fuzz feeds
// the framer EVERY prefix of a framed request and asserts none of them parses
// as complete — the old truncation bug cannot come back silently. The residual
// core limitation is fragmentation across epoll readiness bursts (EAGAIN
// mid-message), which is rejected with an error — never delivered truncated.

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	handle(req, -1, mut out)!
	return out
}

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

// raw_post frames a request with a correct Content-Length (`${}` is fine in
// test scaffolding — it never runs in the server).
fn raw_post(path string, content_type string, body string) string {
	return 'POST ${path} HTTP/1.1\r\nContent-Type: ${content_type}\r\nContent-Length: ${body.len}\r\n\r\n${body}'
}

// ----- unit tests: sub-handlers and the multipart scanner --------------------

fn test_create_user_json() {
	req := mkreq(raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}'))
	mut out := []u8{}
	create_user_json(req, mut out)
	res := out.bytestr()
	assert res.contains('201 Created')
	assert res.contains('"name":"Ada"')
	assert res.contains('"email":"ada@example.com"')
}

fn test_invalid_json_is_400() {
	req := mkreq(raw_post('/users', 'application/json', '{ x'))
	mut out := []u8{}
	create_user_json(req, mut out)
	res := out.bytestr()
	assert res.contains('400 Bad Request')
	assert res.contains('invalid JSON')
}

fn test_missing_fields_is_400() {
	req := mkreq(raw_post('/users', 'application/json', '{}'))
	mut out := []u8{}
	create_user_json(req, mut out)
	res := out.bytestr()
	assert res.contains('400 Bad Request')
	assert res.contains('name and email are required')
}

fn test_parse_multipart() {
	body := '--boundary\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nhello\r\n--boundary--\r\n'
	parts := parse_multipart(body.bytes(), 'boundary'.bytes())
	assert parts.len == 1
	assert parts[0].name == 'file'
	assert parts[0].filename == 'a.txt'
	assert parts[0].content.bytestr() == 'hello'
}

fn test_parse_multipart_edges() {
	// Preamble, a field part without filename, an empty file part, closing '--'.
	body := 'preamble ignored\r\n--b\r\nContent-Disposition: form-data; name="note"\r\n\r\ntext value\r\n--b\r\nContent-Disposition: form-data; name="empty"; filename="e.bin"\r\n\r\n\r\n--b--\r\n'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 2
	assert parts[0].name == 'note'
	assert parts[0].filename == ''
	assert parts[0].content.bytestr() == 'text value'
	assert parts[1].name == 'empty'
	assert parts[1].filename == 'e.bin'
	assert parts[1].content.len == 0
}

fn test_parse_multipart_boundary_at_buffer_end() {
	// Closing delimiter flush at the end of the buffer, no trailing CRLF.
	body := '--b\r\nContent-Disposition: form-data; name="f"; filename="x"\r\n\r\ndata\r\n--b--'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 1
	assert parts[0].filename == 'x'
	assert parts[0].content.bytestr() == 'data'
}

fn test_parse_multipart_name_never_matches_filename_tail() {
	// Whole-attribute match: with only filename= present, name must stay ''.
	body := '--b\r\nContent-Disposition: form-data; filename="a.txt"\r\n\r\nz\r\n--b--\r\n'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 1
	assert parts[0].name == ''
	assert parts[0].filename == 'a.txt'
}

// ----- raw-request E2E through the full handler ------------------------------

fn test_e2e_create_user() ! {
	req := raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}')
	out := serve(req.bytes())!.bytestr()
	assert out.contains('201 Created')
	assert out.contains('"id":1')
	assert out.contains('"email":"ada@example.com"')
}

fn test_e2e_invalid_json_is_400() ! {
	out := serve(raw_post('/users', 'application/json', '{ x').bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('invalid JSON')
}

fn test_e2e_upload_multipart() ! {
	body := '--XYZ\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nhello\r\n--XYZ--\r\n'
	req := raw_post('/upload', 'multipart/form-data; boundary=XYZ', body)
	out := serve(req.bytes())!.bytestr()
	assert out.contains('200 OK')
	assert out.contains('"field":"file"')
	assert out.contains('"filename":"a.txt"')
	assert out.contains('"size":5')
}

fn test_e2e_upload_boundary_param_case_insensitive() ! {
	// RFC 2045: parameter names are case-insensitive — Boundary= must work.
	body := '--XYZ\r\nContent-Disposition: form-data; name="f"; filename="b"\r\n\r\nok\r\n--XYZ--\r\n'
	req := raw_post('/upload', 'multipart/form-data; Boundary=XYZ', body)
	out := serve(req.bytes())!.bytestr()
	assert out.contains('200 OK')
	assert out.contains('"size":2')
}

fn test_e2e_upload_missing_content_type_is_400() ! {
	req := 'POST /upload HTTP/1.1\r\nContent-Length: 2\r\n\r\nxx'
	out := serve(req.bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('missing Content-Type')
}

fn test_e2e_upload_missing_boundary_is_400() ! {
	req := raw_post('/upload', 'multipart/form-data', 'xx')
	out := serve(req.bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('missing multipart boundary')
}

fn test_e2e_unknown_route_is_404() ! {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('404 Not Found')
	assert out.contains('"error":"not found"')
}

fn test_e2e_malformed_request_errors() {
	// Malformed input must surface as a handler error, never a response.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
}
