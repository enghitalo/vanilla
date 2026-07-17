module main

import core
import http1.response

fn test_handle_request_get_home() {
	req_buffer := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == http_ok_response
}

fn test_handle_request_get_users() {
	req_buffer := 'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == http_ok_response
}

fn test_handle_request_get_user() {
	req_buffer := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
}

fn test_handle_request_post_user() {
	req_buffer := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req_buffer) == http_created_response
}

fn test_handle_request_bad_request() {
	req_buffer := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == response.tiny_bad_request_response
}

fn test_handle_request_get_unknown_path() {
	req_buffer := 'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == response.tiny_bad_request_response
}

fn test_handle_request_post_unknown_path() {
	req_buffer := 'POST /nope HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req_buffer) == response.tiny_bad_request_response
}

// GET /user/ with an EMPTY id is a 400: the router requires at least one id
// byte after the '/user/' prefix (the same guard that keeps the vbytes view
// non-empty). Before the byte-discipline rewrite this returned 200 with
// Content-Length: 0 — the 400 is intentional and pinned here.
fn test_handle_request_get_user_empty_id() {
	req_buffer := 'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == response.tiny_bad_request_response
}

// A truncated head (no CRLF terminator at all) is a parse error from
// decode_http_request — the handler appends the canned 400 and returns .close
// so the runtime flushes it and drops the connection.
fn test_handle_request_malformed_head() {
	req_buffer := 'GET / HTTP/1.1'.bytes()
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle_request(req_buffer, mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
	return out
}
