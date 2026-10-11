module main

// SOLUTION: pure decoder table tests + raw-request E2E through serve().
// Percent-decoding is the kind of byte transformation that benefits most from
// table-driven tests, including the SECURITY case: decode exactly once.
// (`${}` and `.bytes()` here are test scaffolding — fine outside the handler.)
import core
import encoding.utf8

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

// U+FFFD REPLACEMENT CHARACTER, what each ill-formed UTF-8 sequence becomes.
const fffd = '\xef\xbf\xbd'

fn test_well_formed_utf8_is_kept() {
	assert decoded('%C3%A9') == 'é'
	assert decoded('J%C3%A9r%C3%B4me') == 'Jérôme'
	assert decoded('%E2%82%AC') == '€'
	assert decoded('%F0%9F%98%80') == '😀' // 4 bytes
	assert decoded('%ED%9F%BF') == '\xed\x9f\xbf' // U+D7FF, the last before the surrogates
	assert decoded('%F4%8F%BF%BF') == '\xf4\x8f\xbf\xbf' // U+10FFFF, the last code point
	assert decoded('%EF%BF%BD') == fffd // a U+FFFD sent by the client
	assert decoded('\xc3\xa9') == 'é' // sent unencoded
}

fn test_ill_formed_utf8_becomes_fffd() {
	// RFC 8259 §8.1: JSON exchanged between systems MUST be UTF-8. One U+FFFD
	// per maximal subpart (Unicode §3.9): the lead byte and the continuation
	// bytes that still fit it, or a single byte.
	assert decoded('%FF') == fffd
	assert decoded('%80') == fffd // a lone continuation byte
	assert decoded('%C0%80') == fffd + fffd // overlong NUL: C0 never leads
	assert decoded('%ED%A0%80') == fffd + fffd + fffd // the surrogate U+D800
	assert decoded('%E2%82') == fffd // a truncated €: one for both bytes
	assert decoded('%E2%82x') == fffd + 'x' // the byte that ends it is kept
	assert decoded('%E2%82%E2%82%AC') == fffd + '€'
	assert decoded('%F0%9F%98') == fffd // 3 bytes in, 3 bytes out
	assert decoded('%F4%90%80%80') == fffd + fffd + fffd + fffd // past U+10FFFF
	assert decoded('a\xffb\xc3') == 'a' + fffd + 'b' + fffd // sent unencoded
}

fn test_unicode_maximal_subpart_tables() {
	// Unicode §3.9, Tables 3-8 to 3-11, byte for byte.
	assert decoded('%C0%AF%E0%80%BF%F0%81%82%41') == fffd.repeat(8) + 'A' // non-shortest forms
	assert decoded('%ED%A0%80%ED%BF%BF%ED%AF%41') == fffd.repeat(8) + 'A' // surrogates
	assert decoded('%F4%91%92%93%FF%41%80%BF%42') == fffd.repeat(5) + 'A' + fffd.repeat(2) + 'B' // other
	assert decoded('%E1%80%E2%F0%91%92%F1%BF%41') == fffd.repeat(4) + 'A' // truncated
}

fn test_utf8_and_json_escapes_mixed() {
	// Escapes grow by 1 or 5 bytes and a U+FFFD by 0 to 2, next to each other,
	// to adjacent ill-formed sequences, and to FE and FF bytes in the input
	// (the markers' values): every byte lands in order.
	assert decoded('%22%FF%0A%C3%A9%5C%E2%82%22%F0%9F%98%01') == '\\"' + fffd +
		'\\u000aé\\\\' + fffd + '\\"' + fffd + '\\u0001'
	assert decoded('%F0%9F%98%22') == fffd + '\\"' // growth 0, then 1
	assert decoded('%FE%FF%E2%82%E2%82%C3') == fffd.repeat(5)
	assert decoded('%FE%22%E2%82%FF') == fffd + '\\"' + fffd + fffd
}

fn test_every_one_and_two_byte_input_gives_utf8() {
	// Each of the 256 one-byte and 65536 two-byte inputs comes out as valid
	// UTF-8 with no raw control byte.
	mut out := []u8{cap: 64}
	mut src := []u8{len: 2}
	for n in 1 .. 3 {
		for v in 0 .. (1 << (8 * n)) {
			src[0] = u8(v)
			src[1] = u8(v >> 8)
			unsafe {
				out.len = 0
			}
			write_decoded_json(mut out, unsafe { (&src[0]).vbytes(n) })
			assert utf8.validate_str(out.bytestr()), src.hex()
			assert !out.any(it < 0x20), src.hex()
		}
	}
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

fn test_query_with_invalid_utf8_answers_utf8() {
	// Percent-encoded and raw: the parser hands a raw 0xFF in the target
	// through as it is.
	req := 'GET /x?q=caf%C3%A9&bad=%FF%E2%82&raw=a\xffb HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert serve(req).bytestr() == response('{"q":"café","bad":"' + fffd + fffd + '","raw":"a' +
		fffd + 'b"}')
}

fn test_form_body_with_invalid_utf8_answers_utf8() {
	// In a key too, and a 4-byte sequence cut short by a quote.
	body := 'k%C0=%ED%A0%80&raw=\xf0\x9f\x98\x22'
	req :=
		'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	assert serve(req).bytestr() == response('{"k' + fffd + '":"' + fffd.repeat(3) + '","raw":"' +
		fffd + '\\""}')
}

// Every request shape — query, no query, form body, escapes to re-encode,
// ill-formed UTF-8 to replace — runs 20k times through one reused buffer, as a
// worker would serve them; the collector's lifetime allocation counter must
// not move. (Under `-gc none`, vanilla's production build, an allocation here
// would be a permanent leak.)
fn test_requests_allocate_nothing() {
	$if gcboehm ? {
		body := 'q=hello%20world&tag=c%2B%2B&tag=x&quote=a%22b'
		bad_body := 'k%C0=%ED%A0%80&raw=\xf0\x9f\x98\x22&ok=caf%C3%A9'
		reqs := [
			'GET /x?q=hello%20world&tag=c%2B%2B&ctl=%0A HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /x HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}',
			'GET /x?q=%FF%C0%80%E2%82&e=%F0%9F%98%80&raw=a\xffb HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /submit HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${bad_body.len}\r\n\r\n${bad_body}',
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
