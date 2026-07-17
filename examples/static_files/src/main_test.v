module main

// Pure-logic tests (Range math, MIME, and above all path-traversal safety)
// PLUS raw-request E2E through the serve() adapter (BEST_PRACTICES §9) — the
// handler is pure, so no listening socket is needed.
//
// The E2E cases need a real file on disk: testsuite_begin builds a throwaway
// ./public/index.html fixture in a temp dir and chdirs into it (web_root is
// a relative const), testsuite_end removes it. `${}` here is test scaffolding,
// not program code.
import core
import os

const fixture_body = '<h1>hello</h1>' // 14 bytes
const test_root = os.join_path(os.temp_dir(), 'vanilla_static_files_test_${os.getpid()}')

fn testsuite_begin() {
	os.mkdir_all(os.join_path(test_root, 'public')) or { panic(err) }
	os.write_file(os.join_path(test_root, 'public', 'index.html'), fixture_body) or { panic(err) }
	os.chdir(test_root) or { panic(err) }
}

fn testsuite_end() {
	os.chdir(os.temp_dir()) or {}
	os.rmdir_all(test_root) or {}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}

// ---- pure logic --------------------------------------------------------------

fn test_parse_range() {
	if s, e := parse_range('bytes=0-99'.bytes(), 1000) {
		assert s == 0 && e == 99
	} else {
		assert false
	}
	if s, e := parse_range('bytes=500-'.bytes(), 1000) {
		assert s == 500 && e == 999 // open-ended -> to last byte
	} else {
		assert false
	}
	if s, e := parse_range('bytes=-100'.bytes(), 1000) {
		assert s == 900 && e == 999 // suffix range -> last 100 bytes
	} else {
		assert false
	}
}

fn test_parse_range_rejects_bad_input() {
	if _, _ := parse_range('bytes=900-100'.bytes(), 1000) { // start > end
		assert false
	} else {
		assert true
	}
	if _, _ := parse_range('items=0-9'.bytes(), 1000) { // wrong unit
		assert false
	} else {
		assert true
	}
	if _, _ := parse_range('bytes=0-99-100'.bytes(), 1000) { // two dashes
		assert false
	} else {
		assert true
	}
	if _, _ := parse_range('bytes=0-9999'.bytes(), 1000) { // end past the file
		assert false
	} else {
		assert true
	}
}

fn test_mime_type() {
	assert mime_type('index.html').contains('text/html')
	assert mime_type('app.js') == 'application/javascript'
	assert mime_type('pic.png') == 'image/png'
	assert mime_type('PIC.PNG') == 'image/png' // extension match is case-insensitive
	assert mime_type('blob.bin') == 'application/octet-stream'
	assert mime_type('no_extension') == 'application/octet-stream'
}

// THE most important test in a static server.
fn test_path_traversal_refused() {
	assert safe_path('/../../etc/passwd') == none
	assert safe_path('/../../../root/.ssh/id_rsa') == none
	// a normal path resolves to something inside the root
	p := safe_path('/index.html') or { '' }
	assert p != ''
}

// ---- raw-request E2E (serve adapter) -------------------------------------------

fn test_get_index() {
	out := serve('GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK')
	assert out.contains('Content-Type: text/html; charset=utf-8')
	assert out.contains('Accept-Ranges: bytes')
	assert out.contains('ETag: "')
	assert out.ends_with(fixture_body)
}

fn test_root_serves_index() {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK')
	assert out.ends_with(fixture_body)
}

fn test_query_string_is_stripped() {
	out := serve('GET /index.html?v=123 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK')
	assert out.ends_with(fixture_body)
}

fn test_head_sends_headers_only() {
	out := serve('HEAD /index.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK')
	assert out.contains('Content-Length: ${fixture_body.len}')
	assert out.ends_with('\r\n\r\n') // no body after the header block
}

fn test_unknown_file_404() {
	out := serve('GET /nope.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
}

fn test_post_405_with_allow() {
	out :=
		serve('POST /index.html HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()).bytestr()
	assert out.contains('405 Method Not Allowed')
	assert out.contains('Allow: GET, HEAD')
}

fn test_range_request_206() {
	out :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\n\r\n'.bytes()).bytestr()
	assert out.contains('206 Partial Content')
	assert out.contains('Content-Range: bytes 0-4/${fixture_body.len}')
	assert out.contains('Content-Length: 5')
	assert out.ends_with(fixture_body[..5])
}

fn test_invalid_range_falls_back_to_200() {
	out :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=900-100\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK') // unusable spec -> full response, as before
	assert out.ends_with(fixture_body)
}

fn test_if_none_match_roundtrip_304() {
	first := serve('GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	tag_at := first.index('ETag: ') or {
		assert false, 'response must carry an ETag'
		return
	}
	assert first.len >= tag_at + 6 + 18
	etag := first[tag_at + 6..tag_at + 6 + 18] // `"<16 hex>"` (64-bit wyhash)
	out :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nIf-None-Match: ${etag}\r\n\r\n'.bytes()).bytestr()
	assert out.contains('304 Not Modified')
	assert out.contains('ETag: ${etag}')
	assert !out.contains('200 OK')
}

fn test_path_traversal_gets_404() {
	out := serve('GET /../../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
}

fn test_malformed_request_errors() {
	// Malformed input must append the canned 400 and close the connection.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out.bytestr().contains('400 Bad Request')
}
