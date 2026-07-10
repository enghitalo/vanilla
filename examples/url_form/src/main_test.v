module main

// SOLUTION: pure decoder table tests + raw-request E2E through serve().
// Percent-decoding is the kind of byte transformation that benefits most from
// table-driven tests, including the SECURITY case: decode exactly once.
// (`${}` and `.bytes()` here are test scaffolding — fine outside the handler.)
import http_server.core

fn test_percent_decode() {
	assert percent_decode('hello%20world'.bytes()) == 'hello world'
	assert percent_decode('c%2B%2B'.bytes()) == 'c++'
	assert percent_decode('a+b'.bytes()) == 'a b' // '+' is space in form/query encoding
	assert percent_decode('plain'.bytes()) == 'plain'
	assert percent_decode([]u8{}) == '' // empty view — no alloc, no panic
}

fn test_decode_exactly_once() {
	// %2527 -> %27 (NOT all the way to a single quote). Double-decoding is a
	// classic filter bypass; decoding once is the correct, safe behavior.
	assert percent_decode('%2527'.bytes()) == '%27'
}

fn test_malformed_escape_is_literal() {
	assert percent_decode('100%'.bytes()) == '100%' // dangling % left as-is
	assert percent_decode('%zz'.bytes()) == '%zz' // non-hex left as-is
	assert percent_decode('%2'.bytes()) == '%2' // truncated escape left as-is
}

fn test_parse_form() {
	m := parse_form('q=hello%20world&tag=c%2B%2B&empty='.bytes())
	assert m['q'] == 'hello world'
	assert m['tag'] == 'c++'
	assert m['empty'] == ''
}

// ---- raw-request E2E through the pure handler -------------------------------
// The JSON pair order follows V map insertion order; contains() per pair keeps
// the asserts robust to that.

fn test_get_query_is_decoded() {
	req := 'GET /x?q=hello%20world&tag=c%2B%2B HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('"q":"hello world"')
	assert out.contains('"tag":"c++"')
}

fn test_plus_as_space_through_full_request() {
	req := 'GET /x?msg=a+b HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert serve(req).bytestr().contains('"msg":"a b"')
}

fn test_empty_query_is_empty_object() {
	req := 'GET /x? HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('{}')
}

fn test_post_form_body_is_decoded() {
	body := 'q=hello%20world&tag=c%2B%2B'
	req :=
		'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('"q":"hello world"')
	assert out.contains('"tag":"c++"')
}

fn test_post_content_type_is_case_insensitive() {
	// RFC 9110 §8.3.1: media types are case-insensitive — odd casing must
	// still parse (behavior improvement over the old case-sensitive check).
	body := 'k=v'
	req :=
		'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: Application/X-WWW-Form-URLencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	assert serve(req).bytestr().contains('"k":"v"')
}

fn test_post_form_with_charset_suffix() {
	body := 'k=v'
	req :=
		'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded; charset=UTF-8\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	assert serve(req).bytestr().contains('"k":"v"')
}

fn test_post_non_form_content_type_not_parsed() {
	body := 'k=v'
	req :=
		'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('{}') // body must NOT be parsed as a form
	assert !out.contains('"k"')
}

fn test_json_echo_escapes_user_input() {
	// %22 -> '"' — echoed unescaped this would be broken, injectable JSON.
	req := 'GET /x?q=a%22b HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('"q":"a\\"b"') // the quote arrives escaped
}

fn test_malformed_request_errors() {
	// Malformed input must append the canned 400 and close the connection.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out.bytestr().contains('400 Bad Request')
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}
