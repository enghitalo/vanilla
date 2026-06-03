module main

// SOLUTION: pure codec test (works today) + Solution-2 note for the wire side.
// The chunked DECODER is a pure function over bytes — exactly the thing to
// unit-test hard, since it's the request-smuggling-adjacent piece.

fn test_decode_chunked_basic() ! {
	enc := '4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n'.bytes()
	assert decode_chunked(enc)!.bytestr() == 'Wikipedia'
}

fn test_decode_chunked_empty() ! {
	assert decode_chunked('0\r\n\r\n'.bytes())!.len == 0
}

fn test_decode_chunked_truncated_errors() {
	// size says 9 bytes but the buffer ends after 3 -> must error, not over-read.
	enc := '9\r\nabc'.bytes()
	if _ := decode_chunked(enc) {
		assert false
	} else {
		assert true
	}
}

fn test_response_uses_chunked_framing() ! {
	out := handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1)!.bytestr()
	assert out.contains('Transfer-Encoding: chunked')
	assert !out.contains('Content-Length') // chunked => no Content-Length
	assert out.ends_with('0\r\n\r\n') // terminating chunk present
}

/*
ASPIRATIONAL — Solution 2: read a chunked RESPONSE incrementally from a real
socket (the current Server.test() can't: it frames by Content-Length and would
hang). With the programmable client:

  mut c := testkit.dial(port); c.send('GET / HTTP/1.1\r\n\r\n')
  c.read_until('\r\n\r\n')                 // headers
  assert c.read_chunk() == 'first piece\n' // decode chunks as they arrive
  ... until the 0-length terminator.
*/
