module main

import core
import http1_1.response

// SOLUTION: pure handler test — works today.
// CORS is header logic, so the preflight + allowlist behavior is fully unit
// testable without a browser or server.

fn test_allowlist() {
	assert origin_allowed('http://localhost:5173')
	assert !origin_allowed('https://evil.com')
}

fn test_preflight_allowed_origin() {
	req :=
		'OPTIONS /api HTTP/1.1\r\nOrigin: http://localhost:5173\r\nAccess-Control-Request-Method: POST\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('204 No Content')
	assert out.contains('Access-Control-Allow-Origin: http://localhost:5173')
	assert out.contains('Access-Control-Allow-Methods:')
	assert out.contains('Access-Control-Max-Age:')
}

fn test_preflight_forbidden_origin() {
	req := 'OPTIONS /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('403 Forbidden')
}

fn test_simple_request_echoes_allowed_origin() {
	req := 'GET /api HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('Access-Control-Allow-Origin: https://app.example.com')
	// SECURITY invariant: never the wildcard `*` when credentials are allowed.
	assert !out.contains('Access-Control-Allow-Origin: *')
}

fn test_simple_request_disallowed_origin_gets_no_cors() {
	// The server still serves the resource — the missing CORS grant is what
	// makes the BROWSER block the cross-origin read.
	req := 'GET /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert !out.contains('Access-Control-Allow-Origin')
	assert !out.contains('Access-Control-Allow-Credentials')
}

fn test_simple_request_without_origin() {
	// Same-origin (or non-browser) request: plain response, zero CORS headers.
	req := 'GET /api HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('{"ok":true}')
	assert !out.contains('Access-Control-Allow-Origin')
}

fn test_every_variant_carries_vary_origin() {
	// The response depends on Origin, so a shared cache must key on it for
	// EVERY variant — the plain one included, or a cache can serve the plain
	// variant to an allowed origin (no Access-Control-Allow-Origin => blocked).
	for c in [preflight_tail, ok_cors_tail, resp_ok_plain, resp_403] {
		assert c.contains('\r\nVary: Origin\r\n')
	}
	for raw in [
		'OPTIONS /api HTTP/1.1\r\nOrigin: http://localhost:5173\r\n\r\n', // 204 preflight
		'OPTIONS /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n', // 403 preflight
		'GET /api HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n', // 200 + CORS
		'GET /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n', // 200 plain
		'GET /api HTTP/1.1\r\nHost: x\r\n\r\n', // 200 plain, no Origin
	] {
		out := serve(raw.bytes()).bytestr()
		assert out.contains('\r\nVary: Origin\r\n'), out
	}
}

// Every variant — allowed and refused preflights, simple requests with an
// allowed, a refused or no Origin — runs 20k times through one reused buffer,
// as a worker would serve them; the collector's lifetime allocation counter
// must not move. (Under `-gc none`, vanilla's production build, an allocation
// here would be a permanent leak.)
fn test_requests_allocate_nothing() {
	$if gcboehm ? {
		reqs := [
			'OPTIONS /api HTTP/1.1\r\nOrigin: http://localhost:5173\r\n\r\n',
			'OPTIONS /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n',
			'GET /api HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n',
			'GET /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n',
			'GET /api HTTP/1.1\r\nHost: x\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

fn test_malformed_request_errors() {
	// Malformed input gets the canned 400 and the connection is closed.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req, mut out, -1, unsafe { nil }, mut event_loop)
	return out
}
