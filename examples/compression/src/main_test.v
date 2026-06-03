module main

import compress.gzip

// SOLUTION: pure negotiation + round-trip test — works today.
// Negotiation is pure; for the encoder we use a ROUND-TRIP oracle: compress in
// the response, then decompress and assert we got the original bytes back.
// (See main_oracle_test.v for the Solution-3 `curl --compressed` variant.)

fn test_negotiate_preference_order() {
	assert negotiate_encoding('gzip, deflate') == 'gzip'
	assert negotiate_encoding('br, gzip') == 'br' // br preferred when offered
	assert negotiate_encoding('identity') == 'identity'
	assert negotiate_encoding('') == 'identity'
}

fn test_compressible_types() {
	assert compressible('application/json')
	assert compressible('text/html; charset=utf-8')
	assert !compressible('image/png') // already compressed
}

fn test_gzip_roundtrip() ! {
	body := []u8{len: 1000, init: u8(`a`)}
	out := build_response('text/plain', body, 'gzip')
	s := out.bytestr()
	assert s.contains('Content-Encoding: gzip')
	assert s.contains('Vary: Accept-Encoding') // mandatory for caches
	// body after the header terminator must decompress back to the original
	idx := s.index('\r\n\r\n') or {
		assert false
		return
	}
	compressed := out[idx + 4..]
	assert gzip.decompress(compressed)! == body
}

fn test_small_body_not_compressed() {
	out := build_response('text/plain', 'tiny'.bytes(), 'gzip').bytestr()
	assert !out.contains('Content-Encoding') // below threshold: skip
}
