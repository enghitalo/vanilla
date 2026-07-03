module main

// Static file serving — reference design.
//
// This is deceptively deep: doing it correctly means MIME detection, byte
// Range requests (how video/audio seek works), conditional GET (ETag /
// If-Modified-Since for caching), and — above all — path-traversal safety.
//
// SECURITY FIRST
//   The single most important line in a static server is the one that prevents
//   `GET /../../etc/passwd`. We resolve the requested path against the root and
//   verify the result is still inside the root. Never trust the URL path.
//
// WORKS TODAY: everything here is plain file I/O + header building — read into a
// []u8 and write it out, which is the clearest way to show the logic.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - Method routing, the query strip and the If-None-Match check compare
//     bytes IN PLACE by offsets — no `.to_string()`, no `buf[a..b]`
//     slice-marking, no `${}` interpolation per request.
//   - Responses append straight into `out`: consts for 404/405; `ws`/`wi`
//     framing for 200/206/304; the file bytes and the range window are
//     appended as direct pointer copies, never via `content[a..b]`.
//   - The ETag is the md5 digest hex-encoded into a STACK scratch (`hex32`) —
//     no `.hex()` string per request. Hashing the whole file per request is
//     O(filesize) BY DESIGN — it is the conditional-GET pedagogy; for
//     precomputed validators use `http_server.static_assets`.
//   - The URL path reaches `safe_path` as a zero-copy `tos` VIEW; the os path
//     APIs (norm_path/join_path/abs_path) are string-typed and make their own
//     copies internally — the documented teaching trade-off (rule 3: don't
//     contort a path that is disk-bound anyway).
//
// ZERO-COPY IS NOW AVAILABLE: large files no longer have to bounce through a
// userspace []u8. The epoll core can stream a file straight to the socket with
// `sendfile(2)` (EPOLLOUT-driven, so a 4 GB file never sits in RAM) — a handler
// hands the file off via `core.queue_file(fd, off, len)`. The reusable
// `http_server.static_assets` module does exactly this for files past a size
// threshold; see `examples/static_assets`. This example keeps the explicit
// read-into-RAM path for teaching.
import http_server
import http_server.http1_1.request_parser
import os
import strconv
import crypto.md5

const web_root = './public'

// ---- static responses (consts — the error paths append, never build) --------
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n\r\n'.bytes()

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) --------------------------
// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// path_len_without_query returns the path length up to (not including) '?' —
// the query strip happens on the path VIEW by offsets, no substr.
@[direct_array_access]
fn path_len_without_query(buf []u8, s request_parser.Slice) int {
	for i in 0 .. s.len {
		if buf[s.start + i] == `?` {
			return i
		}
	}
	return s.len
}

// ---- MIME --------------------------------------------------------------------
// Minimal MIME table. A fuller one (or libmagic) covers more types.
struct MimeEntry {
	ext   string // includes the dot, lowercase
	ctype string
}

const mime_table = [
	MimeEntry{'.html', 'text/html; charset=utf-8'},
	MimeEntry{'.css', 'text/css'},
	MimeEntry{'.js', 'application/javascript'},
	MimeEntry{'.json', 'application/json'},
	MimeEntry{'.png', 'image/png'},
	MimeEntry{'.jpg', 'image/jpeg'},
	MimeEntry{'.jpeg', 'image/jpeg'},
	MimeEntry{'.svg', 'image/svg+xml'},
	MimeEntry{'.mp4', 'video/mp4'},
	MimeEntry{'.woff2', 'font/woff2'},
]

// ext_eq compares the extension window (dot included) case-insensitively.
// The fold is a GUARDED A-Z lowering, not a blanket `| 0x20`: these needles
// contain digits and '.', and `| 0x20` on non-letters aliases control bytes
// (0x14 would match `4` — see examples/compression on why lowercase-LETTER
// needles are load-bearing for the blanket trick).
@[direct_array_access]
fn ext_eq(path string, dot int, ext string) bool {
	if path.len - dot != ext.len {
		return false
	}
	for i in 0 .. ext.len {
		mut c := path[dot + i]
		if c >= `A` && c <= `Z` {
			c |= 0x20
		}
		if c != ext[i] {
			return false
		}
	}
	return true
}

// mime_type maps the file extension to a Content-Type by scanning back to the
// last '.' of the basename and comparing in place — no os.file_ext + .to_lower()
// (two string allocations per request in the old version). Returns consts only.
@[direct_array_access]
fn mime_type(path string) string {
	mut dot := -1
	for i := path.len - 1; i >= 0; i-- {
		c := path[i]
		if c == `.` {
			dot = i
			break
		}
		if c == `/` || c == u8(92) { // 92 = backslash, the Windows separator
			break
		}
	}
	if dot >= 0 {
		for e in mime_table {
			if ext_eq(path, dot, e.ext) {
				return e.ctype
			}
		}
	}
	return 'application/octet-stream'
}

// SECURITY: resolve `url_path` under `web_root` and confirm it cannot escape.
fn safe_path(url_path string) ?string {
	// The core does NO percent-decoding — the path arrives raw off the wire.
	// An encoded traversal (`%2e%2e`) is never turned back into `..` by any
	// upstream layer, so it simply fails the file lookup; the literal `..` is
	// what this guard refuses. The query string was already stripped by
	// offsets in handle().
	clean := os.norm_path(os.join_path(web_root, url_path.trim_left('/')))
	root_abs := os.abs_path(web_root)
	cand_abs := os.abs_path(clean)
	if !cand_abs.starts_with(root_abs) {
		return none // traversal attempt — refuse
	}
	return cand_abs
}

// ---- ETag --------------------------------------------------------------------
const hex_digits = '0123456789abcdef'

// hex32 encodes the 16-byte md5 digest as 32 lowercase hex chars in a fixed
// (stack) array — replaces `.hex()`, which allocates a string per request.
@[direct_array_access]
fn hex32(digest []u8) [32]u8 {
	mut buf := [32]u8{}
	if digest.len != 16 {
		return buf
	}
	for i in 0 .. 16 {
		buf[i * 2] = hex_digits[digest[i] >> 4]
		buf[i * 2 + 1] = hex_digits[digest[i] & 0xF]
	}
	return buf
}

// etag_matches compares the If-None-Match value IN PLACE against `"<32 hex>"`
// (34 bytes). Exact match only — same semantics as the old string compare:
// no weak validators, no comma-separated lists.
@[direct_array_access]
fn etag_matches(buf []u8, s request_parser.Slice, etag [32]u8) bool {
	if s.len != 34 || buf[s.start] != `"` || buf[s.start + 33] != `"` {
		return false
	}
	for i in 0 .. 32 {
		if buf[s.start + 1 + i] != etag[i] {
			return false
		}
	}
	return true
}

// ---- Range -------------------------------------------------------------------
// dec_prefix parses the leading decimal digits of buf[from..to] (0 when none),
// mirroring string.i64()'s ignore-the-tail behavior.
@[direct_array_access]
fn dec_prefix(buf []u8, from int, to int) i64 {
	mut v := i64(0)
	for i := from; i < to; i++ {
		c := buf[i]
		if c < `0` || c > `9` {
			break
		}
		v = v * 10 + int(c - `0`)
	}
	return v
}

// Parse "Range: bytes=START-END" -> (start, end) inclusive, clamped to size.
// Operates on a byte VIEW of the header value — no substr, no split(), no
// intermediate strings. Semantics identical to the previous string version:
// exactly one '-'; empty left side = suffix range ("bytes=-N" -> last N
// bytes); empty right side = open-ended ("bytes=N-" -> to the last byte);
// start > end or end past the file rejects (the caller falls back to 200).
@[direct_array_access]
fn parse_range(h []u8, size i64) ?(i64, i64) {
	prefix := 'bytes='
	if h.len < prefix.len {
		return none
	}
	for i in 0 .. prefix.len {
		if h[i] != prefix[i] {
			return none
		}
	}
	// Exactly one '-' separates the two sides (split-free scan).
	mut dash := -1
	for i in prefix.len .. h.len {
		if h[i] == `-` {
			if dash >= 0 {
				return none
			}
			dash = i
		}
	}
	if dash < 0 {
		return none
	}
	mut start := i64(0)
	mut end := size - 1
	if dash == prefix.len {
		// suffix range "bytes=-N": the LAST N bytes
		n := dec_prefix(h, dash + 1, h.len)
		start = if n >= size { i64(0) } else { size - n }
		end = size - 1
	} else {
		start = dec_prefix(h, prefix.len, dash)
		end = if dash == h.len - 1 { size - 1 } else { dec_prefix(h, dash + 1, h.len) }
	}
	if start < 0 || end >= size || start > end {
		return none
	}
	return start, end
}

fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	// Method routing IN PLACE over the request buffer — no `.to_string()`.
	is_get := slice_eq(req.buffer, req.method, 'GET')
	if !is_get && !slice_eq(req.buffer, req.method, 'HEAD') {
		out << resp_405
		return
	}

	// Strip the query string by SHRINKING the path view — offsets, no substr.
	plen := path_len_without_query(req.buffer, req.path)
	// The os path APIs need a string, so hand safe_path a zero-copy `tos`
	// VIEW of the path bytes — trim_left/join_path/norm_path copy internally
	// and the view never escapes this call (justified per rule 3: the lookup
	// below is disk-bound).
	mut url_path := ''
	if plen == 1 && req.buffer[req.path.start] == `/` {
		url_path = '/index.html' // a bare '/' serves the index
	} else if plen > 0 {
		url_path = unsafe { tos(&req.buffer[req.path.start], plen) }
	}

	fs_path := safe_path(url_path) or {
		out << resp_404
		return
	}
	if !os.is_file(fs_path) {
		out << resp_404
		return
	}
	content := os.read_bytes(fs_path) or {
		out << resp_404
		return
	}
	ctype := mime_type(fs_path)
	// ETag = md5 of the content, hex-encoded into a stack scratch (see header).
	etag := hex32(md5.sum(content))

	// Conditional GET: if the client's cached ETag matches, save the bytes.
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches(req.buffer, inm, etag) {
			ws(mut out, 'HTTP/1.1 304 Not Modified\r\nETag: "')
			unsafe { out.push_many(&etag[0], 32) }
			ws(mut out, '"\r\n\r\n')
			return
		}
	}

	// Range request: serve 206 Partial Content (this is how seeking works).
	if rng := req.get_header_value_slice('Range') {
		if rng.len > 0 {
			rview := unsafe { (&req.buffer[rng.start]).vbytes(rng.len) } // view
			if start, end := parse_range(rview, content.len) {
				ws(mut out, 'HTTP/1.1 206 Partial Content\r\nContent-Type: ')
				ws(mut out, ctype)
				ws(mut out, '\r\nContent-Range: bytes ')
				wi(mut out, start)
				out << u8(`-`)
				wi(mut out, end)
				out << u8(`/`)
				wi(mut out, content.len)
				ws(mut out, '\r\nAccept-Ranges: bytes\r\nContent-Length: ')
				wi(mut out, end + 1 - start)
				ws(mut out, '\r\nETag: "')
				unsafe { out.push_many(&etag[0], 32) }
				ws(mut out, '"\r\n\r\n')
				if is_get {
					// The range window is appended as a direct pointer copy —
					// no content[start..end+1] slice-marking. In-bounds and
					// non-empty: parse_range guarantees 0 <= start <= end < len.
					unsafe { out.push_many(&content[int(start)], int(end + 1 - start)) }
				}
				return
			}
		}
	}

	ws(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, content.len)
	ws(mut out, '\r\nAccept-Ranges: bytes\r\nETag: "') // advertise range support
	unsafe { out.push_many(&etag[0], 32) }
	ws(mut out, '"\r\nCache-Control: public, max-age=3600\r\nConnection: keep-alive\r\n\r\n')
	if is_get {
		out << content // HEAD gets the headers only
	}
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: handle
	})!
	// One-time init prints — `${}` is fine here, nothing below runs per request.
	println('Static server on http://localhost:3000/  (root: ${web_root})')
	println('For zero-copy large-file serving (sendfile(2)), use http_server.static_assets — see examples/static_assets.')
	server.run()
}
