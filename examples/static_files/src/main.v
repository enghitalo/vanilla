module main

// Static file serving — reference design.
//
// This is deceptively deep: doing it correctly means MIME detection, byte
// Range requests (how video/audio seek works), conditional GET (ETag /
// If-Modified-Since for caching), and — above all — path-traversal safety.
//
// SECURITY FIRST
//   The single most important line in a static server is the one that prevents
//   `GET /../../etc/passwd`. We resolve the requested path against the root
//   (symlinks included) and verify the result is still inside the root, on a
//   path-segment boundary: `./public2` is not inside `./public`. Never trust
//   the URL path.
//
// POSIX (Linux, macOS): realpath(3) into a caller buffer, open(2) + fstat(2),
// and pread(2) through core.append_file_region.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3/§4, docs/V_PERF_TOOLBOX.md):
// no allocation per request.
//   - Method routing, the query strip and the If-None-Match check compare
//     bytes IN PLACE by offsets — no `.to_string()`, no `buf[a..b]`
//     slice-marking, no `${}` interpolation per request.
//   - The web root is resolved ONCE, in main. Each worker's State (make_state)
//     holds it with two path buffers that every request reuses: root + URL
//     path + NUL is built in one, and realpath(3) writes the resolved path
//     into the other (its caller-buffer form: no malloc, no string). The
//     containment check reads a `tos` view of that buffer.
//   - Responses append straight into `out`: consts for 404/405; `core.append_str`/`wi`
//     framing for 200/206/304. The file is read with pread(2) straight into
//     `out`, after its header block (core.append_file_region): no
//     os.read_bytes, no copy. The ETag, which hashes the body, fills a
//     16-byte placeholder left in that header block; a 304 rolls `out` back
//     to where this response began (`out.len = mark`), a 206 moves its window
//     down over the bytes before it, and HEAD drops the body.
//   - The ETag is a 64-bit wyhash hex-encoded into a STACK scratch (`hex16`) —
//     no `.hex()` string per request. Hashing the whole file per request is
//     O(filesize) BY DESIGN — it is the conditional-GET pedagogy; for
//     precomputed validators use `server.static_assets`.
//
// ZERO-COPY IS NOW AVAILABLE: large files no longer have to bounce through a
// userspace []u8. The epoll core can stream a file straight to the socket with
// `sendfile(2)` (EPOLLOUT-driven, so a 4 GB file never sits in RAM) — a handler
// hands the file off via `core.queue_file(fd, off, len)`. The reusable
// `server.static_assets` module does exactly this for files past a size
// threshold; see `examples/spa_static_assets`. This example reads each file
// into `out` instead, because its ETag hashes the body on every request.
import server
import core
import http1_1.request_parser
import http1_1.response
import os
import strconv
import hash as wyhash

#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

fn C.fstat(fd int, buf &C.stat) int

const web_root = './public'
const index_path = '/index.html' // what a bare '/' serves

// State is one worker's (make_state): the web root, resolved once at startup,
// and the two path buffers every request reuses. Only its worker touches it.
struct State {
	root string // web_root resolved: absolute, no symlinks, no trailing '/'
mut:
	path     []u8 // root + '/' + URL path + NUL: realpath's input
	resolved []u8 // realpath's output: PATH_MAX bytes, as it requires
}

fn new_state(root string) &State {
	return &State{
		root:     root
		path:     []u8{cap: C.PATH_MAX}
		resolved: []u8{len: C.PATH_MAX}
	}
}

// ---- static responses (consts — the error paths append, never build) --------
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n\r\n'

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) --------------------------
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

// SECURITY: resolve `url_path` under the root into st.resolved and return the
// resolved path's length, or none when it does not resolve inside the root.
fn safe_path(mut st State, url_path []u8) ?int {
	// The core does NO percent-decoding — the path arrives raw off the wire.
	// An encoded traversal (`%2e%2e`) is never turned back into `..` by any
	// upstream layer, so it simply fails the file lookup; a literal `..` is
	// resolved by realpath, and the containment check below refuses where it
	// leads. The query string was already stripped by offsets in handle().
	//
	// realpath resolves `..` and symlinks the way open(2) would, so a symlink
	// inside the root is followed only when its target is inside the root too,
	// and a path that does not resolve (missing, a symlink loop, a target past
	// PATH_MAX) is refused: a 404 either way. This guards against requests,
	// not local writers: the check and the open below are two walks of the
	// path, and a writer inside the root can swap a directory for a symlink in
	// between (closing that takes openat2's RESOLVE_BENEATH).
	//
	// root + '/' + path + NUL must fit in PATH_MAX: a longer path cannot
	// resolve anyway, and refusing it first keeps st.path at its size.
	if st.root.len + url_path.len + 2 > st.resolved.len {
		return none
	}
	// A NUL would end the C string early, so realpath would resolve a shorter
	// path than the one requested: refuse it.
	if url_path.len > 0 && unsafe { C.memchr(url_path.data, 0, usize(url_path.len)) } != nil {
		return none
	}
	unsafe {
		st.path.len = 0
		st.path.push_many(st.root.str, st.root.len)
	}
	st.path << u8(`/`)
	if url_path.len > 0 {
		unsafe { st.path.push_many(url_path.data, url_path.len) }
	}
	st.path << u8(0)
	if C.realpath(&char(st.path.data), &char(st.resolved.data)) == unsafe { nil } {
		return none // fail closed: never fall back to the unresolved path
	}
	cand := unsafe { tos(&st.resolved[0], vstrlen(&st.resolved[0])) }
	// Containment on a path-segment boundary: the candidate must be the root
	// followed by a separator. A bare prefix test lets a sibling that shares
	// the root's name through (`/../public2/secret.txt` for `./public`, #228).
	if !(cand.len > st.root.len && cand.starts_with(st.root) && cand[st.root.len] == `/`) {
		return none // traversal attempt — refuse
	}
	return cand.len
}

// resolve is os.real_path that fails closed, for the web root at startup.
// When realpath(3) fails, os.real_path returns its input unchanged: a path that
// may still lead through a symlink, and that passes the containment check
// whenever the root is absolute. Here a path that does not resolve (missing, a
// symlink loop, a target past PATH_MAX) is refused.
fn resolve(path string) ?string {
	p := C.realpath(&char(path.str), unsafe { nil })
	if p == unsafe { nil } {
		return none
	}
	s := unsafe { cstring_to_vstring(p) }
	unsafe { C.free(p) }
	return s
}

// ---- ETag --------------------------------------------------------------------
const hex_digits = '0123456789abcdef'

// hex16 encodes the 64-bit wyhash as 16 lowercase hex chars in a fixed
// (stack) array — replaces `.hex()`, which allocates a string per request.
@[direct_array_access]
fn hex16(h u64) [16]u8 {
	mut buf := [16]u8{}
	for i in 0 .. 16 {
		buf[i] = hex_digits[(h >> ((15 - i) * 4)) & 0xF]
	}
	return buf
}

// etag_matches compares the If-None-Match value IN PLACE against `"<16 hex>"`
// (18 bytes). Exact match only — same semantics as the old string compare:
// no weak validators, no comma-separated lists.
@[direct_array_access]
fn etag_matches(buf []u8, s request_parser.Slice, etag [16]u8) bool {
	if s.len != 18 || buf[s.start] != `"` || buf[s.start + 17] != `"` {
		return false
	}
	for i in 0 .. 16 {
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

fn handle(req_buffer []u8, mut out []u8, _client_fd int, worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}
	// Method routing IN PLACE over the request buffer — no `.to_string()`.
	// Every view below is taken from `req_buffer`, the handler's own
	// parameter, never from `req.buffer`: a view of `req.buffer` handed on to
	// a callee moves `req` to the heap (docs/V_PERF_TOOLBOX.md).
	is_get := slice_eq(req_buffer, req.method, 'GET')
	if !is_get && !slice_eq(req_buffer, req.method, 'HEAD') {
		core.append_str(mut out, resp_405)
		return .done
	}
	mut st := unsafe { &State(worker_state) }

	// Strip the query string by SHRINKING the path view — offsets, no substr.
	plen := path_len_without_query(req_buffer, req.path)
	mut url_path := []u8{}
	if plen == 1 && req_buffer[req.path.start] == `/` {
		url_path = unsafe { index_path.str.vbytes(index_path.len) }
	} else if plen > 0 {
		url_path = unsafe { (&req_buffer[req.path.start]).vbytes(plen) }
	}
	n := safe_path(mut st, url_path) or {
		core.append_str(mut out, resp_404)
		return .done
	}
	// O_NONBLOCK: a FIFO in the root cannot block the worker in open() (on a
	// regular file it changes nothing). fstat on the opened fd then refuses
	// anything but a regular file, with no gap between the check and the read.
	fd := C.open(&char(st.resolved.data), C.O_RDONLY | C.O_NONBLOCK | C.O_CLOEXEC)
	if fd < 0 {
		core.append_str(mut out, resp_404)
		return .done
	}
	defer {
		C.close(fd)
	}
	mut sb := C.stat{}
	if C.fstat(fd, &sb) != 0 || sb.st_mode & os.s_ifmt != os.s_ifreg {
		core.append_str(mut out, resp_404)
		return .done
	}
	size := i64(sb.st_size)
	ctype := mime_type(unsafe { tos(&st.resolved[0], n) })

	// Range request: serve 206 Partial Content (this is how seeking works).
	// It needs only the size, so the status line is known before the body.
	mut start := i64(0)
	mut end := size - 1
	mut partial := false
	if rng := req.get_header_value_slice('Range') {
		if rng.len > 0 {
			rview := unsafe { (&req_buffer[rng.start]).vbytes(rng.len) } // view
			if s, e := parse_range(rview, size) {
				start, end, partial = s, e, true
			}
		}
	}

	// The header block goes first, with a 16-byte placeholder for the ETag,
	// which hashes the body read after it.
	mark := out.len
	mut tag_at := 0
	if partial {
		core.append_str(mut out, 'HTTP/1.1 206 Partial Content\r\nContent-Type: ')
		core.append_str(mut out, ctype)
		core.append_str(mut out, '\r\nContent-Range: bytes ')
		wi(mut out, start)
		out << u8(`-`)
		wi(mut out, end)
		out << u8(`/`)
		wi(mut out, size)
		core.append_str(mut out, '\r\nAccept-Ranges: bytes\r\nContent-Length: ')
		wi(mut out, end + 1 - start)
		core.append_str(mut out, '\r\nETag: "')
		tag_at = out.len
		unsafe { out.grow_len(16) }
		core.append_str(mut out, '"\r\n\r\n')
	} else {
		core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: ')
		core.append_str(mut out, ctype)
		core.append_str(mut out, '\r\nContent-Length: ')
		wi(mut out, size)
		core.append_str(mut out, '\r\nAccept-Ranges: bytes\r\nETag: "') // advertise range support
		tag_at = out.len
		unsafe { out.grow_len(16) }
		core.append_str(mut out, '"\r\nCache-Control: public, max-age=3600\r\nConnection: keep-alive\r\n\r\n')
	}
	// The whole file, read straight into `out`: the ETag hashes all of it.
	body_at := out.len
	if core.append_file_region(mut out, fd, 0, size) != size {
		unsafe {
			out.len = mark // the file shrank under us, or a read error
		}
		core.append_str(mut out, resp_404)
		return .done
	}
	// ETag = 64-bit wyhash of the content, hex-encoded into a stack scratch —
	// a cheap, strong opaque validator (same as server.static_assets);
	// a crypto digest here is pure cost, and md5 is broken anyway.
	etag := hex16(wyhash.wyhash_c(unsafe { &u8(out.data) + body_at }, u64(size), 0))

	// Conditional GET: if the client's cached ETag matches, save the bytes —
	// drop all this response appended and answer 304 instead.
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches(req_buffer, inm, etag) {
			unsafe {
				out.len = mark
			}
			core.append_str(mut out, 'HTTP/1.1 304 Not Modified\r\nETag: "')
			unsafe { out.push_many(&etag[0], 16) }
			core.append_str(mut out, '"\r\n\r\n')
			return .done
		}
	}
	unsafe { vmemcpy(&u8(out.data) + tag_at, &etag[0], 16) }
	if !is_get {
		unsafe {
			out.len = body_at // HEAD gets the headers only
		}
	} else if partial {
		// Keep only the range window, moved down over the bytes before it —
		// no content[start..end+1] slice-marking. In bounds and non-empty:
		// parse_range guarantees 0 <= start <= end < size.
		length := int(end + 1 - start)
		unsafe {
			vmemmove(&u8(out.data) + body_at, &u8(out.data) + body_at + int(start), isize(length))
			out.len = body_at + length
		}
	}
	return .done
}

fn main() {
	// Resolved once: every request checks containment against this string.
	root := resolve(web_root) or {
		eprintln('web root ${web_root} does not resolve: create it, or run from the directory that holds it')
		exit(1)
	}
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
		make_state:      fn [root] () voidptr {
			return new_state(root)
		}
	})!
	// One-time init prints — `${}` is fine here, nothing below runs per request.
	println('Static server on http://localhost:3000/  (root: ${root})')
	println('For zero-copy large-file serving (sendfile(2)), use the static_assets module — see examples/spa_static_assets.')
	srv.run()
}
