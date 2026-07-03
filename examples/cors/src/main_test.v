module main

// SOLUTION: pure handler test — works today.
// CORS is header logic, so the preflight + allowlist behavior is fully unit
// testable without a browser or server.

fn test_allowlist() {
	assert origin_allowed('http://localhost:5173')
	assert !origin_allowed('https://evil.com')
}

fn test_preflight_allowed_origin() ! {
	req :=
		'OPTIONS /api HTTP/1.1\r\nOrigin: http://localhost:5173\r\nAccess-Control-Request-Method: POST\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	assert out.contains('204 No Content')
	assert out.contains('Access-Control-Allow-Origin: http://localhost:5173')
	assert out.contains('Access-Control-Allow-Methods:')
	assert out.contains('Access-Control-Max-Age:')
}

fn test_preflight_forbidden_origin() ! {
	req := 'OPTIONS /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n'.bytes()
	assert serve(req)!.bytestr().contains('403 Forbidden')
}

fn test_simple_request_echoes_allowed_origin() ! {
	req := 'GET /api HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	assert out.contains('Access-Control-Allow-Origin: https://app.example.com')
	// SECURITY invariant: never the wildcard `*` when credentials are allowed.
	assert !out.contains('Access-Control-Allow-Origin: *')
}

fn test_simple_request_disallowed_origin_gets_no_cors() ! {
	// The server still serves the resource — the missing CORS grant is what
	// makes the BROWSER block the cross-origin read.
	req := 'GET /api HTTP/1.1\r\nOrigin: https://evil.com\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	assert out.contains('200 OK')
	assert !out.contains('Access-Control-Allow-Origin')
	assert !out.contains('Access-Control-Allow-Credentials')
}

fn test_simple_request_without_origin() ! {
	// Same-origin (or non-browser) request: plain response, zero CORS headers.
	req := 'GET /api HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	assert out.contains('200 OK')
	assert out.contains('{"ok":true}')
	assert !out.contains('Access-Control-Allow-Origin')
	assert !out.contains('Vary: Origin')
}

fn test_malformed_request_errors() {
	// Malformed input must surface as a handler error, never a response.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	handle(req, -1, mut out)!
	return out
}
