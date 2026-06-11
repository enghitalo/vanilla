module main

// SOLUTION: pure handler test — works today.
// Token logic + safe/unsafe method gating are pure, so the full CSRF policy is
// unit testable.

fn test_token_is_long_and_random() {
	a := new_token()
	b := new_token()
	assert a.len == 64 // 32 bytes, hex-encoded
	assert a != b // CSPRNG, never repeats
}

fn test_parse_cookies() {
	m := parse_cookies('sid=abc; csrf=xyz')
	assert m['sid'] == 'abc'
	assert m['csrf'] == 'xyz'
}

fn test_unsafe_methods_gated() {
	assert is_unsafe('POST') && is_unsafe('PUT') && is_unsafe('DELETE')
	assert !is_unsafe('GET') && !is_unsafe('HEAD') // safe methods need no token
}

fn test_post_without_token_forbidden() ! {
	req := 'POST /save HTTP/1.1\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert handle(req, -1)!.bytestr().contains('403 Forbidden')
}

fn test_post_with_matching_token_ok() ! {
	tok := 'deadbeefcafe'
	req :=
		'POST /save HTTP/1.1\r\nCookie: csrf=${tok}\r\nX-CSRF-Token: ${tok}\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert handle(req, -1)!.bytestr().contains('200 OK')
}

fn test_post_with_mismatched_token_forbidden() ! {
	req :=
		'POST /save HTTP/1.1\r\nCookie: csrf=aaaa\r\nX-CSRF-Token: bbbb\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert handle(req, -1)!.bytestr().contains('403 Forbidden')
}
