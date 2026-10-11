module main

import core
import http1_1.request_parser

// SOLUTION: pure body-parsing unit tests + raw-request E2E through serve().
// JSON decode and multipart parsing are pure over the body bytes, and the
// handler is a pure function of the raw request bytes, so everything here runs
// without a socket (BEST_PRACTICES §9).
//
// Body FRAMING (a body split across TCP segments) is the core's job and is
// regression-tested there: request_parser_test.v's test_frame_split_fuzz feeds
// the framer EVERY prefix of a framed request and asserts none of them parses
// as complete — the old truncation bug cannot come back silently. The residual
// core limitation is fragmentation across epoll readiness bursts (EAGAIN
// mid-message), which is rejected with an error — never delivered truncated.

// serve adapts the unified-handler contract (writes into a caller-owned buffer)
// to the return-a-buffer shape the assertions expect; a .close step maps to an
// error, mirroring the old error-raising contract.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .close {
		return error('handler closed the connection')
	}
	return out
}

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

// raw_post frames a request with a correct Content-Length (`${}` is fine in
// test scaffolding — it never runs in the server).
fn raw_post(path string, content_type string, body string) string {
	return 'POST ${path} HTTP/1.1\r\nContent-Type: ${content_type}\r\nContent-Length: ${body.len}\r\n\r\n${body}'
}

// framed is the exact response frame_body must produce around `body`.
fn framed(status string, body string) string {
	return 'HTTP/1.1 ${status}\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'
}

// parse_multipart collects every part PartIter yields. Test scaffolding: it
// builds the array the handler never builds (upload walks the parts in place).
fn parse_multipart(body []u8, boundary []u8) []Part {
	mut parts := []Part{}
	for p in parts_of(body, boundary) {
		parts << p
	}
	return parts
}

// ----- unit tests: sub-handlers and the multipart scanner --------------------

fn test_create_user_json() {
	req := mkreq(raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}'))
	mut out := []u8{}
	create_user_json(req, mut out, unsafe { nil })
	res := out.bytestr()
	assert res.contains('201 Created')
	assert res.contains('"name":"Ada"')
	assert res.contains('"email":"ada@example.com"')
}

fn test_invalid_json_is_400() {
	req := mkreq(raw_post('/users', 'application/json', '{ x'))
	mut out := []u8{}
	create_user_json(req, mut out, unsafe { nil })
	res := out.bytestr()
	assert res.contains('400 Bad Request')
	assert res.contains('invalid JSON')
}

fn test_missing_fields_is_400() {
	req := mkreq(raw_post('/users', 'application/json', '{}'))
	mut out := []u8{}
	create_user_json(req, mut out, unsafe { nil })
	res := out.bytestr()
	assert res.contains('400 Bad Request')
	assert res.contains('name and email are required')
}

fn test_parse_multipart() {
	body := '--boundary\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nhello\r\n--boundary--\r\n'
	parts := parse_multipart(body.bytes(), 'boundary'.bytes())
	assert parts.len == 1
	assert parts[0].name == 'file'
	assert parts[0].filename == 'a.txt'
	assert parts[0].content.bytestr() == 'hello'
}

fn test_parse_multipart_edges() {
	// Preamble, a field part without filename, an empty file part, closing '--'.
	body := 'preamble ignored\r\n--b\r\nContent-Disposition: form-data; name="note"\r\n\r\ntext value\r\n--b\r\nContent-Disposition: form-data; name="empty"; filename="e.bin"\r\n\r\n\r\n--b--\r\n'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 2
	assert parts[0].name == 'note'
	assert parts[0].filename == ''
	assert parts[0].content.bytestr() == 'text value'
	assert parts[1].name == 'empty'
	assert parts[1].filename == 'e.bin'
	assert parts[1].content.len == 0
}

fn test_parse_multipart_boundary_at_buffer_end() {
	// Closing delimiter flush at the end of the buffer, no trailing CRLF.
	body := '--b\r\nContent-Disposition: form-data; name="f"; filename="x"\r\n\r\ndata\r\n--b--'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 1
	assert parts[0].filename == 'x'
	assert parts[0].content.bytestr() == 'data'
}

fn test_parse_multipart_name_never_matches_filename_tail() {
	// Whole-attribute match: with only filename= present, name must stay ''.
	body := '--b\r\nContent-Disposition: form-data; filename="a.txt"\r\n\r\nz\r\n--b--\r\n'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 1
	assert parts[0].name == ''
	assert parts[0].filename == 'a.txt'
}

fn test_parse_multipart_skips_a_part_without_headers_end() {
	// A part with no blank line is skipped; the iterator moves on to the next.
	body := '--b\r\nno separator here\r\n--b\r\nContent-Disposition: form-data; name="f"; filename="y"\r\n\r\nok\r\n--b--\r\n'
	parts := parse_multipart(body.bytes(), 'b'.bytes())
	assert parts.len == 1
	assert parts[0].filename == 'y'
	assert parts[0].content.bytestr() == 'ok'
	assert parse_multipart(body.bytes(), []u8{}).len == 0 // no boundary, no parts
}

// frame_body splices the head in front of a body behind earlier bytes of the
// same buffer (pipelined responses share one write buffer), across a grow of
// `out`.
fn test_frame_body_behind_earlier_bytes() {
	mut out := []u8{cap: 8}
	core.append_str(mut out, 'previous')
	mark := out.len
	core.append_str(mut out, '{"a":1}')
	frame_body(mut out, mark, head_200, head_tail)
	assert out.bytestr() == 'previous' + framed('200 OK', '{"a":1}')
}

// Every static response's Content-Length is its body's length.
fn test_static_responses_are_framed() {
	for r in [resp_404, resp_400_invalid_json, resp_400_missing_fields, resp_400_no_content_type,
		resp_400_no_boundary] {
		head_end := r.index('\r\n\r\n') or { -1 }
		assert head_end > 0, r
		assert r.contains('\r\nContent-Length: ${r.len - head_end - 4}\r\n'), r
	}
}

// ----- raw-request E2E through the full handler ------------------------------

fn test_e2e_create_user() ! {
	req := raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}')
	out := serve(req.bytes())!.bytestr()
	assert out.contains('201 Created')
	assert out.contains('"id":1')
	assert out.contains('"email":"ada@example.com"')
	assert out == framed('201 Created', '{"id":1,"name":"Ada","email":"ada@example.com"}')
}

fn test_e2e_create_user_with_worker_state() ! {
	// The same bytes through the per-worker decode buffer, reused across calls.
	req := raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}').bytes()
	state := make_state()
	mut event_loop := core.EventLoop{}
	for _ in 0 .. 3 {
		mut out := []u8{}
		assert handle(req, mut out, -1, state, mut event_loop) == .done
		assert out.bytestr() == framed('201 Created', '{"id":1,"name":"Ada","email":"ada@example.com"}')
	}
	mut out := []u8{}
	bad := raw_post('/users', 'application/json', '{ x').bytes()
	assert handle(bad, mut out, -1, state, mut event_loop) == .done
	assert out.bytestr() == resp_400_invalid_json
}

fn test_e2e_create_user_escapes_strings() ! {
	// Decoded escapes are re-escaped on the way out (§8): a quote stays a JSON
	// string character, and non-ASCII is \u-escaped (escape_unicode).
	req := raw_post('/users', 'application/json', '{"name":"A\\"da","email":"é@x"}')
	out := serve(req.bytes())!.bytestr()
	assert out == framed('201 Created', '{"id":1,"name":"A\\"da","email":"\\u00e9@x"}')
}

fn test_e2e_invalid_json_is_400() ! {
	out := serve(raw_post('/users', 'application/json', '{ x').bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('invalid JSON')
}

fn test_e2e_upload_multipart() ! {
	body := '--XYZ\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nhello\r\n--XYZ--\r\n'
	req := raw_post('/upload', 'multipart/form-data; boundary=XYZ', body)
	out := serve(req.bytes())!.bytestr()
	assert out.contains('200 OK')
	assert out.contains('"field":"file"')
	assert out.contains('"filename":"a.txt"')
	assert out.contains('"size":5')
	assert out == framed('200 OK', '{"received":[{"field":"file","filename":"a.txt","size":5}]}')
}

fn test_e2e_upload_lists_only_file_parts() ! {
	body := '--XYZ\r\nContent-Disposition: form-data; name="a"; filename="a.txt"\r\n\r\nhello\r\n--XYZ\r\nContent-Disposition: form-data; name="note"\r\n\r\nskipped\r\n--XYZ\r\nContent-Disposition: form-data; name="b"; filename="b.bin"\r\n\r\nworld!\r\n--XYZ--\r\n'
	req := raw_post('/upload', 'multipart/form-data; boundary=XYZ', body)
	out := serve(req.bytes())!.bytestr()
	assert out == framed('200 OK', '{"received":[{"field":"a","filename":"a.txt","size":5},{"field":"b","filename":"b.bin","size":6}]}')
	// No body at all: an empty list.
	empty := serve(raw_post('/upload', 'multipart/form-data; boundary=XYZ', '').bytes())!.bytestr()
	assert empty == framed('200 OK', '{"received":[]}')
}

fn test_e2e_upload_boundary_param_case_insensitive() ! {
	// RFC 2045: parameter names are case-insensitive — Boundary= must work.
	body := '--XYZ\r\nContent-Disposition: form-data; name="f"; filename="b"\r\n\r\nok\r\n--XYZ--\r\n'
	req := raw_post('/upload', 'multipart/form-data; Boundary=XYZ', body)
	out := serve(req.bytes())!.bytestr()
	assert out.contains('200 OK')
	assert out.contains('"size":2')
}

fn test_e2e_upload_missing_content_type_is_400() ! {
	req := 'POST /upload HTTP/1.1\r\nContent-Length: 2\r\n\r\nxx'
	out := serve(req.bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('missing Content-Type')
}

fn test_e2e_upload_missing_boundary_is_400() ! {
	req := raw_post('/upload', 'multipart/form-data', 'xx')
	out := serve(req.bytes())!.bytestr()
	assert out.contains('400 Bad Request')
	assert out.contains('missing multipart boundary')
}

fn test_e2e_unknown_route_is_404() ! {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('404 Not Found')
	assert out.contains('"error":"not found"')
}

// ----- the point of the design: what a request allocates ---------------------

// heap_growth runs every request `rounds` times through one reused buffer, as
// a worker serves them, and returns how far the collector's lifetime
// allocation counter moved (after a warm-up, so `out` and the decode buffer
// have reached their high-water marks).
fn heap_growth(reqs [][]u8, worker_state voidptr, rounds int) u64 {
	mut out := []u8{cap: 4096}
	mut event_loop := core.EventLoop{}
	for r in reqs {
		unsafe {
			out.len = 0
		}
		handle(r, mut out, -1, worker_state, mut event_loop)
	}
	before := gc_heap_usage().total_bytes
	for _ in 0 .. rounds {
		for r in reqs {
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, worker_state, mut event_loop)
		}
	}
	return gc_heap_usage().total_bytes - before
}

// /upload (multipart parsing and the JSON summary) and every static answer
// allocate nothing. (Under `-gc none`, the production build, an allocation
// here would be a permanent leak.)
fn test_upload_and_static_answers_allocate_nothing() {
	$if gcboehm ? {
		files := '--XYZ\r\nContent-Disposition: form-data; name="a"; filename="a.txt"\r\n\r\nhello\r\n--XYZ\r\nContent-Disposition: form-data; name="note"\r\n\r\nskipped\r\n--XYZ\r\nContent-Disposition: form-data; name="b"; filename="b.bin"\r\n\r\nworld!\r\n--XYZ--\r\n'
		reqs := [
			raw_post('/upload', 'multipart/form-data; boundary=XYZ', files),
			raw_post('/upload', 'multipart/form-data; boundary=XYZ', ''),
			raw_post('/upload', 'multipart/form-data', 'xx'),
			'POST /upload HTTP/1.1\r\nContent-Length: 2\r\n\r\nxx',
			'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
		].map(it.bytes())
		rounds := 20_000
		grown := heap_growth(reqs, make_state(), rounds)
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// POST /users still allocates what json2 does on every decode (the strings
// it returns are owned copies, by design, plus a little bookkeeping: 16 bytes
// even for `{}`) and json2's formatting of the `id` number: a few dozen
// bytes. The bound catches a return of what it used to pay per request, about
// 2.4 KiB: a copy of the body, json2's token array and its 2 KiB encoder
// buffer.
fn test_create_user_allocates_only_decoded_strings() {
	$if gcboehm ? {
		reqs := [
			raw_post('/users', 'application/json', '{"name":"Ada","email":"ada@example.com"}').bytes(),
			raw_post('/users', 'application/json', '{}').bytes(),
		]
		rounds := 20_000
		per_req := heap_growth(reqs, make_state(), rounds) / u64(rounds * reqs.len)
		assert per_req < 128, 'POST /users allocated ${per_req} bytes per request'
	}
}

fn test_e2e_malformed_request_errors() {
	// Malformed input must surface as .close (the canned 400 + drop), never a
	// routed response.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
}
