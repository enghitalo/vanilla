module main

import core
import http1_1.response

fn test_handle_request_get_home() {
	req_buffer := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res.bytestr() == http_ok_response
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
	assert res.contains('Access-Control-Expose-Headers: ETag') // front-end reads it cross-origin
	assert res.ends_with('\r\n\r\n123')
}

fn test_conditional_get_roundtrip() {
	// Fresh cache: If-None-Match with the current ETag -> 304, no body.
	fresh :=
		'GET /user/123 HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: ${quoted_etag_of('123')}\r\n\r\n'.bytes()
	res := serve(fresh) or { panic(err) }
	assert res.bytestr() == not_modified_response
	// Stale cache: a different ETag must NOT match -> full 200.
	stale :=
		'GET /user/123 HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: "0000000000000000"\r\n\r\n'.bytes()
	res2 := (serve(stale) or { panic(err) }).bytestr()
	assert res2.contains('200 OK')
	assert res2.ends_with('123')
}

fn test_cors_preflight_for_conditional_get() {
	req_buffer :=
		'OPTIONS /user/1 HTTP/1.1\r\nHost: localhost:3000\r\nOrigin: http://localhost:4001\r\nAccess-Control-Request-Method: GET\r\nAccess-Control-Request-Headers: if-none-match\r\n\r\n'.bytes()
	res := (serve(req_buffer) or { panic(err) }).bytestr()
	assert res == preflight_response
}

fn test_handle_request_post_user() {
	req_buffer := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res.bytestr() == http_created_response
}

fn test_handle_request_bad_request() {
	req_buffer := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	res := serve(req_buffer) or { panic(err) }
	assert res == response.tiny_bad_request_response
}

// Every route, the 200 and the 304 included, runs 20k times through one
// reused buffer, as a worker would serve them; the collector's lifetime
// allocation counter must not move. (Under `-gc none`, vanilla's epoll build,
// an allocation here would be a permanent leak.)
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/123 HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: ${quoted_etag_of('123')}\r\n\r\n',
			'OPTIONS /user/1 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
			'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n',
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

// serve adapts the unified-handler contract (writes into a caller-owned buffer)
// to the return-a-buffer shape the assertions expect; a .close step maps to an
// error, mirroring the old error-raising contract.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle_request(req, mut out, -1, unsafe { nil }, mut event_loop) == .close {
		return error('handler closed the connection')
	}
	return out
}
