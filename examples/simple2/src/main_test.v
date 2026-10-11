module main

import core
import http1_1.response

fn test_handle_request_get_home() {
	req_buffer := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer).bytestr() == http_ok_response
}

fn test_handle_request_get_users() {
	req_buffer := 'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer).bytestr() == http_ok_response
}

fn test_handle_request_get_user() {
	req_buffer := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	assert serve(req_buffer) == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
}

fn test_handle_request_post_user() {
	req_buffer := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req_buffer).bytestr() == http_created_response
}

// An unmatched method or path gets the 404, and the handler returns .done:
// the connection stays open, as the 404's `Connection: keep-alive` says.
fn test_handle_request_unknown_method() {
	req_buffer := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	step, got := serve_step(req_buffer)
	assert step == .done
	assert got.bytestr() == http_not_found_response
}

fn test_handle_request_get_unknown_path() {
	req_buffer := 'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	step, got := serve_step(req_buffer)
	assert step == .done
	assert got.bytestr() == http_not_found_response
}

fn test_handle_request_post_unknown_path() {
	req_buffer := 'POST /nope HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	step, got := serve_step(req_buffer)
	assert step == .done
	assert got.bytestr() == http_not_found_response
}

// The route is the path up to the first '?': the query neither reaches the id
// nor stops `/`, `/users` and `/user` from matching.
fn test_handle_request_query_is_not_routed() {
	assert serve('GET /user/7?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n7'.bytes()
	assert serve('GET /?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()).bytestr() == http_ok_response
	assert serve('GET /users?page=2 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()).bytestr() == http_ok_response
	assert serve('POST /user?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()).bytestr() == http_created_response
}

// GET /user/ with an EMPTY id is a 404: the router requires at least one id
// byte after the '/user/' prefix (the same guard that keeps the vbytes view
// non-empty), and it checks the path without its query, so `/user/?x=1` is
// a 404 too.
fn test_handle_request_get_user_empty_id() {
	for r in [
		'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'GET /user/?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n',
	] {
		step, got := serve_step(r.bytes())
		assert step == .done, r
		assert got.bytestr() == http_not_found_response, r
	}
}

// A truncated head (no CRLF terminator at all) is rejected by decode_into —
// the handler appends the canned 400 and returns .close so the runtime
// flushes it and drops the connection.
fn test_handle_request_malformed_head() {
	req_buffer := 'GET / HTTP/1.1'.bytes()
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle_request(req_buffer, mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
}

// Every route runs 20k times through one reused buffer, as a worker would
// serve them; the collector's lifetime allocation counter must not move.
// (Under `-gc none`, vanilla's epoll build, an allocation here would be a
// permanent leak.) The 404s and the malformed head are routes too.
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/7?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET/HTTP/1.1\r\nHost: localhost\r\n\r\n', // malformed: 400 + .close
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	_, out := serve_step(req)
	return out
}

// serve_step is serve plus the core.Step the handler returned (.done keeps
// the connection open, .close closes it after the response).
fn serve_step(req []u8) (core.Step, []u8) {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	step := handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
	return step, out
}
