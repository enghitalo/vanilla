module main

import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response

// SOLUTION: pure handler test — works today.
// Token issuance, cookie scanning and safe/unsafe method gating are pure, so
// the full CSRF policy is testable without a server. `${}` is fine here:
// tests are scaffolding, not request-serving code.

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut tctx := core.Ctx{}
	handle(req, mut out, mut tctx)
	return out
}

// set_cookie_token extracts the csrf token from a GET /form response.
fn set_cookie_token(resp string) string {
	rest := resp.all_after('Set-Cookie: csrf=')
	return rest.all_before(';')
}

fn test_form_sets_fresh_token() {
	req := 'GET /form HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('Set-Cookie: csrf=')
	assert out.contains('Secure; SameSite=Strict')
	a := set_cookie_token(out)
	assert a.len == 64 // 32 CSPRNG bytes, hex-encoded
	for c in a {
		assert (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`)
	}
	b := set_cookie_token(serve(req).bytestr())
	assert a != b // CSPRNG, never repeats
}

// slice_of wraps a whole buffer as a parser Slice, for the in-place helpers.
fn slice_of(buf []u8) request_parser.Slice {
	return request_parser.Slice{
		start: 0
		len:   buf.len
	}
}

fn test_cookie_value_scan() {
	buf := 'sid=abc; csrf=xyz'.bytes()
	s, l := cookie_value(buf, slice_of(buf), 'csrf')
	assert buf[s..s + l].bytestr() == 'xyz'
	s2, l2 := cookie_value(buf, slice_of(buf), 'sid')
	assert buf[s2..s2 + l2].bytestr() == 'abc'
}

fn test_cookie_value_is_segment_anchored() {
	// `xcsrf=evil` must NOT match `csrf` — matches anchor at segment starts.
	buf := 'xcsrf=evil; other=1'.bytes()
	_, l := cookie_value(buf, slice_of(buf), 'csrf')
	assert l == -1
	// ...but the real pair after a decoy prefix segment is still found.
	buf2 := 'xcsrf=evil; csrf=good'.bytes()
	s2, l2 := cookie_value(buf2, slice_of(buf2), 'csrf')
	assert buf2[s2..s2 + l2].bytestr() == 'good'
	// Empty value is reported as len 0 (the handler rejects it).
	buf3 := 'csrf='.bytes()
	_, l3 := cookie_value(buf3, slice_of(buf3), 'csrf')
	assert l3 == 0
}

fn test_unsafe_methods_gated() {
	for m in ['POST', 'PUT', 'PATCH', 'DELETE'] {
		buf := m.bytes()
		assert is_unsafe(buf, slice_of(buf)), '${m} must require a token'
	}
	for m in ['GET', 'HEAD', 'OPTIONS'] {
		buf := m.bytes()
		assert !is_unsafe(buf, slice_of(buf)), '${m} is safe, needs no token'
	}
}

fn test_post_without_token_forbidden() {
	req := 'POST /save HTTP/1.1\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('403 Forbidden')
}

fn test_post_with_matching_token_ok() {
	tok := 'deadbeefcafe'
	req :=
		'POST /save HTTP/1.1\r\nCookie: csrf=${tok}\r\nX-CSRF-Token: ${tok}\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('200 OK')
}

fn test_post_with_mismatched_token_forbidden() {
	req :=
		'POST /save HTTP/1.1\r\nCookie: csrf=aaaa\r\nX-CSRF-Token: bbbb\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('403 Forbidden')
}

fn test_header_token_without_cookie_forbidden() {
	// Half a double-submit is no submit: the attacker CAN set the header via
	// their own fetch, but cannot make the browser attach the cookie.
	req := 'POST /save HTTP/1.1\r\nX-CSRF-Token: aaaa\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('403 Forbidden')
}

fn test_empty_cookie_token_forbidden() {
	req :=
		'POST /save HTTP/1.1\r\nCookie: csrf=\r\nX-CSRF-Token: \r\nContent-Length: 0\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('403 Forbidden')
}

fn test_safe_get_passes_through() {
	// Safe methods need no token — GET must be side-effect free anyway.
	req := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('200 OK')
}

fn test_malformed_request_errors() {
	// Malformed input gets the canned 400 and the connection is closed.
	mut out := []u8{}
	mut tctx := core.Ctx{}
	assert handle('garbage'.bytes(), mut out, mut tctx) == .close
	assert out == response.tiny_bad_request_response
	mut out2 := []u8{}
	assert handle('POST /save HTTP/1.1\r\nTrunc'.bytes(), mut out2, mut tctx) == .close
	assert out2 == response.tiny_bad_request_response
}
