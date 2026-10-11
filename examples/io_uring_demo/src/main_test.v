module main

import core

// The demo is about the backend (io_uring where the kernel allows it); the
// handler is the same on every backend, so it is tested in-process here and
// runs on every OS in CI. It never parses: whatever arrives gets the one
// response, spelled out below so a change to it has to change this test too.

const want_hello = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'

fn test_get_root_is_hello_world() {
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) == want_hello.bytes()
}

fn test_any_request_gets_the_same_response() {
	for req in [
		'POST /anything?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
		'HEAD /nope HTTP/1.1\r\nHost: localhost\r\n\r\n',
		'GARBAGE\r\n\r\n',
		'',
	] {
		assert serve(req.bytes()) == want_hello.bytes(), 'request: ${req}'
	}
}

// The handler APPENDS: a response already in `out` (an earlier pipelined
// request in the same batch) must survive untouched.
fn test_appends_after_existing_bytes() {
	mut out := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	mut event_loop := core.EventLoop{}
	assert handle_request('GET / HTTP/1.1\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut
		event_loop) == .done
	assert out.bytestr() == 'HTTP/1.1 204 No Content\r\n\r\n' + want_hello
}

// 20k requests through one reused buffer, as a worker serves them, must not
// move the collector's lifetime allocation counter. (Under `-gc none`,
// vanilla's production build, an allocation here would be a permanent leak:
// the handler used to copy a `.bytes()` literal per request.)
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		req := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		handle_request(req, mut out, -1, unsafe { nil }, mut event_loop) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds} requests'
	}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle_request(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}
