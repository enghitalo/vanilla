module static_assets

// Pure, socket-free tests — exactly vanilla's testing style: feed a raw request
// to respond() and assert the raw response. These pin down GitHub issue #19's
// acceptance criteria (application/wasm MIME, precompressed negotiation,
// immutable caching, SPA fallback, traversal safety, conditional GET).
import os

// A small built bundle written to a temp dir for the suite to serve.
const fixture_root = os.join_path(os.temp_dir(), 'vanilla_static_assets_fixture')

fn testsuite_begin() {
	if os.exists(fixture_root) {
		os.rmdir_all(fixture_root) or {}
	}
	os.mkdir_all(fixture_root) or { panic(err) }
	os.mkdir_all(os.join_path(fixture_root, 'assets')) or { panic(err) }

	write('index.html', '<!doctype html><title>app</title><script src=/app.abc123.js></script>')
	write('app.abc123.js', 'export const x = 1')
	write('app.abc123.js.br', 'BROTLI-APP-JS')
	write('app.abc123.js.gz', 'GZIP-APP-JS')
	write('styles.7f7f7f.css', 'body{margin:0}')
	os.write_file_array(os.join_path(fixture_root, 'core.9f3a1c.wasm'), [u8(0x00), `a`, `s`, `m`,
		0x01, 0x00, 0x00, 0x00]) or { panic(err) }
	write('core.9f3a1c.wasm.br', 'BROTLI-WASM')
	write('assets/logo.png', 'PNGDATA')
	// A file above the default sendfile threshold (256 KiB): on Linux this is
	// served disk-backed (sendfile path); elsewhere it is just preloaded. Either
	// way the bytes a client receives must be identical. A recognizable pattern
	// lets the tests verify the exact body.
	mut big := []u8{len: big_size}
	for i in 0 .. big.len {
		big[i] = u8(i & 0xff)
	}
	os.write_file_array(os.join_path(fixture_root, 'big.0a1b2c.wasm'), big) or { panic(err) }
}

const big_size = 512 * 1024

fn testsuite_end() {
	os.rmdir_all(fixture_root) or {}
}

fn write(rel string, content string) {
	os.write_file(os.join_path(fixture_root, rel), content) or { panic(err) }
}

fn server() AssetServer {
	return new(Config{ root: fixture_root }) or { panic(err) }
}

fn req(line string) []u8 {
	return (line + '\r\n\r\n').bytes()
}

// --- MIME table -------------------------------------------------------------

fn test_mime_type() {
	assert mime_type('core.9f3a1c.wasm') == 'application/wasm' // the hard blocker
	assert mime_type('app.js') == 'text/javascript; charset=utf-8'
	assert mime_type('app.mjs') == 'text/javascript; charset=utf-8'
	assert mime_type('app.css').starts_with('text/css')
	assert mime_type('index.html').starts_with('text/html')
	assert mime_type('data.json') == 'application/json'
	assert mime_type('app.js.map') == 'application/json'
	assert mime_type('site.webmanifest') == 'application/manifest+json'
	assert mime_type('logo.png') == 'image/png'
	assert mime_type('blob.bin') == 'application/octet-stream'
}

// --- hashed-asset detection -------------------------------------------------

fn test_glob_match_detects_hashed_assets() {
	assert glob_match('*.[hash].*', 'core.9f3a1c.wasm')
	assert glob_match('*.[hash].*', 'app.abc123.js')
	assert glob_match('*.[hash].*', 'styles.7f7f7f.css')
	// not hashed: no >=6-hex interior segment
	assert !glob_match('*.[hash].*', 'index.html')
	assert !glob_match('*.[hash].*', 'styles.min.css') // "min" is not a hash
	assert !glob_match('*.[hash].*', 'app.12345.js') // only 5 hex
}

// --- WASM + immutable caching -----------------------------------------------

fn test_serves_wasm_with_application_wasm() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: application/wasm')
	assert resp.contains('Cache-Control: public, max-age=31536000, immutable')
}

fn test_hashed_css_is_immutable() {
	resp := server().respond(req('GET /styles.7f7f7f.css HTTP/1.1'))!.bytestr()
	assert resp.contains('Cache-Control: public, max-age=31536000, immutable')
}

// --- precompressed negotiation ----------------------------------------------

fn test_negotiates_brotli_when_accepted() {
	resp :=
		server().respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br, gzip'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Encoding: br')
	assert resp.contains('Vary: Accept-Encoding')
	assert resp.contains('BROTLI-APP-JS') // the .br sibling bytes, not the source
}

fn test_falls_back_to_gzip_when_br_not_accepted() {
	resp := server().respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: gzip'))!.bytestr()
	assert resp.contains('Content-Encoding: gzip')
	assert resp.contains('GZIP-APP-JS')
}

fn test_q_value_zero_disables_encoding() {
	// br is explicitly disabled (q=0) -> must pick gzip, not br
	resp :=
		server().respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br;q=0, gzip'))!.bytestr()
	assert resp.contains('Content-Encoding: gzip')
	assert !resp.contains('Content-Encoding: br')
}

fn test_serves_raw_when_encoding_not_accepted() {
	resp := server().respond(req('GET /app.abc123.js HTTP/1.1'))!.bytestr()
	assert !resp.contains('Content-Encoding')
	assert resp.contains('export const x = 1') // identity source bytes
}

// --- HTML entrypoint + SPA fallback -----------------------------------------

fn test_index_html_is_no_cache() {
	resp := server().respond(req('GET / HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: text/html')
	assert resp.contains('Cache-Control: no-cache')
}

fn test_spa_fallback_for_client_route() {
	// deep link / refresh on a client route with no file -> serve index.html
	resp := server().respond(req('GET /users/42 HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: text/html')
	assert resp.contains('Cache-Control: no-cache')
}

fn test_missing_asset_looking_path_is_404_not_fallback() {
	// asset-looking 404s must NOT be masked by the SPA fallback
	resp := server().respond(req('GET /nope.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404')
}

fn test_nested_asset_served() {
	resp := server().respond(req('GET /assets/logo.png HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: image/png')
}

// --- security ---------------------------------------------------------------

fn test_path_traversal_refused() {
	resp := server().respond(req('GET /../../etc/passwd HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404') || resp.starts_with('HTTP/1.1 400')
}

// --- conditional GET / ETag -------------------------------------------------

fn test_etag_conditional_get_returns_304() {
	s := server()
	etag := s.etag_for('core.9f3a1c.wasm')!
	resp := s.respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: ' + etag))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
	assert resp.contains('ETag: ' + etag)
}

fn test_etag_wildcard_matches() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: *'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
}

fn test_stale_etag_serves_200() {
	resp :=
		server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: "deadbeef"'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

// --- method + HEAD + Range --------------------------------------------------

fn test_method_not_allowed() {
	resp := server().respond(req('POST / HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 405')
	assert resp.contains('Allow: GET, HEAD')
}

fn test_head_returns_headers_without_body() {
	resp := server().respond(req('HEAD /core.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Length: 8') // wasm magic is 8 bytes
	// nothing follows the header terminator
	idx := resp.index('\r\n\r\n') or { -1 }
	assert idx >= 0
	assert idx + 4 == resp.len
}

fn test_range_request_returns_206() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=0-3'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 206')
	assert resp.contains('Content-Range: bytes 0-3/8')
	assert resp.contains('Content-Length: 4')
}

// --- large (disk-backed / sendfile on Linux) assets -------------------------
//
// In a unit test no sendfile-capable worker is running, so respond_into() takes
// the read-fallback and produces the full bytes — letting us verify the body is
// correct (the same bytes sendfile would deliver in the live server).

fn full_response(resp []u8) (string, []u8) {
	s := resp.bytestr()
	if i := s.index('\r\n\r\n') {
		return s[..i], resp[i + 4..]
	}
	return s, []u8{}
}

fn test_large_asset_respond_returns_full_body() {
	resp := server().respond(req('GET /big.0a1b2c.wasm HTTP/1.1'))!
	headers, body := full_response(resp)
	assert headers.starts_with('HTTP/1.1 200')
	assert headers.contains('Content-Type: application/wasm')
	assert headers.contains('Content-Length: ${big_size}')
	assert headers.contains('Cache-Control: public, max-age=31536000, immutable')
	assert body.len == big_size
	assert body[0] == 0 && body[255] == 255 && body[256] == 0 // the i&0xff pattern
}

fn test_large_asset_respond_into_appends_full_body() {
	// No sendfile-capable worker in a test → respond_into reads the body into out.
	mut out := []u8{}
	server().respond_into(req('GET /big.0a1b2c.wasm HTTP/1.1'), mut out)!
	headers, body := full_response(out)
	assert headers.starts_with('HTTP/1.1 200')
	assert headers.contains('Content-Type: application/wasm')
	assert body.len == big_size
	assert body[1000] == u8(1000 & 0xff)
}

fn test_large_asset_head_has_no_body() {
	mut out := []u8{}
	server().respond_into(req('HEAD /big.0a1b2c.wasm HTTP/1.1'), mut out)!
	headers, body := full_response(out)
	assert headers.starts_with('HTTP/1.1 200')
	assert headers.contains('Content-Length: ${big_size}')
	assert body.len == 0
}

fn test_large_asset_etag_round_trips_304() {
	s := server()
	etag := s.etag_for('big.0a1b2c.wasm')!
	assert etag.len > 2 // quoted, non-empty
	resp := s.respond(req('GET /big.0a1b2c.wasm HTTP/1.1\r\nIf-None-Match: ' + etag))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
}

fn test_large_asset_range() {
	resp := server().respond(req('GET /big.0a1b2c.wasm HTTP/1.1\r\nRange: bytes=10-13'))!
	headers, body := full_response(resp)
	assert headers.starts_with('HTTP/1.1 206')
	assert headers.contains('Content-Range: bytes 10-13/${big_size}')
	assert headers.contains('Content-Length: 4')
	assert body.len == 4
	assert body[0] == 10 && body[3] == 13 // the i&0xff pattern at offset 10
}
