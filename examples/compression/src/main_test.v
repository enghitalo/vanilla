module main

import compress.brotli
import compress.gzip
import compress.zstd

// SOLUTION: pure negotiation + round-trip + raw-request E2E (BEST_PRACTICES §9).
// pick_encoding is pure over raw bytes; each precompressed const response is
// verified with a ROUND-TRIP oracle: split it, decompress the body, assert we
// got the original demo_body back. Handlers are pure, so the E2E test feeds
// raw request bytes straight to handle() — no listening socket required.

// pick adapts pick_encoding's offset-based signature for test readability.
fn pick(accept string, brotli_ok bool) Encoding {
	return pick_encoding(accept.bytes(), 0, accept.len, brotli_ok)
}

fn test_pick_preference_order() {
	assert pick('gzip, deflate', true) == .gzip
	assert pick('br, gzip', true) == .br // br preferred when offered
	assert pick('zstd, gzip', true) == .zstd // zstd beats gzip
	assert pick('GZIP', true) == .gzip // tokens are case-insensitive
	assert pick('gzip;q=1, br', true) == .br // `;` delimits a token
	assert pick('identity', true) == .identity
	assert pick('', true) == .identity
}

fn test_pick_without_brotli() {
	// libbrotli missing at runtime: negotiate down, never fail the request.
	assert pick('br, gzip', false) == .gzip
	assert pick('br, zstd, gzip', false) == .zstd
	assert pick('br', false) == .identity
}

fn test_pick_whole_tokens_only() {
	// pack200-gzip is a DIFFERENT registered coding — substring matching would
	// serve gzip to a client that never accepted it (RFC 9110 §12.5.3).
	assert pick('pack200-gzip', true) == .identity
	assert pick('pack200-gzip, gzip', true) == .gzip
}

fn test_has_token_respects_offsets() {
	// The value is addressed by offsets into the request buffer: bytes before
	// `start` and after `start + len` must never leak into the match.
	buf := 'XXXgzipYYY'.bytes()
	assert has_token(buf, 3, 4, 'gzip')
	assert !has_token(buf, 3, 4, 'zstd')
	assert !has_token(buf, 0, 3, 'gzip') // window too short
	assert !has_token(buf, 3, 3, 'gzip') // token crosses the window end
}

// Split a serialized response into (headers, body) at the CRLFCRLF terminator.
fn split_response(resp []u8) (string, []u8) {
	s := resp.bytestr()
	idx := s.index('\r\n\r\n') or {
		assert false, 'response has no header terminator'
		return s, []u8{}
	}
	return s[..idx], resp[idx + 4..]
}

fn test_identity_response() {
	headers, body := split_response(resp_identity)
	assert !headers.contains('Content-Encoding') // identity: header omitted
	assert headers.contains('Vary: Accept-Encoding') // mandatory for caches
	assert headers.contains('Content-Length: ${body.len}')
	assert body == demo_body
}

fn test_gzip_response_roundtrip() ! {
	headers, body := split_response(resp_gzip)
	assert headers.contains('Content-Encoding: gzip')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len // it actually compressed
	assert gzip.decompress(body)! == demo_body
}

fn test_zstd_response_roundtrip() ! {
	headers, body := split_response(resp_zstd)
	assert headers.contains('Content-Encoding: zstd')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len
	assert zstd.decompress(body)! == demo_body
}

fn test_brotli_response_roundtrip() ! {
	if resp_br.len == 0 {
		println('skipping: system libbrotli not installed')
		return
	}
	headers, body := split_response(resp_br)
	assert headers.contains('Content-Encoding: br')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len
	assert brotli.decompress(body)! == demo_body
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	handle(req, -1, mut out)!
	return out
}

fn test_handle_raw_requests() ! {
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n'.bytes())! == resp_gzip
	// Header NAMES are case-insensitive too (RFC 9110 §5.1).
	assert serve('GET / HTTP/1.1\r\naccept-encoding: zstd\r\n\r\n'.bytes())! == resp_zstd
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes())! == resp_identity
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: pack200-gzip\r\n\r\n'.bytes())! == resp_identity
	if resp_br.len > 0 {
		assert serve('GET / HTTP/1.1\r\nAccept-Encoding: br, gzip\r\n\r\n'.bytes())! == resp_br
	}
}

fn test_handle_malformed_requests() {
	// Malformed input must surface as a handler error (the core turns it into
	// a 400), never a response — BEST_PRACTICES §9.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
	// Truncated before the CRLFCRLF terminator.
	if _ := serve('GET / HTTP/1.1\r\nHost: local'.bytes()) {
		assert false, 'truncated request must not produce a response'
	}
}
