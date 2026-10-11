module main

import core
import http1_1.response

fn test_simple_without_init_the_server() {
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request3 := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	request4 := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

	request2_response :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'

	assert serve(request1).bytestr() == http_ok_response
	assert serve(request2).bytestr() == request2_response
	assert serve(request3).bytestr() == http_created_response
	assert serve(request4) == response.tiny_bad_request_response
}

// Every route runs 20k times through one reused buffer, as a worker would
// serve them; the collector's lifetime allocation counter must not move.
// (Under `-gc none`, vanilla's epoll build, an allocation here would be a
// permanent leak.)
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n',
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

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
	return out
}
