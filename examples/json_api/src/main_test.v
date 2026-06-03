module main

import http_server.http1_1.request_parser

// SOLUTION: pure body-parsing tests (work today) + Solution-1 split-fuzz note.
// JSON decode and multipart parsing are pure over the body bytes, so they're
// unit testable now. What is NOT testable today is whether the body ARRIVES
// whole — that's the read_request framing bug, and split-fuzz is its regression
// test (see the block at the bottom).

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

fn test_create_user_json() {
	req := mkreq('POST /users HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{"name":"Ada","email":"ada@example.com"}')
	out := create_user_json(req).bytestr()
	assert out.contains('201 Created')
	assert out.contains('"name":"Ada"')
	assert out.contains('"email":"ada@example.com"')
}

fn test_invalid_json_is_400() {
	req := mkreq('POST /users HTTP/1.1\r\nContent-Length: 3\r\n\r\n{ x')
	assert create_user_json(req).bytestr().contains('400')
}

fn test_missing_fields_is_400() {
	req := mkreq('POST /users HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}')
	assert create_user_json(req).bytestr().contains('400')
}

fn test_parse_multipart() {
	body := '--boundary\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nhello\r\n--boundary--\r\n'
	parts := parse_multipart(body.bytes(), '--boundary')
	assert parts.len == 1
	assert parts[0].name == 'file'
	assert parts[0].filename == 'a.txt'
	assert parts[0].content.bytestr() == 'hello'
}

/*
ASPIRATIONAL — Solution 1: split-point fuzzing. This is the regression test for
the read_request body-framing fix. TODAY IT FAILS (the core truncates bodies
split across TCP segments) — failing is the signal that the fix is still needed.

  full     := 'POST /users HTTP/1.1\r\nContent-Type: application/json\r\n' +
              'Content-Length: 41\r\n\r\n{"name":"Ada","email":"ada@example.com"}'
  expected := '201 Created'
  for split in 1 .. full.len {                 // every possible TCP boundary
      mut c := testkit.dial(port)
      c.send(full[..split].bytes()); c.flush()
      c.send(full[split..].bytes())
      assert c.read_response().contains(expected)   // must reassemble identically
      c.close()
  }
*/
