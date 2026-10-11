module main

import os
import core

// The handler, called directly: TLS is the server's business, so these run in
// any build (no `-d vanilla_tls`, no sockets). https_e2e_test.v serves it over
// TLS. The expected bytes are spelled out rather than read from main.v's
// consts, so a change to a response has to change this test too.

const want_hello = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, HTTPS!'

fn test_get_root_says_hello() {
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n') == want_hello
	// The query string is not part of the path.
	assert serve('GET /?lang=en HTTP/1.1\r\nHost: localhost\r\n\r\n') == want_hello
}

fn test_head_root_has_the_headers_and_no_body() {
	assert serve('HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n') == want_hello.all_before('Hello, HTTPS!')
}

fn test_other_methods_on_root_get_405_with_allow() {
	for method in ['POST', 'PUT', 'DELETE', 'BREW'] {
		got := serve('${method} / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n')
		assert got.starts_with('HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\n'), '${method}: ${got}'
	}
}

fn test_other_paths_get_404() {
	for path in ['/hello', '//', '/index.html', '/a/b'] {
		got := serve('GET ${path} HTTP/1.1\r\nHost: localhost\r\n\r\n')
		assert got == 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n', '${path}: ${got}'
	}
}

// The handler APPENDS: a response already in `out` (an earlier pipelined
// request in the same batch) must survive untouched.
fn test_appends_after_existing_bytes() {
	mut out := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	mut event_loop := core.EventLoop{}
	assert route('GET / HTTP/1.1\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .done
	assert out.bytestr() == 'HTTP/1.1 204 No Content\r\n\r\n' + want_hello
}

// 20k requests through one reused buffer, as a worker serves them: the
// collector's lifetime allocation counter must not move (under `-gc none`,
// vanilla's production build, an allocation here would be a permanent leak).
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
			'HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
			'POST / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
			'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
		]
		mut out := []u8{cap: 256}
		mut event_loop := core.EventLoop{}
		for req in reqs {
			route(req, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for i in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			route(reqs[i % reqs.len], mut out, -1, unsafe { nil }, mut event_loop)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds} requests'
	}
}

// load_tls refuses half a certificate: a key without its chain (or the other
// way round) is a configuration mistake, not a reason to fall back to a
// self-signed identity.
fn test_load_tls_needs_both_cert_and_key() {
	saved_cert := os.getenv_opt('HTTPS_CERT')
	saved_key := os.getenv_opt('HTTPS_KEY')
	os.setenv('HTTPS_CERT', '/nonexistent/cert.pem', true)
	os.unsetenv('HTTPS_KEY')
	defer {
		restore_env('HTTPS_CERT', saved_cert)
		restore_env('HTTPS_KEY', saved_key)
	}
	load_tls('certs') or {
		assert err.msg().contains('both HTTPS_CERT and HTTPS_KEY'), err.msg()
		return
	}
	assert false, 'load_tls accepted HTTPS_CERT without HTTPS_KEY'
}

// restore_env puts back a variable the test changed: its old value, or unset.
fn restore_env(name string, saved ?string) {
	if v := saved {
		os.setenv(name, v, true)
	} else {
		os.unsetenv(name)
	}
}

// serve runs the handler on one request and returns what it appended.
fn serve(req string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert route(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out.bytestr()
}
