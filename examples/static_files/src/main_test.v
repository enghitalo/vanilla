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

// range_of is parse_range as a string: `start-end` for a satisfiable range,
// else the outcome's name.
fn range_of(spec string, size i64) string {
	kind, s, e := parse_range(spec.bytes(), size)
	return if kind == .satisfiable { '${s}-${e}' } else { '${kind}' }
}

// On a 28-byte file (the README's index.html). RFC 9110 §14.1.2: a LAST at or
// past the end, or none, runs to the last byte (#294), and a SUFFIX longer
// than the file is the whole file.
fn test_parse_range() {
	assert range_of('bytes=0-8', 28) == '0-8'
	assert range_of('bytes=4-4', 28) == '4-4'
	assert range_of('bytes=10-1000', 28) == '10-27'
	assert range_of('bytes=0-27', 28) == '0-27'
	assert range_of('bytes=0-99', 28) == '0-27'
	assert range_of('bytes=10-', 28) == '10-27' // open-ended
	assert range_of('bytes=27-', 28) == '27-27'
	assert range_of('bytes=-7', 28) == '21-27' // suffix: the last 7 bytes
	assert range_of('bytes=-28', 28) == '0-27'
	assert range_of('bytes=-100', 28) == '0-27'
}

// RFC 9110 §14.1.2: unsatisfiable are a FIRST at or past the end, so any
// FIRST on an empty file, and a SUFFIX of 0.
fn test_parse_range_unsatisfiable() {
	assert range_of('bytes=500-600', 28) == 'unsatisfiable'
	assert range_of('bytes=28-', 28) == 'unsatisfiable'
	assert range_of('bytes=28-30', 28) == 'unsatisfiable'
	assert range_of('bytes=-0', 28) == 'unsatisfiable'
	assert range_of('bytes=0-', 0) == 'unsatisfiable'
	assert range_of('bytes=0-0', 0) == 'unsatisfiable'
	assert range_of('bytes=-0', 0) == 'unsatisfiable'
}

// A SUFFIX above 0 on an empty file is satisfiable (RFC 9110 §14.1.2) but
// selects no byte a 206 could carry, so it is ignored: a 200 with the empty
// file (§14.2 lets a server ignore Range on an empty representation).
fn test_parse_range_suffix_on_empty_file_is_ignored() {
	assert range_of('bytes=-5', 0) == 'ignore'
	assert range_of('bytes=-1', 0) == 'ignore'
	assert range_of('bytes=-99999999999999999999999', 0) == 'ignore'
	assert range_of('bytes=-1', 1) == '0-0' // one byte is enough for a 206
}

// Not one valid byte range: ignored, so the caller serves a 200. LAST below
// FIRST, another unit (the unit is matched lowercase), more than one range,
// a side that is not all digits, no number at all.
fn test_parse_range_ignores_invalid_specs() {
	for spec in ['bytes=900-100', 'bytes=9-3', 'items=0-9', 'Bytes=0-9', 'bytes=0-99-100',
		'bytes=0-1,5-6', 'bytes=0-1,5', 'bytes=-1,-2', 'bytes=0-0,-1', 'bytes=-', 'bytes=', 'bytes=5',
		'bytes=a-b', 'bytes=5x-10', 'bytes=0-9x', 'bytes= 7-9', 'bytes=7 -9', '-5'] {
		assert range_of(spec, 28) == 'ignore', spec
	}
	assert range_of('bytes=5-2', 0) == 'ignore' // invalid comes first, even on an empty file
}

// RFC 9110 §14.1.2: a recipient expects numbers of any length. Past max_i64
// a position saturates instead of wrapping (2^64 would wrap to offset 0).
fn test_parse_range_saturates_huge_numbers() {
	assert range_of('bytes=18446744073709551616-', 28) == 'unsatisfiable'
	assert range_of('bytes=99999999999999999999999-99999999999999999999999', 28) == 'unsatisfiable'
	assert range_of('bytes=0-18446744073709551615', 28) == '0-27'
	assert range_of('bytes=-18446744073709551616', 28) == '0-27'
	assert range_of('bytes=18446744073709551616-0', 28) == 'ignore' // LAST < FIRST
	assert parse_dec('9223372036854775807'.bytes(), 0, 19) == max_i64
	assert parse_dec('9223372036854775808'.bytes(), 0, 19) == max_i64
	assert parse_dec('922337203685477580'.bytes(), 0, 18) == 922337203685477580
	assert parse_dec('0'.bytes(), 0, 1) == 0
	assert parse_dec('12'.bytes(), 0, 0) == -1 // empty window
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

// RFC 9110 §14.2 defines range handling for GET only, and a server MUST
// ignore Range on any other method: a HEAD with a Range, whatever it asks
// for, gets exactly the plain HEAD response (200 headers, no body).
fn test_head_ignores_range() {
	for path in ['/index.html', '/empty.txt'] {
		plain := serve('HEAD ${path} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
		assert plain.starts_with('HTTP/1.1 200 OK\r\n'), path
		assert plain.ends_with('\r\n\r\n'), path
		for rng in ['bytes=4-8', 'bytes=10-1000', 'bytes=-3', 'bytes=500-600', 'bytes=-0', 'bytes=0-',
			'bytes=-5', 'bytes=9-3', 'bytes=0-1,5-6', 'items=0-4'] {
			out := serve('HEAD ${path} HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
			assert out == plain, '${path} ${rng}'
		}
	}
}

// A LAST past the end of the file runs to its last byte (#294), and so does a
// SUFFIX longer than the file: a 206, never a 200 of the whole file.
fn test_range_end_past_the_file_is_clamped() {
	etag := hex16(wyhash.wyhash_c(fixture_body.str, u64(fixture_body.len), 0))[..].bytestr()
	out :=
		serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=10-1000\r\n\r\n'.bytes()).bytestr()
	assert out == 'HTTP/1.1 206 Partial Content\r\nContent-Type: text/html; charset=utf-8\r\nContent-Range: bytes 10-13/14\r\nAccept-Ranges: bytes\r\nContent-Length: 4\r\nETag: "${etag}"\r\n\r\n${fixture_body[10..]}'
	for rng in ['bytes=0-13', 'bytes=0-99', 'bytes=0-', 'bytes=-14', 'bytes=-100'] {
		whole :=
			serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
		assert whole.starts_with('HTTP/1.1 206 Partial Content\r\n'), rng
		assert whole.contains('\r\nContent-Range: bytes 0-13/14\r\n'), rng
		assert whole.contains('\r\nContent-Length: 14\r\n'), rng
		assert whole.ends_with('"\r\n\r\n' + fixture_body), rng
	}
}

// A GET whose range is unsatisfiable gets 416 with the file's length and no
// body: a FIRST at or past the end (any FIRST on an empty file), a SUFFIX of
// 0. A huge FIRST saturates rather than wrapping to 0.
fn test_unsatisfiable_range_416() {
	want := 'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */14\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
	for rng in ['bytes=500-600', 'bytes=14-', 'bytes=-0', 'bytes=18446744073709551616-'] {
		out := serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
		assert out == want, rng
	}
	empty := 'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */0\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
	for rng in ['bytes=0-', 'bytes=0-0', 'bytes=-0'] {
		out := serve('GET /empty.txt HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
		assert out == empty, rng
	}
}

// A SUFFIX above 0 on the empty file is ignored (parse_range says why): the
// GET gets the plain 200 of the empty file, byte for byte.
fn test_suffix_on_empty_file_gets_200() {
	plain := serve('GET /empty.txt HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert plain.starts_with('HTTP/1.1 200 OK\r\n')
	assert plain.contains('\r\nContent-Length: 0\r\n')
	for rng in ['bytes=-5', 'bytes=-1'] {
		out := serve('GET /empty.txt HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
		assert out == plain, rng
	}
}

// Range is evaluated after If-None-Match (RFC 9110 §14.2): a cached copy that
// is still current gets its 304, even when the range would get a 416.
fn test_if_none_match_wins_over_416() {
	etag := hex16(wyhash.wyhash_c(fixture_body.str, u64(fixture_body.len), 0))[..].bytestr()
	out := serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=500-600\r\nIf-None-Match: "${etag}"\r\n\r\n'.bytes()).bytestr()
	assert out == 'HTTP/1.1 304 Not Modified\r\nETag: "${etag}"\r\n\r\n'
	stale := serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=500-600\r\nIf-None-Match: "0000000000000000"\r\n\r\n'.bytes()).bytestr()
	assert stale.starts_with('HTTP/1.1 416 Range Not Satisfiable\r\n')
}

// A spec that is not one valid byte range is ignored (RFC 9110 §14.2 allows
// it): the whole file comes back as a 200. A LAST below its FIRST, more than
// one range, a malformed spec, another unit.
fn test_invalid_range_falls_back_to_200() {
	for rng in ['bytes=900-100', 'bytes=9-3', 'bytes=0-1,5-6', 'bytes=0-0,-1', 'bytes=a-b', 'bytes=-',
		'items=0-4'] {
		out :=
			serve('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: ${rng}\r\n\r\n'.bytes()).bytestr()
		assert out.starts_with('HTTP/1.1 200 OK\r\n'), rng
		assert out.contains('\r\nContent-Length: 14\r\n'), rng
		assert out.ends_with(fixture_body), rng
	}
	// An empty file is no exception: an invalid spec on it is ignored too.
	out := serve('GET /empty.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=5-2\r\n\r\n'.bytes()).bytestr()
	assert out.starts_with('HTTP/1.1 200 OK\r\n')
	assert out.contains('\r\nContent-Length: 0\r\n')
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

// A pipelined response already in `out` is left alone: a 304 or a 416 rolls
// back only what this request appended, and a 206 moves only its own window.
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
	out = earlier.bytes()
	handle('GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=500-600\r\n\r\n'.bytes(), mut
		out, -1, fresh_state(), mut event_loop)
	assert out.bytestr() == earlier +
		'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */14\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
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

// Every outcome — 200, 206 (a clamped one too), 304, 416, HEAD (with a Range
// it ignores too), an ignored Range, 404 for each refusal, 405, 400 — runs
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
			'GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=10-1000\r\n\r\n',
			'GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=500-600\r\n\r\n',
			'GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=-0\r\n\r\n',
			'HEAD /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=-0\r\n\r\n',
			'GET /empty.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-\r\n\r\n',
			'GET /empty.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=-5\r\n\r\n',
			'GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=0-1,5-6\r\n\r\n',
			'GET /index.html HTTP/1.1\r\nHost: x\r\nRange: bytes=99999999999999999999999-\r\n\r\n',
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
