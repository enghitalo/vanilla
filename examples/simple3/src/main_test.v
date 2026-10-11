module main

import core
import http1_1.response

// A request line with no spaces: the server frames it (the head ends in
// CRLFCRLF), so it reaches the handler, and decode_into rejects it.
const malformed_request = 'GET/HTTP/1.1\r\nHost: localhost\r\n\r\n'

fn test_simple_without_init_the_server() {
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request3 := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	request4 := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

	request2_response :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'

	app := App{}

	assert serve(app, request1).bytestr() == http_ok_response
	assert serve(app, request2).bytestr() == request2_response
	assert serve(app, request3).bytestr() == http_created_response
	assert serve(app, request4).bytestr() == http_not_found_response
}

// A method or path no route matches gets the 404, and the handler returns
// .done: the connection stays open, as the 404's `Connection: keep-alive`
// says.
fn test_unmatched_route_is_404_and_keeps_the_connection() {
	app := App{}
	for r in [
		'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'PUT /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
		'POST /nope HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
	] {
		step, got := serve_step(app, r.bytes())
		assert step == .done, r
		assert got.bytestr() == http_not_found_response, r
	}
}

// The route is the path up to the first '?': the query neither reaches the id
// nor stops `/` and `/user` from matching.
fn test_query_is_not_part_of_the_route() {
	app := App{}
	assert serve(app, 'GET /user/7?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()).bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n7'
	assert serve(app, 'GET /?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()).bytestr() == http_ok_response
	assert serve(app, 'POST /user?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()).bytestr() == http_created_response
}

// `/user/` with no id byte is not the `/user/<id>` route, query or not.
fn test_empty_user_id_is_404() {
	app := App{}
	for r in [
		'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'GET /user/?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n',
	] {
		step, got := serve_step(app, r.bytes())
		assert step == .done, r
		assert got.bytestr() == http_not_found_response, r
	}
}

// A head decode_into rejects gets the library's canned 400 (`Connection:
// close`) and .close, so the server closes the connection after sending it.
fn test_malformed_head_is_400_and_closes() {
	step, got := serve_step(App{}, malformed_request.bytes())
	assert step == .close
	assert got == response.tiny_bad_request_response
}

// Every route runs 20k times through one reused buffer, as a worker would
// serve them; the collector's lifetime allocation counter must not move.
// (Under `-gc none`, vanilla's epoll build, an allocation here would be a
// permanent leak.) The 404s and the malformed head are routes too.
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		app := App{}
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/7?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			malformed_request,
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			app.handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				app.handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-buffer shape the assertions expect.
fn serve(app App, req []u8) []u8 {
	_, out := serve_step(app, req)
	return out
}

// serve_step is serve plus the core.Step the handler returned (.done keeps
// the connection open, .close closes it after the response).
fn serve_step(app App, req []u8) (core.Step, []u8) {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	step := app.handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
	return step, out
}
