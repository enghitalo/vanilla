module main

import http_server.core
import http_server.http1_1.response

// SOLUTION: pure codec tests + raw-request E2E (BEST_PRACTICES §9).
// The chunk iterator is a pure function over bytes — exactly the thing to
// unit-test hard, since it's the request-smuggling-adjacent piece. The E2E
// tests feed raw requests straight to handle(); the CL+TE case asserts the
// CORE's smuggling guard, not example code.

fn decode_all(enc []u8) ![]u8 {
	mut dst := []u8{}
	decode_chunked_into(enc, 0, enc.len, mut dst)!
	return dst
}

fn test_decode_chunked_basic() ! {
	enc := '4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n'.bytes()
	assert decode_all(enc)!.bytestr() == 'Wikipedia'
}

fn test_decode_chunked_empty() ! {
	assert decode_all('0\r\n\r\n'.bytes())!.len == 0
}

fn test_chunk_extensions_are_skipped() ! {
	// `;name=val` after the size is legal and must be ignored (RFC 9112 §7.1.1).
	enc := '5;ext=1\r\nhello\r\n0\r\n\r\n'.bytes()
	assert decode_all(enc)!.bytestr() == 'hello'
}

fn test_hex_sizes_are_case_insensitive() ! {
	enc := 'A\r\n0123456789\r\n0\r\n\r\n'.bytes()
	assert decode_all(enc)!.bytestr() == '0123456789'
	enc2 := 'a\r\n0123456789\r\n0\r\n\r\n'.bytes()
	assert decode_all(enc2)!.bytestr() == '0123456789'
}

fn test_decode_chunked_malformed_errors() {
	// size says 9 bytes but the buffer ends after 3 -> must error, not over-read.
	if _ := decode_all('9\r\nabc'.bytes()) {
		assert false, 'truncated chunk must error'
	}
	// non-hex size
	if _ := decode_all('zz\r\nab\r\n0\r\n\r\n'.bytes()) {
		assert false, 'invalid chunk size must error'
	}
	// missing terminating CRLF after the zero-chunk
	if _ := decode_all('0\r\n'.bytes()) {
		assert false, 'truncated terminator must error'
	}
	// chunk data not CRLF-terminated
	if _ := decode_all('3\r\nabcXX0\r\n\r\n'.bytes()) {
		assert false, 'missing data CRLF must error'
	}
}

fn test_next_chunk_yields_views() ! {
	enc := '5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'.bytes()
	d1, l1, p1 := next_chunk(enc, 0, enc.len)!
	assert enc[d1..d1 + l1].bytestr() == 'hello'
	d2, l2, p2 := next_chunk(enc, p1, enc.len)!
	assert enc[d2..d2 + l2].bytestr() == ' world'
	_, l3, p3 := next_chunk(enc, p2, enc.len)!
	assert l3 == 0 // terminating chunk
	assert p3 == enc.len
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect.
fn serve(req string) string {
	mut out := []u8{}
	mut tctx := core.Ctx{}
	handle(req.bytes(), mut out, mut tctx)
	return out.bytestr()
}

fn test_response_uses_chunked_framing() ! {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	assert out.contains('Transfer-Encoding: chunked')
	assert !out.contains('Content-Length') // chunked => no Content-Length
	assert out.ends_with('0\r\n\r\n') // terminating chunk present
	// the three demo pieces decode back out of the response body
	body := out.all_after('\r\n\r\n').bytes()
	assert decode_all(body)!.bytestr() == 'first piece\nsecond piece\nthird piece\n'
}

fn test_chunked_request_is_echoed() ! {
	// Chunk boundaries need not survive the round trip — the PAYLOAD must.
	req := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n' +
		'5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'
	out := serve(req)
	assert out.contains('Transfer-Encoding: chunked')
	body := out.all_after('\r\n\r\n').bytes()
	assert decode_all(body)!.bytestr() == 'hello world'
}

fn test_smuggling_guard_via_validate_http1() {
	// Content-Length + Transfer-Encoding together must be rejected
	// (RFC 9112 §6.1) via req.validate_http1() — opt-in, one line in the handler.
	// The handler appends the canned 400 and closes the connection.
	req :=
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n' +
		'5\r\nhello\r\n0\r\n\r\n'
	mut out := []u8{}
	mut tctx := core.Ctx{}
	assert handle(req.bytes(), mut out, mut tctx) == .close
	assert out == response.tiny_bad_request_response
}

fn test_malformed_request_errors() {
	// Malformed input gets the canned 400 and the connection is closed.
	mut out := []u8{}
	mut tctx := core.Ctx{}
	assert handle('garbage'.bytes(), mut out, mut tctx) == .close
	assert out == response.tiny_bad_request_response
}
