module main

import http_server.http1_1.response

fn test_handle_request_get_home() {
	req_buffer := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res == http_ok_response
}

// quoted_etag_of derives the on-the-wire `"<16 hex>"` for a body — test
// scaffolding built from the same helper the controller uses.
fn quoted_etag_of(body string) string {
	etag := etag_hex(body.bytes())
	return '"' + unsafe { tos(&etag[0], 16) }.clone() + '"'
}

fn test_handle_request_get_user() {
	req_buffer := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	res := (serve(req_buffer) or { panic(err) }).bytestr()
	assert res.contains('HTTP/1.1 200 OK')
	assert res.contains('ETag: ${quoted_etag_of('123')}') // quoted per RFC 9110 §8.8.3
	assert res.contains('Content-Length: 3')
	assert res.ends_with('\r\n\r\n123')
}

fn test_conditional_get_roundtrip() {
	// Fresh cache: If-None-Match with the current ETag -> 304, no body.
	fresh :=
		'GET /user/123 HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: ${quoted_etag_of('123')}\r\n\r\n'.bytes()
	res := serve(fresh) or { panic(err) }
	assert res == not_modified_response
	// Stale cache: a different ETag must NOT match -> full 200.
	stale :=
		'GET /user/123 HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: "0000000000000000"\r\n\r\n'.bytes()
	res2 := (serve(stale) or { panic(err) }).bytestr()
	assert res2.contains('200 OK')
	assert res2.ends_with('123')
}

fn test_handle_request_post_user() {
	req_buffer := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res == http_created_response
}

fn test_handle_request_bad_request() {
	req_buffer := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res == response.tiny_bad_request_response
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	handle_request(req, -1, mut out)!
	return out
}
