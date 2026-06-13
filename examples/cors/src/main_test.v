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

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	handle(req, -1, mut out)!
	return out
}
