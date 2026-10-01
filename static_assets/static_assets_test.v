module static_assets

// Pure, socket-free tests — exactly vanilla's testing style: feed a raw request
// to respond() and assert the raw response. These pin down GitHub issue #19's
// acceptance criteria (application/wasm MIME, precompressed negotiation,
// immutable caching, SPA fallback, traversal safety, conditional GET).
import os
import time
import core

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

// --- conditional GET + Range edge cases (zero-copy slice parsing) ------------
//
// These pin the byte-scan etag_matches_slice / parse_range_slice rewrites: same
// behavior as the old string-split parsers, but reading straight off the request
// buffer with no per-request allocation.

fn test_etag_weak_validator_matches() {
	s := server()
	etag := s.etag_for('core.9f3a1c.wasm')!
	resp := s.respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: W/' + etag))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
}

fn test_etag_list_matches_later_member() {
	s := server()
	etag := s.etag_for('core.9f3a1c.wasm')!
	resp :=
		s.respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: "nope", ' + etag))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
}

fn test_etag_list_no_member_serves_200() {
	resp :=
		server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: "a", "b"'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

fn test_range_suffix_returns_last_bytes() {
	// 8-byte asset; `-3` is the last 3 bytes (offsets 5..7).
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=-3'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 206')
	assert resp.contains('Content-Range: bytes 5-7/8')
	assert resp.contains('Content-Length: 3')
}

fn test_range_open_ended_runs_to_eof() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=5-'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 206')
	assert resp.contains('Content-Range: bytes 5-7/8')
	assert resp.contains('Content-Length: 3')
}

fn test_range_multi_dash_falls_through_to_200() {
	// More than one '-' is not a single range → serve the full 200, not a 206.
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=0-1-2'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

fn test_range_wrong_unit_falls_through_to_200() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: items=0-3'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

fn test_range_unsatisfiable_falls_through_to_200() {
	// start beyond EOF (8-byte asset) → none → full 200.
	resp :=
		server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=900-1000'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

fn test_range_absurd_number_falls_through_to_200() {
	// A number past i64 saturates (does not wrap to a valid offset) → none → 200.
	resp :=
		server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=18446744073709551616-'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

// --- url_prefix mount -------------------------------------------------------

fn mounted_server() AssetServer {
	return new(Config{ root: fixture_root, url_prefix: '/static/' }) or { panic(err) }
}

fn test_url_prefix_serves_under_mount() {
	// The same bundle, mounted at /static/: the prefix is stripped before keying.
	resp := mounted_server().respond(req('GET /static/app.abc123.js HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('export const x = 1')
}

fn test_url_prefix_negotiates_under_mount() {
	// Precompressed negotiation still works through the mount.
	resp :=
		mounted_server().respond(req('GET /static/app.abc123.js HTTP/1.1\r\nAccept-Encoding: br'))!.bytestr()
	assert resp.contains('Content-Encoding: br')
	assert resp.contains('BROTLI-APP-JS')
}

fn test_url_prefix_path_outside_mount_is_404() {
	// A path that does not start with the mount prefix is not owned by this server.
	resp := mounted_server().respond(req('GET /app.abc123.js HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404')
}

fn test_url_prefix_traversal_still_blocked() {
	// `..` under the mount is still refused (cannot escape via the prefix).
	resp := mounted_server().respond(req('GET /static/../core.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404')
}

fn test_no_prefix_default_still_serves_at_root() {
	// Regression: default (no url_prefix) serves at the root exactly as before.
	resp := server().respond(req('GET /app.abc123.js HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
}

// --- per-representation ETags, 304 with Vary, exact 206 ---------------------

fn header_value(resp []u8, name string) string {
	head, _ := full_response(resp)
	for line in head.split('\r\n') {
		if line.to_lower().starts_with(name.to_lower() + ': ') {
			return line[name.len + 2..]
		}
	}
	return ''
}

fn test_each_representation_has_its_own_etag() {
	s := server()
	ident := s.respond(req('GET /app.abc123.js HTTP/1.1'))!
	br := s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br'))!
	gz := s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: gzip'))!
	e_id := header_value(ident, 'ETag')
	e_br := header_value(br, 'ETag')
	e_gz := header_value(gz, 'ETag')
	assert e_id.len == 18 && e_br.len == 18 && e_gz.len == 18
	assert e_id != e_br && e_id != e_gz && e_br != e_gz
	assert e_id == s.etag_for('app.abc123.js')!
}

fn test_304_uses_the_negotiated_representation_and_carries_vary() {
	s := server()
	br := s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br'))!
	e_br := header_value(br, 'ETag')
	nm := s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br\r\nIf-None-Match: ' +
		e_br))!.bytestr()
	assert nm == 'HTTP/1.1 304 Not Modified\r\nETag: ${e_br}\r\nCache-Control: public, max-age=31536000, immutable\r\nVary: Accept-Encoding\r\nConnection: keep-alive\r\n\r\n'
	// The identity ETag does not validate the br representation.
	e_id := s.etag_for('app.abc123.js')!
	full := s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br\r\nIf-None-Match: ' +
		e_id))!.bytestr()
	assert full.starts_with('HTTP/1.1 200')
	assert full.contains('Content-Encoding: br')
	// A non-negotiable asset's 304 has no Vary; respond_into gives the same bytes.
	e_css := s.etag_for('styles.7f7f7f.css')!
	mut out := []u8{}
	s.respond_into(req('GET /styles.7f7f7f.css HTTP/1.1\r\nIf-None-Match: ' + e_css), mut out)!
	assert out.bytestr() == 'HTTP/1.1 304 Not Modified\r\nETag: ${e_css}\r\nCache-Control: public, max-age=31536000, immutable\r\nConnection: keep-alive\r\n\r\n'
}

fn test_206_bytes_are_exact() {
	s := server()
	// Small (in RAM) and large (disk-backed on Linux) identity bodies.
	e_small := s.etag_for('app.abc123.js')!
	small_want := 'HTTP/1.1 206 Partial Content\r\nContent-Type: text/javascript; charset=utf-8\r\nContent-Range: bytes 7-11/18\r\nContent-Length: 5\r\nAccept-Ranges: bytes\r\nETag: ${e_small}\r\nConnection: keep-alive\r\n\r\nconst'
	// A Range ignores Accept-Encoding: it is always a range of the identity bytes.
	small_req := req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br\r\nRange: bytes=7-11')
	assert s.respond(small_req)!.bytestr() == small_want
	mut out := []u8{}
	s.respond_into(small_req, mut out)!
	assert out.bytestr() == small_want

	e_big := s.etag_for('big.0a1b2c.wasm')!
	big_req := req('GET /big.0a1b2c.wasm HTTP/1.1\r\nRange: bytes=1000-1999')
	big_head := 'HTTP/1.1 206 Partial Content\r\nContent-Type: application/wasm\r\nContent-Range: bytes 1000-1999/${big_size}\r\nContent-Length: 1000\r\nAccept-Ranges: bytes\r\nETag: ${e_big}\r\nConnection: keep-alive\r\n\r\n'
	mut want := big_head.bytes()
	for i in 1000 .. 2000 {
		want << u8(i & 0xff)
	}
	assert s.respond(big_req)! == want
	out.clear()
	s.respond_into(big_req, mut out)!
	assert out == want
}

fn test_range_if_none_match_uses_the_identity_etag() {
	s := server()
	e_id := s.etag_for('app.abc123.js')!
	e_br := header_value(s.respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br'))!,
		'ETag')
	// A Range selects the identity bytes whatever Accept-Encoding says, and RFC
	// 9110 evaluates If-None-Match before Range: against the identity ETag.
	ranged := 'GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br\r\nRange: bytes=0-5\r\nIf-None-Match: '
	nm := s.respond(req(ranged + e_id))!.bytestr()
	assert nm == 'HTTP/1.1 304 Not Modified\r\nETag: ${e_id}\r\nCache-Control: public, max-age=31536000, immutable\r\nVary: Accept-Encoding\r\nConnection: keep-alive\r\n\r\n'
	mut out := []u8{}
	s.respond_into(req(ranged + e_id), mut out)!
	assert out.bytestr() == nm
	// The br ETag does not validate a range of the identity bytes.
	part := s.respond(req(ranged + e_br))!
	assert part.bytestr().starts_with('HTTP/1.1 206')
	assert header_value(part, 'ETag') == e_id
	assert body_of(part).bytestr() == 'export'
	// A Range that does not apply is ignored: the negotiated representation is
	// validated and served as without one.
	unsat := 'GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br\r\nRange: bytes=900-1000\r\nIf-None-Match: '
	assert s.respond(req(unsat + e_br))!.bytestr().starts_with('HTTP/1.1 304')
	full := s.respond(req(unsat + e_id))!
	assert full.bytestr().starts_with('HTTP/1.1 200')
	assert header_value(full, 'Content-Encoding') == 'br'
}

fn test_disk_backed_etag_is_stable_across_replicas() {
	// Two copies of one file, as two replicas (or a restart over another
	// overlay mount) see it: the same bytes and mtime, another inode and ctime.
	a_dir := fd_dir('replica_a')
	b_dir := fd_dir('replica_b')
	defer {
		os.rmdir_all(a_dir) or {}
		os.rmdir_all(b_dir) or {}
	}
	big := pattern(40 * 1024, 19)
	mtime := i64(1_700_000_000)
	for dir in [a_dir, b_dir] {
		path := os.join_path(dir, 'f.bin')
		os.write_file_array(path, big) or { panic(err) }
		os.utime(path, mtime, mtime) or { panic(err) }
	}
	$if !windows {
		assert os.stat(os.join_path(a_dir, 'f.bin'))!.inode != os.stat(os.join_path(b_dir,
			'f.bin'))!.inode
	}
	a := new(Config{ root: a_dir, sendfile_min_bytes: fd_threshold })!
	b := new(Config{ root: b_dir, sendfile_min_bytes: fd_threshold })!
	$if linux {
		assert !snap_of(a, 'f.bin', slot_identity).in_memory // disk-backed: not hashed from the bytes
	}
	assert a.etag_for('f.bin')! == b.etag_for('f.bin')!
	$if linux {
		// ... but from size and mtime, so another mtime is another ETag.
		os.utime(os.join_path(b_dir, 'f.bin'), mtime + 1, mtime + 1)!
		b2 := new(Config{ root: b_dir, sendfile_min_bytes: fd_threshold })!
		assert b2.etag_for('f.bin')! != a.etag_for('f.bin')!
	}
}

fn test_disk_backed_file_truncated_in_place_stays_framed() {
	$if windows {
		return // every body is in RAM on Windows
	}
	dir := fd_dir('truncated')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'f.bin')
	a := pattern(40 * 1024, 20)
	os.write_file_array(path, a) or { panic(err) }
	s := new(Config{ root: dir, sendfile_min_bytes: fd_threshold })!
	// Truncated in place (same inode) under a snapshot that does not follow the
	// disk: the Content-Length it promises stays true, the lost tail is zeros.
	os.write_file_array(path, a[..1000]) or { panic(err) }
	r := get(s, '/f.bin')
	assert header_value(r, 'Content-Length') == '${a.len}'
	body := body_of(r)
	assert body.len == a.len
	$if linux {
		assert body[..1000] == a[..1000]
		assert body[1000..].all(it == 0)
	} $else {
		assert body == a // kept in RAM since new()
	}
	mut out := []u8{}
	s.respond_into(req('GET /f.bin HTTP/1.1\r\nRange: bytes=30000-30999'), mut out)!
	assert header_value(out, 'Content-Length') == '1000'
	assert body_of(out).len == 1000
}

// --- follow_disk -------------------------------------------------------------
//
// Each test serves its own temp dir. revalidate_ms: 0 (a stat on every request)
// unless noted, so every request sees the file as it is on disk.

const fd_threshold = 16 * 1024

fn fd_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'vanilla_sa_follow_${tag}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

// pattern returns `n` recognisable bytes; a different `seed` gives different bytes.
fn pattern(n int, seed int) []u8 {
	mut b := []u8{len: n}
	for i in 0 .. n {
		b[i] = u8((i * 7 + seed * 31 + i / 251) & 0xff)
	}
	return b
}

// replace writes `content` to a temporary file in `dir` and renames it over
// `name`, the way a deploy replaces a file: a new inode under the same name.
fn replace(dir string, name string, content []u8) {
	tmp := os.join_path(dir, '.tmp-' + name)
	os.write_file_array(tmp, content) or { panic(err) }
	os.rename(tmp, os.join_path(dir, name)) or { panic(err) }
}

fn follow_server(dir string, memory_fallback bool) AssetServer {
	return new(Config{
		root:               dir
		follow_disk:        true
		revalidate_ms:      0
		sendfile_min_bytes: fd_threshold
		memory_fallback:    memory_fallback
	}) or { panic(err) }
}

// get serves `path` through respond_into (no sendfile-capable worker on a test
// thread, so the body is appended) and checks respond() gives the same bytes.
fn get(s &AssetServer, path string) []u8 {
	r := req('GET ${path} HTTP/1.1')
	mut out := []u8{}
	s.respond_into(r, mut out) or { panic(err) }
	assert s.respond(r) or { panic(err) } == out
	return out
}

fn body_of(resp []u8) []u8 {
	_, body := full_response(resp)
	return body
}

fn snap_of(s &AssetServer, rel string, slot int) &Snap {
	return s.assets[rel] or { panic('no asset ${rel}') }.reps[slot].snap()
}

fn check_same_length_rename(tag string, size int, memory_fallback bool) {
	dir := fd_dir(tag)
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(size, 1)
	b := pattern(size, 2)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := follow_server(dir, memory_fallback)
	r1 := get(s, '/f.bin')
	assert body_of(r1) == a
	$if linux {
		snap := snap_of(s, 'f.bin', slot_identity)
		assert snap.in_memory == (size < fd_threshold || memory_fallback)
		assert (snap.file_fd >= 0) == (size >= fd_threshold)
	}
	replace(dir, 'f.bin', b)
	r2 := get(s, '/f.bin')
	assert body_of(r2) == b
	assert header_value(r2, 'Content-Length') == header_value(r1, 'Content-Length')
	assert header_value(r2, 'ETag') != header_value(r1, 'ETag')
	assert header_value(r2, 'ETag') == s.etag_for('f.bin') or { panic(err) }
}

fn test_follow_same_length_rename() {
	$if windows {
		return // no follow_disk on Windows
	}
	check_same_length_rename('small', 1000, false)
	check_same_length_rename('large', 40 * 1024, false)
	check_same_length_rename('large_mem', 40 * 1024, true)
}

fn check_restore_with_older_mtime(tag string, size int) {
	dir := fd_dir(tag)
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'f.bin')
	a := pattern(size, 3)
	b := pattern(size, 4)
	os.write_file_array(path, a) or { panic(err) }
	old_mtime := os.file_last_mod_unix(path) - 3600 // well before anything below
	os.utime(path, old_mtime, old_mtime) or { panic(err) }
	s := follow_server(dir, false)
	assert body_of(get(s, '/f.bin')) == a
	replace(dir, 'f.bin', b)
	assert body_of(get(s, '/f.bin')) == b
	// Restore A the way `cp -p` would: same bytes, the OLD mtime. A "newer
	// mtime" rule would keep serving B; signature inequality does not.
	tmp := os.join_path(dir, '.restore')
	os.write_file_array(tmp, a) or { panic(err) }
	os.utime(tmp, old_mtime, old_mtime) or { panic(err) }
	os.rename(tmp, path) or { panic(err) }
	assert body_of(get(s, '/f.bin')) == a
}

fn test_follow_restore_with_older_mtime() {
	$if windows {
		return // no follow_disk on Windows
	}
	check_restore_with_older_mtime('restore_small', 1000)
	check_restore_with_older_mtime('restore_large', 40 * 1024)
}

fn test_follow_in_place_same_size() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('inplace')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'f.txt')
	a := pattern(800, 5)
	b := pattern(800, 6)
	os.write_file_array(path, a) or { panic(err) }
	ino := os.stat(path) or { panic(err) }.inode
	s := follow_server(dir, false)
	assert body_of(get(s, '/f.txt')) == a
	// Same inode, same size: only mtime_ns/ctime_ns change. Kernel timestamps
	// are coarse (a tick is 1-4 ms), so the writes are 20 ms apart.
	time.sleep(20 * time.millisecond)
	os.write_file_array(path, b) or { panic(err) }
	assert os.stat(path) or { panic(err) }.inode == ino
	assert body_of(get(s, '/f.txt')) == b
	time.sleep(20 * time.millisecond)
	os.write_file_array(path, a) or { panic(err) }
	assert body_of(get(s, '/f.txt')) == a
}

fn check_same_size_same_mtime(tag string, size int) {
	dir := fd_dir(tag)
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'f.bin')
	a := pattern(size, 17)
	b := pattern(size, 18)
	mtime := i64(1_700_000_000) // whole seconds: os.utime sets no nanoseconds
	os.write_file_array(path, a) or { panic(err) }
	os.utime(path, mtime, mtime) or { panic(err) }
	s := follow_server(dir, false)
	r1 := get(s, '/f.bin')
	assert body_of(r1) == a
	tmp := os.join_path(dir, '.same')
	os.write_file_array(tmp, b) or { panic(err) }
	os.utime(tmp, mtime, mtime) or { panic(err) }
	os.rename(tmp, path) or { panic(err) }
	// Only the inode and ctime tell the two versions apart.
	mut st := C.vanilla_sa_sig{}
	assert C.vanilla_sa_stat(&char(path.str), &st) == 0
	old := snap_of(s, 'f.bin', slot_identity).sig
	assert st.size == old.size && st.mtime_ns == old.mtime_ns && st.ino != old.ino
	r2 := get(s, '/f.bin')
	assert body_of(r2) == b
	assert header_value(r2, 'Content-Length') == header_value(r1, 'Content-Length')
	// A body in RAM gets a new ETag (a hash of the bytes). A disk-backed one
	// keeps it (a hash of size and mtime_ns, both unchanged here), but its body
	// is read from the new inode all the same.
	if snap_of(s, 'f.bin', slot_identity).in_memory {
		assert header_value(r2, 'ETag') != header_value(r1, 'ETag')
	}
}

fn test_follow_same_size_same_mtime_new_inode() {
	$if windows {
		return // no follow_disk on Windows
	}
	check_same_size_same_mtime('same_mtime_small', 1000)
	check_same_size_same_mtime('same_mtime_large', 40 * 1024)
}

fn check_sibling_only(ext string, token string) {
	dir := fd_dir('sibling' + ext)
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'f.css'), 'body{margin:0}') or { panic(err) }
	os.write_file(os.join_path(dir, 'f.css' + ext), 'COMPRESSED-ONE') or { panic(err) }
	s := follow_server(dir, false)
	enc_req := req('GET /f.css HTTP/1.1\r\nAccept-Encoding: ' + token)
	ident_before := get(s, '/f.css')
	first := s.respond(enc_req) or { panic(err) }
	assert body_of(first).bytestr() == 'COMPRESSED-ONE'
	replace(dir, 'f.css' + ext, 'COMPRESSED-TWO!'.bytes())
	second := s.respond(enc_req) or { panic(err) }
	assert body_of(second).bytestr() == 'COMPRESSED-TWO!'
	assert header_value(second, 'Content-Encoding') == token
	assert header_value(second, 'Content-Length') == '15'
	assert header_value(second, 'ETag') != header_value(first, 'ETag')
	// The identity representation did not change: byte-identical, same ETag.
	assert get(s, '/f.css') == ident_before
}

fn test_follow_sibling_only() {
	$if windows {
		return // no follow_disk on Windows
	}
	check_sibling_only('.br', 'br')
	check_sibling_only('.gz', 'gzip')
}

fn test_follow_range_does_not_revalidate_encoded_representations() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('range_enc')
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'f.css'), 'body{margin:0}') or { panic(err) }
	os.write_file(os.join_path(dir, 'f.css.br'), 'COMPRESSED-ONE') or { panic(err) }
	s := follow_server(dir, false)
	br_boot := snap_of(s, 'f.css', slot_br)
	replace(dir, 'f.css.br', 'COMPRESSED-TWO!'.bytes())
	// A Range is served from the identity representation alone: the br one is
	// neither negotiated nor stat'ed, so it is still the boot snapshot.
	r := s.respond(req('GET /f.css HTTP/1.1\r\nAccept-Encoding: br\r\nRange: bytes=0-3')) or {
		panic(err)
	}
	assert body_of(r).bytestr() == 'body'
	assert voidptr(snap_of(s, 'f.css', slot_br)) == voidptr(br_boot)
	// The next request that negotiates br picks the new version up.
	r2 := s.respond(req('GET /f.css HTTP/1.1\r\nAccept-Encoding: br')) or { panic(err) }
	assert body_of(r2).bytestr() == 'COMPRESSED-TWO!'
	assert voidptr(snap_of(s, 'f.css', slot_br)) != voidptr(br_boot)
}

fn test_follow_size_change_and_threshold_crossing() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('cross')
	defer {
		os.rmdir_all(dir) or {}
	}
	small := pattern(1000, 7)
	large := pattern(40 * 1024, 8)
	smaller := pattern(500, 9)
	os.write_file_array(os.join_path(dir, 'f.bin'), small) or { panic(err) }
	s := follow_server(dir, false)
	r1 := get(s, '/f.bin')
	assert body_of(r1) == small
	assert header_value(r1, 'Content-Length') == '1000'
	replace(dir, 'f.bin', large)
	r2 := get(s, '/f.bin')
	assert body_of(r2) == large
	assert header_value(r2, 'Content-Length') == '${40 * 1024}'
	$if linux {
		assert !snap_of(s, 'f.bin', slot_identity).in_memory // now disk-backed
	}
	replace(dir, 'f.bin', smaller)
	r3 := get(s, '/f.bin')
	assert body_of(r3) == smaller
	assert header_value(r3, 'Content-Length') == '500'
	assert snap_of(s, 'f.bin', slot_identity).in_memory
	// HEAD and Range follow the new version too.
	mut out := []u8{}
	s.respond_into(req('HEAD /f.bin HTTP/1.1'), mut out) or { panic(err) }
	assert header_value(out, 'Content-Length') == '500'
	assert body_of(out).len == 0
	out.clear()
	s.respond_into(req('GET /f.bin HTTP/1.1\r\nRange: bytes=-10'), mut out) or { panic(err) }
	assert header_value(out, 'Content-Range') == 'bytes 490-499/500'
	assert body_of(out) == smaller[490..]
}

fn test_follow_deleted_file_keeps_serving() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('deleted')
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(1000, 10)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := follow_server(dir, false)
	r1 := get(s, '/f.bin')
	os.rm(os.join_path(dir, 'f.bin')) or { panic(err) }
	assert get(s, '/f.bin') == r1
	// A file added after new() is not followed (the key set is fixed).
	os.write_file(os.join_path(dir, 'new.txt'), 'late') or { panic(err) }
	assert get(s, '/new.txt').bytestr().starts_with('HTTP/1.1 404')
}

fn C.mkfifo(path &char, mode u32) int

fn make_fifo(path string) {
	$if !windows {
		assert C.mkfifo(&char(path.str), 0o644) == 0
	}
}

fn test_follow_non_regular_file_keeps_serving() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('fifo')
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(1000, 21)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	// A FIFO with no writer present at boot: new() does not block opening it,
	// and it is not served.
	make_fifo(os.join_path(dir, 'boot.bin'))
	s := follow_server(dir, false)
	assert get(s, '/boot.bin').bytestr().starts_with('HTTP/1.1 404')
	r1 := get(s, '/f.bin')
	assert body_of(r1) == a
	// A FIFO renamed over the file: no request blocks on it, and the last good
	// version keeps being served.
	make_fifo(os.join_path(dir, '.fifo'))
	os.rename(os.join_path(dir, '.fifo'), os.join_path(dir, 'f.bin')) or { panic(err) }
	assert get(s, '/f.bin') == r1
	// A regular file in its place again is followed.
	b := pattern(1000, 22)
	replace(dir, 'f.bin', b)
	assert body_of(get(s, '/f.bin')) == b
}

fn test_follow_disk_off_stays_immutable() {
	$if windows {
		return // replace() renames over an existing file, which Windows refuses
	}
	dir := fd_dir('immutable')
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(1000, 11)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := new(Config{ root: dir, revalidate_ms: 0 }) or { panic(err) }
	r1 := get(s, '/f.bin')
	assert body_of(r1) == a
	replace(dir, 'f.bin', pattern(1000, 12))
	assert get(s, '/f.bin') == r1
	assert isnil(snap_of(s, 'f.bin', slot_identity).prev)
}

fn test_follow_disk_is_refused_on_windows() {
	$if windows {
		dir := fd_dir('windows')
		defer {
			os.rmdir_all(dir) or {}
		}
		if _ := new(Config{ root: dir, follow_disk: true }) {
			assert false, 'follow_disk must be refused on Windows'
		}
	}
}

fn test_follow_revalidate_window() {
	$if windows {
		return // no follow_disk on Windows
	}
	dir := fd_dir('window')
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(1000, 13)
	b := pattern(1000, 14)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := new(Config{
		root:          dir
		follow_disk:   true
		revalidate_ms: 200
	}) or { panic(err) }
	assert body_of(get(s, '/f.bin')) == a
	replace(dir, 'f.bin', b)
	// Inside the window nothing stats: this one may still be A.
	early := body_of(get(s, '/f.bin'))
	assert early == a || early == b
	time.sleep(250 * time.millisecond)
	assert body_of(get(s, '/f.bin')) == b
}

// --- the sendfile hand-off follows the disk ----------------------------------
//
// The hand-off slot is thread-local, so the probe acts as a sendfile-capable
// worker on a thread of its own (a fresh slot) and only records what it saw;
// the asserts run on the test thread. Under tcc the slot is inert.

struct HandoffProbe {
	queued         bool
	head_only      bool // `out` held the headers only
	file_fd        int
	off            i64
	len            i64
	file_bytes     []u8 // pread of the queued region
	refused_queued bool // queued although the gate was closed
	refused_full   []u8 // the response with the gate closed
}

fn handoff_probe(s &AssetServer) HandoffProbe {
	core.enable_sendfile()
	mut out := []u8{}
	s.respond_into(req('GET /f.bin HTTP/1.1'), mut out) or { panic(err) }
	mut p := HandoffProbe{
		head_only: body_of(out).len == 0 && out.bytestr().ends_with('\r\n\r\n')
	}
	if qf := core.take_queued_file() {
		mut bytes := []u8{}
		$if !windows {
			core.append_file_region(mut bytes, qf.file_fd, qf.off, qf.len)
		}
		p = HandoffProbe{
			...p
			queued:     true
			file_fd:    qf.file_fd
			off:        qf.off
			len:        qf.len
			file_bytes: bytes
		}
	}
	core.set_queue_file_allowed(false)
	mut closed := []u8{}
	s.respond_into(req('GET /f.bin HTTP/1.1'), mut closed) or { panic(err) }
	mut refused_queued := false
	if _ := core.take_queued_file() {
		refused_queued = true
	}
	return HandoffProbe{
		...p
		refused_queued: refused_queued
		refused_full:   closed
	}
}

fn check_handoff(tag string, memory_fallback bool) {
	dir := fd_dir(tag)
	defer {
		os.rmdir_all(dir) or {}
	}
	a := pattern(40 * 1024, 15)
	b := pattern(40 * 1024, 16)
	os.write_file_array(os.join_path(dir, 'f.bin'), a) or { panic(err) }
	s := follow_server(dir, memory_fallback)
	boot := snap_of(s, 'f.bin', slot_identity)
	replace(dir, 'f.bin', b)
	p := spawn handoff_probe(&s)
	probe := p.wait()
	// With the gate closed, the body is appended: from RAM with memory_fallback,
	// by pread without it. Either way it is B, complete.
	assert !probe.refused_queued
	assert body_of(probe.refused_full) == b
	$if linux && !tinyc {
		assert probe.queued
		assert probe.head_only
		assert probe.file_fd >= 0 && probe.file_fd != boot.file_fd
		assert probe.off == 0 && probe.len == b.len
		assert probe.file_bytes == b
	} $else {
		assert !probe.queued
	}
	$if linux {
		assert snap_of(s, 'f.bin', slot_identity).in_memory == memory_fallback
	}
}

fn test_follow_sendfile_handoff() {
	$if windows {
		return // no follow_disk on Windows
	}
	check_handoff('handoff', false)
	check_handoff('handoff_mem', true)
}

// --- no allocation per request -----------------------------------------------

fn test_respond_into_does_not_allocate() {
	s := server()
	e_js := s.etag_for('app.abc123.js')!
	reqs := [
		req('GET /app.abc123.js HTTP/1.1'),
		req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: gzip, br'),
		req('GET /app.abc123.js HTTP/1.1\r\nIf-None-Match: ' + e_js),
		req('HEAD /core.9f3a1c.wasm HTTP/1.1'),
		req('GET /core.9f3a1c.wasm HTTP/1.1\r\nRange: bytes=2-5'),
		req('GET /big.0a1b2c.wasm HTTP/1.1'), // disk-backed on Linux: pread into out
		req('GET /big.0a1b2c.wasm HTTP/1.1\r\nRange: bytes=100-50000'),
		req('GET /users/42 HTTP/1.1'),
		req('GET /nope.9f3a1c.wasm HTTP/1.1'),
	]
	mut out := []u8{cap: 2 * big_size}
	// Warm up, then count what the GC hands out (0 on -gc none / -race builds).
	for r in reqs {
		out.clear()
		s.respond_into(r, mut out)!
	}
	before := gc_heap_usage().total_bytes
	for i in 0 .. 10_000 {
		out.clear()
		s.respond_into(reqs[i % reqs.len], mut out)!
	}
	grown := gc_heap_usage().total_bytes - before
	assert grown < 16 * 1024, 'respond_into allocated ${grown} bytes over 10k requests'
}

fn test_respond_does_not_allocate_for_in_memory_replies() {
	s := server()
	e_js := s.etag_for('app.abc123.js')!
	// A 200, HEAD or 304 of a snapshot is a view of its bytes and a 404 or 405
	// a constant: respond() has nothing to allocate for them.
	reqs := [
		req('GET /app.abc123.js HTTP/1.1'),
		req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: gzip, br'),
		req('GET /app.abc123.js HTTP/1.1\r\nIf-None-Match: ' + e_js),
		req('HEAD /big.0a1b2c.wasm HTTP/1.1'),
		req('GET /users/42 HTTP/1.1'),
		req('GET /nope.9f3a1c.wasm HTTP/1.1'),
		req('POST / HTTP/1.1'),
	]
	mut total := 0
	for r in reqs {
		total += s.respond(r)!.len
	}
	before := gc_heap_usage().total_bytes
	for i in 0 .. 10_000 {
		total += s.respond(reqs[i % reqs.len])!.len
	}
	grown := gc_heap_usage().total_bytes - before
	assert total > 0
	assert grown < 16 * 1024, 'respond allocated ${grown} bytes over 10k requests'
}
