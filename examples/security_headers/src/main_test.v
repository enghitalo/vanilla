module main

// SOLUTION: pure handler-wrapper test — works today.
// Demonstrates testing the COMPOSITION pattern: assert the wrapper injects the
// hardening headers into whatever the inner handler returned, in the right
// place (after the status line, before the body).
import http_server.core

fn test_wrapper_injects_all_headers() {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()

	assert out.contains('Strict-Transport-Security: max-age=')
	assert out.contains("Content-Security-Policy: default-src 'self'")
	assert out.contains('X-Frame-Options: DENY')
	assert out.contains('X-Content-Type-Options: nosniff')
	assert out.contains('Referrer-Policy:')
	assert out.contains('Permissions-Policy:')
}

fn test_status_line_and_body_preserved() {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.starts_with('HTTP/1.1 200 OK\r\n') // status line still first
	assert out.contains('<h1>secure</h1>') // body intact
	// headers go between status line and the body
	hsts_at := out.index('Strict-Transport-Security') or { -1 }
	body_at := out.index('<h1>') or { -1 }
	assert hsts_at > 0 && body_at > hsts_at
}

// serve runs a request through the security-headers wrapper and returns the
// response bytes, adapting the raw-handler contract for the assertions.
fn serve(req []u8) []u8 {
	wrapped := with_security_headers(app)
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert wrapped(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}
