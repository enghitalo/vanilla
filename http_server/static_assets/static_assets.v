module static_assets

// static_assets — serve a static, content-hashed, precompressed SPA/WASM bundle.
//
// This is the reusable counterpart to the `examples/static_files` demo. A CSR /
// WASM single-page-app bundle (HTML + JS + **WASM** + CSS, content-hashed and
// precompressed) is the ideal payload for vanilla: there is no per-request
// rendering — just immutable bytes shipped as fast as the kernel allows. Four
// things the bare example doesn't cover are required for a modern WASM SPA to
// work, and they are easy to get subtly wrong, so they live here in one audited
// place (see docs/ISSUE-vanilla-static-assets / GitHub issue #19):
//
//   1. `application/wasm` MIME — REQUIRED for `WebAssembly.instantiateStreaming`.
//   2. Precompressed-asset negotiation — serve a prebuilt `.br`/`.gz` sibling per
//      `Accept-Encoding` instead of recompressing per request or shipping raw.
//   3. Immutable caching — content-hashed assets get
//      `Cache-Control: public, max-age=31536000, immutable`; the HTML entrypoint
//      gets `no-cache` so deploys flip atomically by swapping `index.html`.
//   4. SPA fallback — a deep link / refresh on a client route (`/users/42`) has
//      no file on disk; serve `index.html` so the client router takes over.
//      Asset-looking 404s (`/nope.[hash].wasm`) are NOT masked by the fallback.
//
// DESIGN: an `AssetServer` is built ONCE at boot from a directory. Every file is
// read into memory and its complete HTTP response (status line + headers + body)
// is precomputed for each representation (identity / br / gzip). The server is
// then immutable, so `respond()` is a lock-free read shared across all worker
// threads, and the hot 200 path returns precomputed bytes with zero allocation.
// `respond()` is a pure function of the request bytes — socket-free and
// E2E-testable exactly like the rest of vanilla.
import os
import strings
import hash as wyhash
import http_server.core
import http_server.http1_1.request_parser

// Encoding is a precompressed representation negotiated via `Accept-Encoding`.
pub enum Encoding {
	br
	gzip
}

// Config configures an AssetServer. Only `root` is required.
pub struct Config {
pub:
	// root directory holding the built bundle (e.g. `dist`).
	root string @[required]
	// spa_fallback is served (200) for unknown, non-asset paths so client-side
	// deep links and refreshes work. Empty disables the fallback.
	spa_fallback string = 'index.html'
	// immutable_glob marks content-hashed assets that may be cached forever.
	// `*` matches any run of characters and `[hash]` matches a content-hash
	// segment (>=6 hex chars), so `*.[hash].*` matches `core.9f3a1c.wasm`.
	immutable_glob string = '*.[hash].*'
	// precompressed lists the precompressed sibling formats to load and
	// negotiate, in preference order (default: prefer `.br`, then `.gz`).
	precompressed []Encoding = [Encoding.br, Encoding.gzip]
	// sendfile_min_bytes: files at least this large are served straight from
	// disk with sendfile(2) (Linux) instead of being preloaded into RAM, so the
	// body is never copied through userspace. 0 disables it (preload everything).
	// Only takes effect on Linux; other OSes always preload (no behavior change).
	// Use respond_into() (not respond()) to get the sendfile fast path.
	sendfile_min_bytes i64 = 256 * 1024
	// url_prefix mounts the bundle under a request-path prefix (e.g. '/static/').
	// When set, route() requires the request path to start with it and strips it
	// before keying the asset map, so a server can expose the same loaded bundle
	// at any mount point without rewriting the request. Empty (default) serves at
	// the root. The SPA fallback (when enabled) only triggers for paths under the
	// prefix; paths outside it are a 404 (the asset server does not own them).
	url_prefix string
}

// Variant is one representation (identity / br / gzip) of an asset.
//
// Small assets (preloaded): `response` is the full precomputed HTTP response
// (headers + body), `header_len` marks the body offset, and `path`/`file_fd`
// are unset — the hot path returns `response` directly with zero allocation.
//
// Large assets (Linux, >= sendfile_min_bytes): `response` holds ONLY the headers
// (header_len == response.len), the body lives on disk at `path`, and `file_fd`
// is an open O_RDONLY fd streamed with sendfile(2) (the fd is borrowed for the
// server's lifetime; sendfile's explicit offset keeps it safe to share).
struct Variant {
	response   []u8   // headers (+ body, for small assets), ready to send
	header_len int    // index in `response` where the body starts
	path       string // body file on disk (large assets only; '' for small)
	file_fd    int = -1 // O_RDONLY fd for sendfile (Linux large assets; -1 otherwise)
	body_len   i64 // body length in bytes
}

@[inline]
fn (v &Variant) is_large() bool {
	return v.path != ''
}

// Asset is one served file: its metadata plus a precomputed response per
// representation. `body` is the identity (uncompressed) payload, kept for Range
// requests. Immutable after construction.
pub struct Asset {
pub:
	rel           string // path relative to root, '/'-separated (the URL key)
	content_type  string
	cache_control string
	etag          string             // strong validator, already quoted: `"<hex>"`
	negotiable    bool               // true when a precompressed sibling exists -> emit Vary
	body          []u8               // identity bytes for Range (small assets; empty when disk-backed)
	body_len      i64                // identity length in bytes (the Content-Range total)
	variants      map[string]Variant // keys: 'identity', 'br', 'gzip'
}

// AssetServer holds the loaded bundle. Built once, read-only thereafter, so it
// is safe to share across worker threads without locking.
pub struct AssetServer {
pub:
	spa_fallback  string
	precompressed []Encoding
	url_prefix    string // mount prefix stripped before keying (e.g. '/static/'); '' = root
	assets        map[string]&Asset
}

const status_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const status_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// new loads every file under `config.root`, computes its content type, cache
// policy, ETag and precompressed variants, and precomputes a ready-to-send HTTP
// response for each. Errors if the root does not exist or is not a directory.
pub fn new(config Config) !AssetServer {
	root_abs := os.abs_path(config.root)
	if !os.is_dir(root_abs) {
		return error('static_assets: root is not a directory: ${config.root}')
	}
	mut formats := config.precompressed.clone()
	if formats.len == 0 {
		formats = [Encoding.br, Encoding.gzip]
	}

	mut files := []string{}
	collect_files(root_abs, mut files)

	// Index all relative paths so precompressed siblings can be found by name.
	mut present := map[string]bool{}
	for f in files {
		present[to_rel(root_abs, f)] = true
	}

	threshold := config.sendfile_min_bytes
	mut assets := map[string]&Asset{}
	for f in files {
		rel := to_rel(root_abs, f)
		// Precompressed files are attached to their base asset, never served
		// directly under their own name.
		if rel.ends_with('.br') || rel.ends_with('.gz') {
			continue
		}
		ctype := mime_type(rel)
		cache := cache_control(rel, config.spa_fallback, config.immutable_glob)

		// Discover precompressed siblings for the requested formats.
		mut sib_present := map[string]string{} // token -> sibling absolute path
		for enc in formats {
			sib_rel := rel + enc_ext(enc)
			if sib_rel in present {
				sib_present[enc_token(enc)] = os.join_path(root_abs, sib_rel)
			}
		}
		negotiable := sib_present.len > 0

		// Identity representation. Large files (Linux) stay on disk for
		// sendfile(2); small files are preloaded and fully precomputed.
		ident_size := os.file_size(f)
		ident_large := is_large(threshold, ident_size)
		mut ident_body := []u8{}
		etag := if ident_large {
			// Avoid reading a large file just to hash it: a strong size+mtime
			// validator is stable across restarts and changes when the file does.
			etag_from_stat(f, ident_size)
		} else {
			ident_body = os.read_bytes(f) or { continue }
			// 64-bit wyhash: a cheap, strong opaque validator (boot-time only).
			'"' + wyhash.wyhash_c(ident_body.data, u64(ident_body.len), 0).hex() + '"'
		}

		mut variants := map[string]Variant{}
		variants['identity'] = if ident_large {
			build_variant_file(ctype, cache, etag, '', negotiable, f, i64(ident_size))
		} else {
			build_variant_inline(ctype, cache, etag, '', negotiable, ident_body)
		}
		// Precompressed siblings share the identity ETag (Vary already set).
		for tok, spath in sib_present {
			ssize := os.file_size(spath)
			if is_large(threshold, ssize) {
				variants[tok] = build_variant_file(ctype, cache, etag, tok, true, spath, i64(ssize))
			} else {
				sbody := os.read_bytes(spath) or { continue }
				variants[tok] = build_variant_inline(ctype, cache, etag, tok, true, sbody)
			}
		}

		assets[rel] = &Asset{
			rel:           rel
			content_type:  ctype
			cache_control: cache
			etag:          etag
			negotiable:    negotiable
			body:          ident_body // empty for large (served from disk)
			body_len:      i64(ident_size)
			variants:      variants
		}
	}

	return AssetServer{
		spa_fallback:  config.spa_fallback
		precompressed: formats
		url_prefix:    config.url_prefix
		assets:        assets
	}
}

// respond turns raw request bytes into a complete raw HTTP response. It never
// touches a socket, so it is unit-testable by feeding a request and asserting
// the returned headers/status. Returns an error only when the request bytes
// cannot be parsed (map to 400); every other case (404, 405, ...) is a normal
// response.
// route resolves a request to a served asset. It returns either a canned
// response (non-empty []u8, for 405 / 404) or a matched asset, with `head`
// telling GET from HEAD. All parsing is byte-level and allocation-free, and the
// security-critical path-traversal check lives here, in one place shared by
// respond() and respond_into().
// The matched-asset return is a possibly-nil &Asset (V won't take `none` for an
// optional reference in a multi-return); callers test it with isnil().
@[direct_array_access]
fn (s &AssetServer) route(req &request_parser.HttpRequest) ([]u8, &Asset, bool) {
	buf := req.buffer
	// Method check by direct byte compare — no string allocation.
	head := slice_is(buf, req.method, 'HEAD')
	if !head && !slice_is(buf, req.method, 'GET') {
		return status_405, unsafe { nil }, false
	}

	// The path is a view into the request buffer; strip the query by moving the
	// end marker only — nothing is copied.
	p := req.path
	mut pend := p.start + p.len
	for i in p.start .. pend {
		if buf[i] == `?` {
			pend = i
			break
		}
	}

	// Mount prefix: when configured, the path must start with url_prefix; strip it
	// so the asset key is mount-relative. A path outside the mount is a 404 — the
	// asset server does not own it. Done before the `..` scan so traversal checks
	// run on the mount-relative remainder.
	mut pstart := p.start
	if s.url_prefix.len > 0 {
		if pend - pstart < s.url_prefix.len {
			return status_404, unsafe { nil }, head
		}
		for k in 0 .. s.url_prefix.len {
			if buf[pstart + k] != s.url_prefix[k] {
				return status_404, unsafe { nil }, head
			}
		}
		pstart += s.url_prefix.len
	}

	// SECURITY: refuse any `..` path segment before it can reach the fallback.
	// Keys are clean relative paths, so a `..` can never match a real asset —
	// but it could otherwise be masked by the SPA fallback as a 200.
	mut seg := pstart
	for seg < pend {
		mut j := seg
		for j < pend && buf[j] != `/` {
			j++
		}
		if j - seg == 2 && buf[seg] == `.` && buf[seg + 1] == `.` {
			return status_404, unsafe { nil }, head
		}
		seg = j + 1
	}

	// Strip leading '/' to form the relative key — still just an offset + len.
	mut rs := pstart
	for rs < pend && buf[rs] == `/` {
		rs++
	}
	rel_len := pend - rs

	if rel_len == 0 {
		// `/` → the SPA entrypoint.
		if asset := s.assets[s.spa_fallback] {
			return []u8{}, asset, head
		}
		return status_404, unsafe { nil }, head
	}

	// Zero-copy lookup key: a string view straight into the request buffer (it
	// is never retained), so routing costs no allocation. V hashes string map
	// keys with wyhash, so the lookup itself is already fast.
	unsafe {
		key := tos(&buf[rs], rel_len)
		if asset := s.assets[key] {
			return []u8{}, asset, head
		}
	}
	// Miss: a clean route falls back to index.html; an asset-looking path (its
	// last segment has an extension) is a genuine 404 and must NOT be masked.
	if s.spa_fallback != '' && !looks_like_asset_slice(buf, rs, pend) {
		if asset := s.assets[s.spa_fallback] {
			return []u8{}, asset, head
		}
	}
	return status_404, unsafe { nil }, head
}

// respond turns raw request bytes into a complete raw HTTP response. Pure and
// socket-free — the testable contract. For a disk-backed (large) asset it reads
// the body from disk to assemble the bytes; handlers that want zero-copy
// sendfile(2) should call respond_into() with the socket fd instead.
pub fn (s &AssetServer) respond(req_buffer []u8) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	canned, asset, head := s.route(&req)
	if isnil(asset) {
		return canned
	}
	return s.build_bytes(asset, req, head)
}

// respond_into appends the response for `req` to `out` and, for a large asset
// body on a sendfile-capable worker, hands that body off to be streamed with
// sendfile(2) (no userspace copy) instead of appending it. On any other backend
// or OS it appends the body bytes, so the result is always a complete response.
// This is what a vanilla handler should call (the worker pairs the handed-off
// file with the current connection, so no socket fd is needed here).
pub fn (s &AssetServer) respond_into(req_buffer []u8, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	canned, asset, head := s.route(&req)
	if isnil(asset) {
		out << canned
		return
	}
	s.emit_into(asset, req, head, mut out)
}

// etag_for returns the strong validator a client should echo in If-None-Match
// to revalidate the asset (the same quoted value sent in the ETag header).
pub fn (s &AssetServer) etag_for(path string) !string {
	rel := path.trim_left('/')
	if asset := s.assets[rel] {
		return asset.etag
	}
	return error('static_assets: no such asset: ${path}')
}

// choose_variant negotiates the representation to serve. Byte-level, no alloc.
fn (s &AssetServer) choose_variant(asset &Asset, req &request_parser.HttpRequest) Variant {
	if asset.negotiable {
		if ae := req.get_header_value_slice('Accept-Encoding') {
			for enc in s.precompressed {
				tok := enc_token(enc)
				if v := asset.variants[tok] {
					if slice_accepts_token(req.buffer, ae, tok) {
						return v
					}
				}
			}
		}
	}
	return asset.variants['identity'] or { Variant{} }
}

// build_bytes returns the full response bytes for a matched asset (conditional
// GET, Range, negotiation). For a small asset the chosen variant's precomputed
// response is returned as-is (zero copy); a large asset's body is read from disk.
fn (s &AssetServer) build_bytes(asset &Asset, req request_parser.HttpRequest, head bool) []u8 {
	buf := req.buffer
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches_slice(buf, inm, asset.etag) {
			return build_304(asset.etag, asset.cache_control)
		}
	}
	if !head {
		if rng := req.get_header_value_slice('Range') {
			if start, end := parse_range_slice(buf, rng, int(asset.body_len)) {
				mut b := build_206_headers(asset, start, end)
				append_identity_region(asset, start, end - start + 1, mut b)
				return b
			}
		}
	}
	v := s.choose_variant(asset, &req)
	if head {
		return v.response[..v.header_len]
	}
	if !v.is_large() {
		return v.response
	}
	mut b := []u8{cap: v.response.len + int(v.body_len)}
	b << v.response
	append_file_bytes(mut b, v.path, 0, v.body_len)
	return b
}

// emit_into appends the response for a matched asset to `out`, using sendfile(2)
// for a large body when the worker can (core.queue_file), else reading the body.
fn (s &AssetServer) emit_into(asset &Asset, req request_parser.HttpRequest, head bool, mut out []u8) {
	buf := req.buffer
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches_slice(buf, inm, asset.etag) {
			out << build_304(asset.etag, asset.cache_control)
			return
		}
	}
	if !head {
		if rng := req.get_header_value_slice('Range') {
			if start, end := parse_range_slice(buf, rng, int(asset.body_len)) {
				length := end - start + 1
				out << build_206_headers(asset, start, end)
				iv := asset.variants['identity'] or { return }
				if !(iv.file_fd >= 0 && core.queue_file(iv.file_fd, start, length)) {
					append_identity_region(asset, start, length, mut out)
				}
				return
			}
		}
	}
	v := s.choose_variant(asset, &req)
	if head {
		out << v.response[..v.header_len]
		return
	}
	if !v.is_large() {
		// Small (preloaded): the precomputed response (headers + body) is immutable
		// for the server's lifetime, so hand it to the worker to send DIRECTLY
		// (borrowed) when the backend can (io_uring core.queue_buf) — no copy through
		// the per-connection write buffer. queue_buf returns false on any backend that
		// can't borrow-send (epoll, TLS, non-Linux), where the copy stays the path.
		if !core.queue_buf(v.response.data, v.response.len) {
			out << v.response
		}
		return
	}
	out << v.response // large: headers only; body streamed below
	// Large body: stream it from the page cache with sendfile(2); if the backend
	// can't (TLS / non-epoll / non-Linux), read it into `out` as a fallback.
	if !(v.file_fd >= 0 && core.queue_file(v.file_fd, i64(0), v.body_len)) {
		append_file_bytes(mut out, v.path, 0, v.body_len)
	}
}

// ---- response construction (load time, off the hot path) -------------------

// write_response_headers writes the shared 200 header block into `sb`.
fn write_response_headers(mut sb strings.Builder, ctype string, cache string, etag string, encoding string, vary bool, content_length i64) {
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(int(content_length))
	sb.write_string('\r\n')
	if encoding != '' {
		sb.write_string('Content-Encoding: ')
		sb.write_string(encoding)
		sb.write_string('\r\n')
	}
	if vary {
		sb.write_string('Vary: Accept-Encoding\r\n')
	}
	sb.write_string('Cache-Control: ')
	sb.write_string(cache)
	sb.write_string('\r\nETag: ')
	sb.write_string(etag)
	sb.write_string('\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n')
}

// build_variant_inline precomputes the COMPLETE response (headers + body) for a
// preloaded (small) representation — the zero-copy hot path.
fn build_variant_inline(ctype string, cache string, etag string, encoding string, vary bool, body []u8) Variant {
	mut sb := strings.new_builder(220 + body.len)
	write_response_headers(mut sb, ctype, cache, etag, encoding, vary, i64(body.len))
	header_len := sb.len
	sb.write(body) or {}
	return Variant{
		response:   sb
		header_len: header_len
		body_len:   i64(body.len)
	}
}

// build_variant_file precomputes ONLY the headers for a disk-backed (large)
// representation; the body is streamed from `path` with sendfile(2) at runtime.
fn build_variant_file(ctype string, cache string, etag string, encoding string, vary bool, path string, body_len i64) Variant {
	mut sb := strings.new_builder(220)
	write_response_headers(mut sb, ctype, cache, etag, encoding, vary, body_len)
	header_len := sb.len
	return Variant{
		response:   sb
		header_len: header_len
		path:       path
		file_fd:    open_ro_fd(path)
		body_len:   body_len
	}
}

fn build_304(etag string, cache string) []u8 {
	mut sb := strings.new_builder(96)
	sb.write_string('HTTP/1.1 304 Not Modified\r\nETag: ')
	sb.write_string(etag)
	sb.write_string('\r\nCache-Control: ')
	sb.write_string(cache)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	return sb
}

// build_206_headers builds the 206 Partial Content header block (no body).
fn build_206_headers(asset &Asset, start i64, end i64) []u8 {
	mut sb := strings.new_builder(256)
	sb.write_string('HTTP/1.1 206 Partial Content\r\nContent-Type: ')
	sb.write_string(asset.content_type)
	sb.write_string('\r\nContent-Range: bytes ')
	sb.write_decimal(int(start))
	sb.write_u8(`-`)
	sb.write_decimal(int(end))
	sb.write_u8(`/`)
	sb.write_decimal(int(asset.body_len))
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(int(end - start + 1))
	sb.write_string('\r\nAccept-Ranges: bytes\r\nETag: ')
	sb.write_string(asset.etag)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	return sb
}

// append_identity_region appends `length` identity bytes from `start` to `out`:
// a slice of the in-RAM body for a small asset, or a disk read for a large one.
fn append_identity_region(asset &Asset, start i64, length i64, mut out []u8) {
	if length <= 0 {
		return
	}
	if asset.body.len > 0 { // small: identity body is in RAM
		out << asset.body[int(start)..int(start + length)]
		return
	}
	if iv := asset.variants['identity'] {
		append_file_bytes(mut out, iv.path, start, length)
	}
}

// append_file_bytes reads [off, off+length) from `path` into `out`. The
// cross-platform userspace fallback when sendfile(2) isn't used.
fn append_file_bytes(mut out []u8, path string, off i64, length i64) {
	if length <= 0 {
		return
	}
	mut f := os.open(path) or { return }
	defer {
		f.close()
	}
	out << f.read_bytes_at(int(length), u64(off))
}

// open_ro_fd opens `path` read-only and returns its fd for sendfile(2). The fd
// is intentionally kept open for the server's lifetime (the File handle is
// dropped but V never auto-closes it). Linux only — returns -1 elsewhere, where
// assets are never disk-backed (see is_large).
fn open_ro_fd(path string) int {
	$if linux {
		f := os.open(path) or { return -1 }
		return f.fd
	}
	return -1
}

// is_large reports whether a file of `size` bytes should be served from disk
// with sendfile(2). Only Linux is disk-backed; other OSes always preload, so
// their behavior is unchanged regardless of the threshold.
fn is_large(threshold i64, size u64) bool {
	$if linux {
		return threshold > 0 && i64(size) >= threshold
	}
	return false
}

// etag_from_stat builds a strong size+mtime validator for a disk-backed asset
// without reading it (stable across restarts, changes when the file changes).
fn etag_from_stat(path string, size u64) string {
	mtime := os.file_last_mod_unix(path)
	return '"' + size.hex() + '-' + u64(mtime).hex() + '"'
}

// ---- policy & negotiation helpers ------------------------------------------

// mime_type maps a file extension to its Content-Type. WASM and the modern JS /
// manifest types are the additions that make a WASM SPA work.
pub fn mime_type(path string) string {
	return match os.file_ext(path).to_lower() {
		'.html', '.htm' { 'text/html; charset=utf-8' }
		'.css' { 'text/css; charset=utf-8' }
		'.js', '.mjs' { 'text/javascript; charset=utf-8' }
		'.json', '.map' { 'application/json' }
		'.wasm' { 'application/wasm' } // REQUIRED for instantiateStreaming
		'.webmanifest' { 'application/manifest+json' }
		'.xml' { 'application/xml' }
		'.txt' { 'text/plain; charset=utf-8' }
		'.svg' { 'image/svg+xml' }
		'.png' { 'image/png' }
		'.jpg', '.jpeg' { 'image/jpeg' }
		'.gif' { 'image/gif' }
		'.webp' { 'image/webp' }
		'.avif' { 'image/avif' }
		'.ico' { 'image/x-icon' }
		'.woff' { 'font/woff' }
		'.woff2' { 'font/woff2' }
		'.ttf' { 'font/ttf' }
		'.otf' { 'font/otf' }
		'.mp4' { 'video/mp4' }
		'.webm' { 'video/webm' }
		'.mp3' { 'audio/mpeg' }
		'.wav' { 'audio/wav' }
		else { 'application/octet-stream' }
	}
}

// cache_control returns the Cache-Control policy for a relative path: the HTML
// entrypoint (the SPA fallback, and any `.html`) is `no-cache` so a deploy that
// swaps it takes effect immediately; content-hashed assets are immutable; the
// rest get a short shared cache.
fn cache_control(rel string, fallback string, immutable_glob string) string {
	if rel == fallback || os.file_ext(rel).to_lower() == '.html' {
		return 'no-cache'
	}
	if immutable_glob != '' && glob_match(immutable_glob, base_name(rel)) {
		return 'public, max-age=31536000, immutable'
	}
	return 'public, max-age=3600'
}

// slice_is reports whether the request slice equals `target` byte-for-byte
// (case-sensitive — HTTP methods are uppercase tokens). No allocation.
@[direct_array_access; inline]
fn slice_is(buf []u8, sl request_parser.Slice, target string) bool {
	if sl.len != target.len {
		return false
	}
	for k in 0 .. target.len {
		if buf[sl.start + k] != target[k] {
			return false
		}
	}
	return true
}

// slice_accepts_token reports whether the `Accept-Encoding` value held in
// `buf[sl]` lists `token` (lowercase ASCII, e.g. 'br'/'gzip') with a non-zero
// q-value. Parsed directly over the header bytes — no allocation, no split.
@[direct_array_access]
fn slice_accepts_token(buf []u8, sl request_parser.Slice, token string) bool {
	end := sl.start + sl.len
	mut i := sl.start
	for i < end {
		// Skip separators / leading whitespace before this element.
		for i < end && (buf[i] == ` ` || buf[i] == `,` || buf[i] == `\t`) {
			i++
		}
		name_start := i
		for i < end && buf[i] != `,` && buf[i] != `;` && buf[i] != ` ` && buf[i] != `\t` {
			i++
		}
		name_len := i - name_start
		// Walk the rest of this element (its ;params) until the next comma,
		// noting an explicit q=0 that would disable the encoding.
		mut q_zero := false
		for i < end && buf[i] != `,` {
			if (buf[i] | 0x20) == `q` && i + 1 < end && buf[i + 1] == `=` {
				q_zero = q_value_is_zero(buf, i + 2, end)
			}
			i++
		}
		if name_len == token.len && ci_equals(buf, name_start, token) && !q_zero {
			return true
		}
	}
	return false
}

// q_value_is_zero reports whether the q-value starting at `start` is zero
// (`0`, `0.0`, `0.000`); `1`, `0.5`, etc. are non-zero.
@[direct_array_access; inline]
fn q_value_is_zero(buf []u8, start int, end int) bool {
	if start >= end || buf[start] != `0` {
		return false
	}
	mut i := start + 1
	if i < end && buf[i] == `.` {
		i++
		for i < end && buf[i] >= `0` && buf[i] <= `9` {
			if buf[i] != `0` {
				return false
			}
			i++
		}
	}
	return true
}

// ci_equals compares `target` (assumed lowercase ASCII) against the bytes at
// `buf[start..]` case-insensitively.
@[direct_array_access; inline]
fn ci_equals(buf []u8, start int, target string) bool {
	for k in 0 .. target.len {
		if (buf[start + k] | 0x20) != target[k] {
			return false
		}
	}
	return true
}

// etag_matches_slice reports whether the If-None-Match value held in `buf[sl]`
// matches `etag` (the quoted strong validator). Accepts a comma-separated list,
// the `*` wildcard (alone), and weak (`W/`) prefixes. Parsed directly over the
// header bytes — no allocation, no `.to_string()`, no `split`.
@[direct_array_access]
fn etag_matches_slice(buf []u8, sl request_parser.Slice, etag string) bool {
	start := sl.start
	end := sl.start + sl.len
	// A sole `*` (after trimming OWS) is the wildcard.
	mut ws := start
	for ws < end && (buf[ws] == ` ` || buf[ws] == `\t`) {
		ws++
	}
	mut we := end
	for we > ws && (buf[we - 1] == ` ` || buf[we - 1] == `\t`) {
		we--
	}
	if we - ws == 1 && buf[ws] == `*` {
		return true
	}
	// Walk the comma-separated list element by element.
	mut i := start
	for i < end {
		for i < end && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `,`) {
			i++
		}
		mut e := i
		for e < end && buf[e] != `,` {
			e++
		}
		mut te := e
		for te > i && (buf[te - 1] == ` ` || buf[te - 1] == `\t`) {
			te--
		}
		mut ts := i
		if te - ts >= 2 && buf[ts] == `W` && buf[ts + 1] == `/` {
			ts += 2 // strip a weak validator prefix
		}
		if te - ts == etag.len {
			mut hit := true
			for k in 0 .. etag.len {
				if buf[ts + k] != etag[k] {
					hit = false
					break
				}
			}
			if hit {
				return true
			}
		}
		i = e + 1
	}
	return false
}

// looks_like_asset_slice reports whether the last path segment in `buf[start..end]`
// carries a file extension (e.g. `app.js`, `nope.[hash].wasm`). Such a path that
// is missing is a genuine 404 — it must not be masked by the SPA fallback.
@[direct_array_access]
fn looks_like_asset_slice(buf []u8, start int, end int) bool {
	mut dot := false
	for i in start .. end {
		match buf[i] {
			`/` { dot = false } // reset at each segment boundary
			`.` { dot = true }
			else {}
		}
	}
	return dot
}

// parse_range_slice parses `bytes=START-END` from `buf[sl]` into an inclusive,
// clamped range. Single range only (more than one `-` is rejected, matching the
// old `split('-')` arity check). Parsed in place — no allocation, no split.
@[direct_array_access]
fn parse_range_slice(buf []u8, sl request_parser.Slice, size int) ?(i64, i64) {
	prefix := 'bytes='
	if sl.len < prefix.len {
		return none
	}
	start0 := sl.start
	end0 := sl.start + sl.len
	for k in 0 .. prefix.len {
		if buf[start0 + k] != prefix[k] {
			return none
		}
	}
	// Find the single '-' separating START and END.
	mut dash := -1
	for p in start0 + prefix.len .. end0 {
		if buf[p] == `-` {
			if dash >= 0 {
				return none // a second '-' → not a single range
			}
			dash = p
		}
	}
	if dash < 0 {
		return none
	}
	sz := i64(size)
	mut start := i64(0)
	mut end := sz - 1
	if dash == start0 + prefix.len {
		// Suffix range `-N`: the last N bytes.
		n := parse_u64_window(buf, dash + 1, end0)
		start = if n >= sz { i64(0) } else { sz - n }
		end = sz - 1
	} else {
		start = parse_u64_window(buf, start0 + prefix.len, dash)
		end = if dash == end0 - 1 { sz - 1 } else { parse_u64_window(buf, dash + 1, end0) }
	}
	if start < 0 || end >= sz || start > end {
		return none
	}
	return start, end
}

// parse_u64_window reads the leading run of ASCII digits in `buf[lo..hi]` as a
// non-negative i64 (empty / non-digit → 0). It saturates at `range_num_ceiling`
// rather than wrapping, so an absurd value (e.g. 2^64) fails the `end >= size`
// bounds check in the caller instead of aliasing a valid offset. `size` is an
// `int`, so the ceiling is far above any real asset and clear of i64 overflow.
@[direct_array_access; inline]
fn parse_u64_window(buf []u8, lo int, hi int) i64 {
	mut v := i64(0)
	for i in lo .. hi {
		c := buf[i]
		if c < `0` || c > `9` {
			break
		}
		v = v * 10 + i64(c - `0`)
		if v >= range_num_ceiling {
			return range_num_ceiling
		}
	}
	return v
}

// Above any int-sized asset (`size` is an `int`, < 2^31) yet far below i64 max,
// so accumulation never wraps.
const range_num_ceiling = i64(u64(1) << 40)

// glob_match matches `name` against a pattern where `*` matches any run of
// characters and `[hash]` matches a content-hash segment (>=6 hex chars). All
// other characters are literal. Load-time only — clarity over speed.
fn glob_match(pattern string, name string) bool {
	return match_glob(pattern, 0, name, 0)
}

const hash_token = '[hash]'

fn match_glob(p string, pi0 int, s string, si0 int) bool {
	mut pi := pi0
	mut si := si0
	for pi < p.len {
		if p[pi] == `*` {
			for k in si .. s.len + 1 {
				if match_glob(p, pi + 1, s, k) {
					return true
				}
			}
			return false
		} else if p[pi] == `[` && p[pi..].starts_with(hash_token) {
			mut run := si
			for run < s.len && is_hex(s[run]) {
				run++
			}
			if run - si < 6 {
				return false
			}
			for k := run; k >= si + 6; k-- {
				if match_glob(p, pi + hash_token.len, s, k) {
					return true
				}
			}
			return false
		} else {
			if si >= s.len || s[si] != p[pi] {
				return false
			}
			pi++
			si++
		}
	}
	return si == s.len
}

@[inline]
fn is_hex(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

// ---- filesystem helpers ----------------------------------------------------

fn enc_token(e Encoding) string {
	return match e {
		.br { 'br' }
		.gzip { 'gzip' }
	}
}

fn enc_ext(e Encoding) string {
	return match e {
		.br { '.br' }
		.gzip { '.gz' }
	}
}

fn base_name(rel string) string {
	return rel.all_after_last('/')
}

// to_rel returns `full` relative to `root_abs`, normalized to '/' separators.
fn to_rel(root_abs string, full string) string {
	rel := full[root_abs.len + 1..]
	$if windows {
		return rel.replace('\\', '/')
	}
	return rel
}

fn collect_files(dir string, mut acc []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		full := os.join_path(dir, e)
		if os.is_dir(full) {
			collect_files(full, mut acc)
		} else if os.is_file(full) {
			acc << full
		}
	}
}
