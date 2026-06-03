module main

// SOLUTION: pure handler-wrapper test — works today.
// Demonstrates testing the COMPOSITION pattern: assert the wrapper injects the
// hardening headers into whatever the inner handler returned, in the right
// place (after the status line, before the body).

fn test_wrapper_injects_all_headers() ! {
	wrapped := with_security_headers(app)
	out := wrapped('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1)!.bytestr()

	assert out.contains('Strict-Transport-Security: max-age=')
	assert out.contains("Content-Security-Policy: default-src 'self'")
	assert out.contains('X-Frame-Options: DENY')
	assert out.contains('X-Content-Type-Options: nosniff')
	assert out.contains('Referrer-Policy:')
	assert out.contains('Permissions-Policy:')
}

fn test_status_line_and_body_preserved() ! {
	wrapped := with_security_headers(app)
	out := wrapped('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1)!.bytestr()
	assert out.starts_with('HTTP/1.1 200 OK\r\n') // status line still first
	assert out.contains('<h1>secure</h1>') // body intact
	// headers go between status line and the body
	hsts_at := out.index('Strict-Transport-Security') or { -1 }
	body_at := out.index('<h1>') or { -1 }
	assert hsts_at > 0 && body_at > hsts_at
}
