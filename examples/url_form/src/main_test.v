module main

// SOLUTION: pure decoder table tests + raw-request E2E through serve().
// Percent-decoding is the kind of byte transformation that benefits most from
// table-driven tests, including the SECURITY case: decode exactly once.
// (`${}` and `.bytes()` here are test scaffolding — fine outside the handler.)
import core

// decoded runs the handler's decoder over all of `s`: the decoded bytes as
// they appear inside a JSON string (escaped).
fn decoded(s string) string {
	mut out := []u8{}
	write_decoded_json(mut out, s.bytes())
	return out.bytestr()
}

// form_json is the JSON object the handler writes for the pairs in `s`.
fn form_json(s string) string {
	mut out := []u8{}
	write_form_json(mut out, s.bytes())
	return out.bytestr()
}

fn test_percent_decode() {
	assert decoded('hello%20world') == 'hello world'
	assert decoded('c%2B%2B') == 'c++'
	assert decoded('a+b') == 'a b' // '+' is space in form/query encoding
	assert decoded('plain') == 'plain'
	assert decoded('') == '' // empty view — no alloc, no panic
	assert decoded('%41%62') == 'Ab' // both hex cases
}

fn test_decode_exactly_once() {
	// %2527 -> %27 (NOT all the way to a single quote). Double-decoding is a
	// classic filter bypass; decoding once is the correct, safe behavior.
	assert decoded('%2527') == '%27'
}

fn test_malformed_escape_is_literal() {
	assert decoded('100%') == '100%' // dangling % left as-is
	assert decoded('%zz') == '%zz' // non-hex left as-is
	assert decoded('%2') == '%2' // truncated escape left as-is
	assert decoded('%2z%20') == '%2z ' // a bad escape does not swallow the next one
}

fn test_decoded_bytes_are_json_escaped() {
	assert decoded('a%22b') == 'a\\"b' // quote
	assert decoded('a%5Cb') == 'a\\\\b' // backslash
	assert decoded('%0A%1f') == '\\u000a\\u001f' // control bytes
}

fn test_parse_form() {
	assert form_json('q=hello%20world&tag=c%2B%2B&empty=') == '{"q":"hello world","tag":"c++","empty":""}'
	assert form_json('') == '{}'
	assert form_json('&&a=1&&') == '{"a":"1"}' // empty pairs are skipped
	assert form_json('flag&k=v=w') == '{"flag":"","k":"v=w"}' // no '=': empty value; later '=' is data
}

fn test_repeated_keys_are_echoed_per_pair() {
	// One member per pair, in wire order: the multi-value form `tag=a&tag=b`
	// keeps both values.
	assert form_json('tag=a&tag=b') == '{"tag":"a","tag":"b"}'
}

// ---- raw-request E2E through the pure handler -------------------------------

// response is the exact reply the handler frames around a JSON body.
fn response(body string) string {
	return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'
}

fn test_get_query_is_decoded() {
	req := 'GET /x?q=hello%20world&tag=c%2B%2B HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req).bytestr()
	assert out.contains('200 OK')
	assert out.contains('"q":"hello world"')
	assert out.contains('"tag":"c++"')
	assert out == response('{"q":"hello world","tag":"c++"}')
}

fn test_frame_body_behind_earlier_bytes() {
	// Pipelined responses share one write buffer: the head goes in front of
	// this body, not at the start of `out`, also across a grow of `out`.
	mut out := []u8{cap: 8}
	core.append_str(mut out, 'previous')
	mark := out.len
	core.append_str(mut out, '{"a":"1"}')
	frame_body(mut out, mark, resp_prefix, resp_prefix_tail)
	assert out.bytestr() == 'previous' + response('{"a":"1"}')
}

fn test_no_query_is_empty_object() {
	assert serve('GET /x HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr() == response('{}')
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
	assert out == response('{"q":"hello world","tag":"c++"}')
}

fn test_post_form_body_replaces_query() {
	body := 'k=v'
	req :=
		'POST /submit?q=1 HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	assert serve(req).bytestr() == response('{"k":"v"}')
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

// Every request shape — query, no query, form body, escapes to re-encode —
// runs 20k times through one reused buffer, as a worker would serve them; the
// collector's lifetime allocation counter must not move. (Under `-gc none`,
// vanilla's production build, an allocation here would be a permanent leak.)
fn test_requests_allocate_nothing() {
	$if gcboehm ? {
		body := 'q=hello%20world&tag=c%2B%2B&tag=x&quote=a%22b'
		reqs := [
			'GET /x?q=hello%20world&tag=c%2B%2B&ctl=%0A HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /x HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}',
			'garbage',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
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
