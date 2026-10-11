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
import hash as wyhash

fn C.mkfifo(path &char, mode u32) int

const fixture_body = '<h1>hello</h1>' // 14 bytes
const secret_body = 'SECRET-OUTSIDE-WEB-ROOT'
const test_root = os.join_path(os.temp_dir(), 'vanilla_static_files_test_${os.getpid()}')

// The fixture: ./public (the web root) and, outside it, a sibling ./public2
// that shares the root's name as a prefix (#228). Symlinks inside the root
// point at the secret (out) and at the index (in). A FIFO, a directory and an
// empty file sit in the root too: none of them is a file with bytes to serve.
fn testsuite_begin() {
	os.mkdir_all(os.join_path(test_root, 'public', 'sub')) or { panic(err) }
	os.mkdir_all(os.join_path(test_root, 'public2')) or { panic(err) }
	os.write_file(os.join_path(test_root, 'public', 'index.html'), fixture_body) or { panic(err) }
	os.write_file(os.join_path(test_root, 'public', 'empty.txt'), '') or { panic(err) }
	os.write_file(os.join_path(test_root, 'public2', 'secret.txt'), secret_body) or { panic(err) }
	os.chdir(test_root) or { panic(err) }
	os.symlink('../public2/secret.txt', os.join_path('public', 'escape.txt')) or { panic(err) }
	os.symlink('index.html', os.join_path('public', 'alias.html')) or { panic(err) }
	assert C.mkfifo(c'public/pipe', 0o600) == 0
}

fn testsuite_end() {
	os.chdir(os.temp_dir()) or {}
	os.rmdir_all(test_root) or {}
}

// fresh_state is a worker's State, as make_state builds it in main().
fn fresh_state() &State {
	return new_state(resolve(web_root) or { panic('the web root must resolve') })
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req, mut out, -1, fresh_state(), mut event_loop) == .done
	return out
}

// safe is safe_path as a string: the resolved path, or none.
fn safe(url string) ?string {
	mut st := fresh_state()
	n := safe_path(mut st, url.bytes())?
	return unsafe { tos(&st.resolved[0], n) }.clone()
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
	assert safe('/../../etc/passwd') == none
	assert safe('/../../../root/.ssh/id_rsa') == none
	// a normal path resolves to something inside the root
	p := safe('/index.html') or { '' }
	assert p != ''
}

// A sibling directory whose name starts with the root's name is outside the
// root: containment is checked on a path-segment boundary (#228).
fn test_sibling_with_root_prefix_refused() {
	assert safe('/../public2/secret.txt') == none
	assert safe('/../public2') == none
	assert safe('/../public') == none // the root itself is no file
	assert safe('') == none
	assert safe('/') == none
}

fn test_symlink_out_of_root_refused() {
	assert safe('/escape.txt') == none
	p := safe('/alias.html') or { '' } // a link that stays inside is fine
	assert p.ends_with('index.html')
}

// `..` is resolved the way open(2) would, then the containment check runs on
// the result: inside the root it is fine, past it it is refused.
fn test_dot_segments_resolve_before_the_check() {
	p := safe('/sub/../index.html') or { '' }
	assert p.ends_with('/public/index.html')
	assert safe('/sub/../../public2/secret.txt') == none
	back_in := safe('/sub/../../public/index.html') or { '' } // through the root's own name
	assert back_in == p
}

// A NUL would end the C string early, and realpath would resolve a path the
// request did not name: refused.
fn test_nul_in_path_refused() {
	assert safe('/index.html\x00.png') == none
	assert safe('/\x00/../../etc/passwd') == none
}

// A path that cannot fit in PATH_MAX is refused before it is copied: the
// per-worker scratch never grows past its size.
fn test_overlong_path_refused() {
	mut st := fresh_state()
	cap := st.path.cap
	long := '/' + 'a'.repeat(st.resolved.len)
	assert safe_path(mut st, long.bytes()) == none
	assert st.path.cap == cap
}

// A path that does not resolve is refused, never handed back unresolved, as
// os.real_path does: under an absolute root that unresolved path would pass
// the containment check.
fn test_unresolvable_path_refused() {
	abs := os.join_path(test_root, 'public', 'missing.html')
	assert os.real_path(abs) == abs // what resolve must not do
	assert resolve(abs) == none
	os.symlink('loop.html', os.join_path('public', 'loop.html')) or { panic(err) }
	assert resolve(os.join_path(test_root, 'public', 'loop.html')) == none // ELOOP
	assert safe('/loop.html') == none
	root := resolve('public') or { '' }
	assert root.len > 0 && os.is_abs_path(root)
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

// The ETag placeholder is filled with the wyhash of the bytes served.
fn test_etag_is_the_body_hash() {
	etag := hex16(wyhash.wyhash_c(fixture_body.str, u64(fixture_body.len), 0))
	out := serve('GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out == 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 14\r\nAccept-Ranges: bytes\r\nETag: "${etag[..].bytestr()}"\r\nCache-Control: public, max-age=3600\r\nConnection: keep-alive\r\n\r\n${fixture_body}'
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

fn test_empty_file_200() {
	out := serve('GET /empty.txt HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('200 OK')
	assert out.contains('Content-Length: 0\r\n')
	assert out.ends_with('\r\n\r\n')
}

fn test_unknown_file_404() {
	out := serve('GET /nope.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
}

// Only regular files are served. A FIFO would block a plain open() until a
// writer shows up, so this test hangs if open() loses O_NONBLOCK.
fn test_directory_and_fifo_get_404() {
	assert serve('GET /sub HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr().contains('404 Not Found')
	assert serve('GET /sub/ HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr().contains('404 Not Found')
	assert serve('GET /pipe HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr().contains('404 Not Found')
	assert serve('GET /index.html/ HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr().contains('404 Not Found')
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

// A window from the middle is moved down to where the body begins: exactly
// its bytes follow the header block.
fn test_range_window_from_the_middle() {
	out :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=4-8\r\n\r\n'.bytes()).bytestr()
	assert out.contains('Content-Range: bytes 4-8/${fixture_body.len}')
	assert out.ends_with('"\r\n\r\n' + fixture_body[4..9])
	suffix :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=-3\r\n\r\n'.bytes()).bytestr()
	assert suffix.ends_with('"\r\n\r\n' + fixture_body[11..])
}

fn test_head_range_sends_headers_only() {
	out :=
		serve('HEAD /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=4-8\r\n\r\n'.bytes()).bytestr()
	assert out.contains('206 Partial Content')
	assert out.contains('Content-Length: 5')
	assert out.ends_with('"\r\n\r\n')
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
	assert out == 'HTTP/1.1 304 Not Modified\r\nETag: ${etag}\r\n\r\n'
}

// A pipelined response already in `out` is left alone: a 304 rolls back only
// what this request appended, and a 206 moves only its own window.
fn test_earlier_responses_in_out_are_kept() {
	earlier := 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'
	etag := hex16(wyhash.wyhash_c(fixture_body.str, u64(fixture_body.len), 0))[..].bytestr()
	mut event_loop := core.EventLoop{}
	mut out := earlier.bytes()
	handle('GET /index.html HTTP/1.1\r\nHost: x\r\nIf-None-Match: "${etag}"\r\n\r\n'.bytes(), mut
		out, -1, fresh_state(), mut event_loop)
	assert out.bytestr() == earlier + 'HTTP/1.1 304 Not Modified\r\nETag: "${etag}"\r\n\r\n'
	out = earlier.bytes()
	handle('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=4-8\r\n\r\n'.bytes(), mut
		out, -1, fresh_state(), mut event_loop)
	got := out.bytestr()
	assert got.starts_with(earlier + 'HTTP/1.1 206 Partial Content\r\n')
	assert got.ends_with('"\r\n\r\n' + fixture_body[4..9])
}

fn test_path_traversal_gets_404() {
	out := serve('GET /../../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
}

fn test_sibling_with_root_prefix_gets_404() {
	out := serve('GET /../public2/secret.txt HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
	assert !out.contains(secret_body)
}

fn test_symlink_out_of_root_gets_404() {
	out := serve('GET /escape.txt HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
	assert !out.contains(secret_body)
	inside := serve('GET /alias.html HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert inside.contains('200 OK')
	assert inside.ends_with(fixture_body)
}

fn test_nul_in_path_gets_404() {
	out := serve('GET /index.html\x00.png HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.contains('404 Not Found')
}

fn test_malformed_request_errors() {
	// Malformed input must append the canned 400 and close the connection.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, fresh_state(), mut event_loop) == .close
	assert out.bytestr().contains('400 Bad Request')
}

// ---- the point of the design: serving allocates nothing ----------------------

// Every outcome — 200, 206, 304, HEAD, 404 for each refusal, 405, 400 — runs
// 20k times through one worker State and one reused `out`, as a worker would
// serve them; the collector's lifetime allocation counter must not move.
// (Under `-gc none`, vanilla's production build, the same allocation would be
// a permanent leak.) Each request still opens and closes a file descriptor.
fn test_serving_allocates_nothing() {
	$if gcboehm ? {
		etag := hex16(wyhash.wyhash_c(fixture_body.str, u64(fixture_body.len), 0))[..].bytestr()
		reqs := [
			'GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
			'HEAD /index.html HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /index.html?v=1 HTTP/1.1\r\nHost: x\r\nRange: bytes=4-8\r\n\r\n',
			'GET /index.html HTTP/1.1\r\nHost: x\r\nIf-None-Match: "${etag}"\r\n\r\n',
			'GET /alias.html HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /empty.txt HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /nope.html HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /../public2/secret.txt HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /escape.txt HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /sub HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /pipe HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /index.html HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'garbage',
		].map(it.bytes())
		st := fresh_state()
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, st, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, st, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}
