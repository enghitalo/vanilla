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
// DESIGN: an `AssetServer` is built ONCE at boot from a directory, and its set
// of files is fixed from then on: the URL -> asset map is never modified, so
// workers read it without locking. Each asset has up to three representations
// (identity, br, gzip), and each representation points at a snapshot (`Snap`)
// of one version of its file: the complete precomputed HTTP response for it
// (status line + headers, plus the body when the body is kept in RAM), its
// strong ETag (one per representation) and its precomputed 304. A snapshot is
// never modified after it is published, so `respond()` is a lock-free read
// shared across all worker threads and every response path, 200, HEAD, 304
// and 206, appends precomputed or computed-in-place bytes with zero
// allocation. `respond()` is a pure function of the request bytes —
// socket-free and E2E-testable exactly like the rest of vanilla.
//
// FOLLOWING THE DISK (`Config.follow_disk`, off by default): a representation
// re-checks its file with one stat(2) per `revalidate_ms` window, made by the
// first request after the window opens (0 = on every request). When the
// file's (dev, ino, size, mtime_ns, ctime_ns) differs from the snapshot's,
// that request builds a new snapshot and publishes it with one atomic pointer
// store; requests already running keep the snapshot they loaded. Old snapshots
// stay reachable through `prev` and are NEVER freed, so a body a worker still
// sends (a borrowed queue_buf send, or a sendfile(2) region of its fd) can
// never dangle, and no fd number is ever reused under it. That costs memory,
// and an fd per snapshot of a disk-backed file, with about one snapshot per
// change and at most two (a request can catch the outgoing version in the
// middle of the rename that replaces it): it suits deploy-style changes, not
// files that are rewritten continuously. Files added or deleted after new()
// are not followed; a deleted file, or one replaced by something that is not
// a regular file (a FIFO, a directory), keeps serving its last version.
// Replace files atomically (write a temporary file in the same directory,
// then rename it over the old one): an in-place rewrite can be caught half
// written, and two same-size in-place writes within one kernel timestamp tick
// look identical to stat(2).
//
// ETAGS: a body kept in RAM is hashed by content. A representation served
// from disk only (sendfile, without memory_fallback) hashes its size and
// mtime_ns instead, so a replacement with the same size and the same mtime
// keeps its ETag: the new bytes are served, but a cache that revalidates with
// If-None-Match gets a 304 and keeps the old ones.
import os
import strconv
import hash as wyhash
import sync.stdatomic
import core
import http1_1.request_parser

#include "@VMODROOT/static_assets/file_sig.h"

@[typedef]
struct C.vanilla_sa_sig {
mut:
	dev      u64
	ino      u64
	size     i64
	mtime_ns i64
	ctime_ns i64
}

fn C.vanilla_sa_open(path &char) int
fn C.vanilla_sa_close(fd int)
fn C.vanilla_sa_stat(path &char, out &C.vanilla_sa_sig) int
fn C.vanilla_sa_fstat(fd int, out &C.vanilla_sa_sig) int
fn C.vanilla_sa_now_ms() u64

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
	// follow_disk: re-check each served representation against its file and
	// rebuild it when (dev, ino, size, mtime_ns, ctime_ns) differs, so a
	// replaced file is served without a restart. Off (default): every
	// representation is immutable after new(). Not supported on Windows.
	follow_disk bool
	// revalidate_ms: with follow_disk, one stat(2) per representation per
	// window, made by the first request after the window opens; requests
	// inside the window pay a coarse clock read and a compare. 0 = stat on
	// every request (strict freshness).
	revalidate_ms int = 100
	// memory_fallback: representations of at least sendfile_min_bytes keep
	// their bytes in RAM as well as an fd, so a worker that cannot sendfile
	// them (io_uring's borrowed queue_buf send, a userspace-TLS connection)
	// sends them from memory instead of reading the file on every request.
	memory_fallback bool
}

// Snap is one immutable version of a representation's file. Every field is
// written before the snapshot is published (an atomic pointer store) and
// never again, and a snapshot is never freed: a worker may keep sending from
// it after a newer one replaced it.
@[heap]
struct Snap {
	sig          C.vanilla_sa_sig // the file's signature, from fstat on the fd the body was read from
	response     []u8             // headers (+ body when in_memory), ready to send; one allocation
	header_len   int              // index in `response` where the body starts
	body_len     i64              // body length in bytes (Content-Length)
	in_memory    bool             // the body is in `response`
	file_fd      int = -1 // O_RDONLY fd of the body (disk-backed or large); never closed
	etag         string // the quoted strong validator: a view into `response`
	not_modified []u8   // the precomputed 304
	prev         &Snap = unsafe { nil } // the version this one replaced: keeps it alive
}

// Variant is one representation (identity / br / gzip) of an asset: what it
// was built from and how, and its current snapshot. Only `cur`, `next_check`
// and `busy` change after new(), and only through C11 atomics.
@[heap]
struct Variant {
	path        string // absolute path of the file (NUL-terminated: passed to stat/open)
	encoding    string // Content-Encoding token; '' for identity
	ctype       string
	cache       string
	vary        bool // the asset is negotiable: emit Vary: Accept-Encoding
	threshold   i64  // Config.sendfile_min_bytes
	keep_memory bool // Config.memory_fallback
	follow      bool // Config.follow_disk
	window_ms   u64  // Config.revalidate_ms
mut:
	cur        &Snap = unsafe { nil } // only through C.atomic_load_ptr / C.atomic_store_ptr
	next_check u64 // coarse-clock ms of the next stat; a CAS elects one checker per window
	busy       u32 // 1 while one thread builds a new snapshot
}

// Asset is one served file: its metadata plus up to three representations.
pub struct Asset {
pub:
	rel           string // path relative to root, '/'-separated (the URL key)
	content_type  string
	cache_control string
	negotiable    bool // true when a precompressed sibling exists -> emit Vary
mut:
	reps [3]&Variant // slot_identity, slot_br, slot_gzip; nil when absent
}

// AssetServer holds the loaded bundle. Its asset map is built once and never
// modified, so it is safe to share across worker threads without locking.
pub struct AssetServer {
pub:
	spa_fallback  string
	precompressed []Encoding
	url_prefix    string // mount prefix stripped before keying (e.g. '/static/'); '' = root
	assets        map[string]&Asset
}

const status_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const status_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// A cached error, so a malformed request costs no allocation (-gc none).
const err_malformed = error('static_assets: malformed request head')

const slot_identity = 0
const slot_br = 1
const slot_gzip = 2

// The ETag is written as a fixed-width placeholder (a quote, 16 hex digits, a
// quote) before the body is read, then overwritten with the hash.
const etag_placeholder = '"0000000000000000"'

// Room for the status line and the fixed header names and values of a 200,
// 206 or 304, on top of the content type and cache policy.
const head_room = 288

// A body larger than this is never kept in RAM (its length must fit an array).
const max_ram_body = i64(max_int) - 65536

// new loads every file under `config.root`, computes its content type, cache
// policy, ETag and precompressed variants, and precomputes a ready-to-send HTTP
// response for each. Errors if the root does not exist or is not a directory,
// or if follow_disk is set on Windows.
pub fn new(config Config) !AssetServer {
	root_abs := os.abs_path(config.root)
	if !os.is_dir(root_abs) {
		return error('static_assets: root is not a directory: ${config.root}')
	}
	$if windows {
		if config.follow_disk {
			return error('static_assets: follow_disk is not supported on Windows')
		}
	}
	mut formats := config.precompressed.clone()
	if formats.len == 0 {
		formats = [Encoding.br, Encoding.gzip]
	}
	window := if config.revalidate_ms > 0 { u64(config.revalidate_ms) } else { u64(0) }

	mut files := []string{}
	collect_files(root_abs, mut files)

	// Index all relative paths so precompressed siblings can be found by name.
	mut present := map[string]bool{}
	for f in files {
		present[to_rel(root_abs, f)] = true
	}

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
		mut paths := ['', '', '']!
		paths[slot_identity] = f
		mut negotiable := false
		for enc in formats {
			sib_rel := rel + enc_ext(enc)
			if sib_rel in present {
				paths[enc_slot(enc)] = os.join_path(root_abs, sib_rel)
				negotiable = true
			}
		}

		mut asset := &Asset{
			rel:           rel
			content_type:  ctype
			cache_control: cache
			negotiable:    negotiable
		}
		for slot in 0 .. 3 {
			if paths[slot] == '' {
				continue
			}
			mut v := &Variant{
				path:        paths[slot].clone() // clone: a NUL-terminated copy for the C calls
				encoding:    slot_token(slot)
				ctype:       ctype
				cache:       cache
				vary:        negotiable
				threshold:   config.sendfile_min_bytes
				keep_memory: config.memory_fallback
				follow:      config.follow_disk
				window_ms:   window
			}
			// Plain stores: workers only see the server after new() returns.
			v.cur = load_snap(v, unsafe { nil }) or {
				if slot == slot_identity {
					break // the file itself could not be read: skip its siblings
				}
				continue
			}
			v.next_check = C.vanilla_sa_now_ms() + window
			asset.reps[slot] = v
		}
		if isnil(asset.reps[slot_identity]) {
			continue // the file itself could not be read: not served
		}
		assets[rel] = asset
	}

	return AssetServer{
		spa_fallback:  config.spa_fallback
		precompressed: formats
		url_prefix:    config.url_prefix
		assets:        assets
	}
}

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
// socket-free — the testable contract. It never touches a socket, so it is
// unit-testable by feeding a request and asserting the returned bytes. Returns
// an error only when the request bytes cannot be parsed (map to 400); every
// other case (404, 405, ...) is a normal response. A plain 200, HEAD or 304 of
// a snapshot is returned zero-copy (a read-only view: snapshots are never
// modified or freed); a disk-backed body or a 206 is assembled into a new
// buffer. Handlers that want sendfile(2) and no allocation should call
// respond_into() or respond_req_into() instead.
pub fn (s &AssetServer) respond(req_buffer []u8) ![]u8 {
	mut hr := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut hr) {
		return err_malformed
	}
	// The response is set through `resp` by a method that returns nothing, as
	// respond_into does. Since V 04fc6a97, passing `&hr` to route and
	// build_bytes here moved `hr` to the heap (one allocation per call), even
	// under unsafe; this shape keeps it on the stack.
	mut resp := []u8{}
	s.respond_view(&hr, mut resp)
	return resp
}

// respond_view sets `resp` to the response for a decoded request: a view of a
// snapshot's bytes, or a constant. It copies and allocates nothing.
fn (s &AssetServer) respond_view(req &request_parser.HttpRequest, mut resp []u8) {
	canned, asset, head := s.route(req)
	if isnil(asset) {
		unsafe {
			resp = canned // a view of a constant, as respond returned it
		}
		return
	}
	resp = s.build_bytes(asset, req, head)
}

// respond_into decodes `req_buffer` and appends the response to `out`; see
// respond_req_into. Errors (map to 400) only when the request bytes cannot be
// parsed, without allocating.
pub fn (s &AssetServer) respond_into(req_buffer []u8, mut out []u8) ! {
	mut hr := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut hr) {
		return err_malformed
	}
	s.respond_req_into(&hr, mut out)
}

// respond_req_into appends the response for an already decoded request to
// `out`, so a handler that parsed the request to route it does not parse it
// twice. For a disk-backed body on a sendfile-capable worker it hands the body
// off to be streamed with sendfile(2) (no userspace copy) instead of appending
// it; on io_uring an in-memory response is handed off as a borrowed buffer.
// Everywhere else it appends the bytes, so the result is always a complete
// response. No allocation once `out` has grown to its high-water mark. This is
// what a vanilla handler should call (the worker pairs a handed-off body with
// the current connection, so no socket fd is needed here).
pub fn (s &AssetServer) respond_req_into(req &request_parser.HttpRequest, mut out []u8) {
	canned, asset, head := s.route(req)
	if isnil(asset) {
		out << canned
		return
	}
	s.emit_into(asset, req, head, mut out)
}

// etag_for returns the strong validator a client should echo in If-None-Match
// to revalidate the asset's identity representation (the same quoted value
// sent in its ETag header; each precompressed representation has its own).
pub fn (s &AssetServer) etag_for(path string) !string {
	rel := path.trim_left('/')
	if asset := s.assets[rel] {
		return asset.reps[slot_identity].current().etag
	}
	return error('static_assets: no such asset: ${path}')
}

// choose_variant negotiates the representation to serve. Byte-level, no alloc.
@[direct_array_access]
fn (s &AssetServer) choose_variant(asset &Asset, req &request_parser.HttpRequest) &Variant {
	if asset.negotiable {
		if ae := req.get_header_value_slice('Accept-Encoding') {
			for enc in s.precompressed {
				v := asset.reps[enc_slot(enc)]
				if !isnil(v) && slice_accepts_token(req.buffer, ae, enc_token(enc)) {
					return v
				}
			}
		}
	}
	return asset.reps[slot_identity]
}

// Reply is what a matched request gets.
enum Reply {
	full         // 200 with the body
	head         // 200 headers only
	not_modified // 304
	partial      // 206 of the identity representation
}

// decide picks the reply and the snapshot it is built from, loading each
// representation's snapshot once (`current` may revalidate it against the
// disk). For .partial it also returns the inclusive byte range.
fn (s &AssetServer) decide(asset &Asset, req &request_parser.HttpRequest, head bool) (Reply, &Snap, i64, i64) {
	buf := req.buffer
	// A Range is always a range of the identity bytes, so a GET whose Range
	// applies selects the identity representation: If-None-Match, which RFC
	// 9110 §13.2.2 evaluates before Range, is compared against its ETag, and
	// the encoded representations are neither negotiated nor stat'ed. A Range
	// applies when it is satisfiable and its If-Range, if any, matches the
	// identity ETag; otherwise it is ignored and the full response is served.
	if !head {
		if rng := req.get_header_value_slice('Range') {
			isnap := asset.reps[slot_identity].current()
			if start, end := parse_range_slice(buf, rng, isnap.body_len) {
				if if_range_allows(req, isnap.etag) {
					if inm := req.get_header_value_slice('If-None-Match') {
						if etag_matches_slice(buf, inm, isnap.etag) {
							return .not_modified, isnap, 0, 0
						}
					}
					return .partial, isnap, start, end
				}
			}
		}
	}
	snap := s.choose_variant(asset, req).current()
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches_slice(buf, inm, snap.etag) {
			return .not_modified, snap, 0, 0
		}
	}
	if head {
		return .head, snap, 0, 0
	}
	return .full, snap, 0, 0
}

// emit_into appends the response for a matched asset to `out`, handing a
// disk-backed body to the worker's sendfile(2) (core.queue_file) or an
// in-memory response to its borrowed send (core.queue_buf) when it can.
fn (s &AssetServer) emit_into(asset &Asset, req &request_parser.HttpRequest, head bool, mut out []u8) {
	reply, snap, start, end := s.decide(asset, req, head)
	match reply {
		.full {
			if snap.file_fd >= 0 && core.queue_file(snap.file_fd, 0, snap.body_len) {
				// Headers now; the worker streams the body after them.
				unsafe { out.push_many(snap.response.data, snap.header_len) }
			} else if snap.in_memory {
				// The snapshot is never modified or freed, so the worker can send it
				// DIRECTLY (borrowed) when the backend can (io_uring core.queue_buf):
				// no copy through the per-connection write buffer. queue_buf returns
				// false on any backend that can't borrow-send (epoll, TLS, non-Linux),
				// where the copy stays the path.
				if !core.queue_buf(snap.response.data, snap.response.len) {
					out << snap.response
				}
			} else {
				unsafe { out.push_many(snap.response.data, snap.header_len) }
				append_body(mut out, snap, 0, snap.body_len)
			}
		}
		.head {
			unsafe { out.push_many(snap.response.data, snap.header_len) }
		}
		.not_modified {
			out << snap.not_modified
		}
		.partial {
			length := end - start + 1
			write_206_head(mut out, asset, snap, start, end)
			if snap.in_memory {
				unsafe { out.push_many(&u8(snap.response.data) + snap.header_len + int(start), int(length)) }
			} else if !(snap.file_fd >= 0 && core.queue_file(snap.file_fd, start, length)) {
				append_body(mut out, snap, start, length)
			}
		}
	}
}

// build_bytes returns the full response bytes for a matched asset, without the
// worker hand-offs: a snapshot's own bytes as a read-only view when they are
// the whole response, else a new buffer.
fn (s &AssetServer) build_bytes(asset &Asset, req &request_parser.HttpRequest, head bool) []u8 {
	reply, snap, start, end := s.decide(asset, req, head)
	match reply {
		.full {
			if snap.in_memory {
				return unsafe { (&u8(snap.response.data)).vbytes(snap.response.len) }
			}
			mut b := []u8{cap: snap.header_len + int(snap.body_len)}
			unsafe { b.push_many(snap.response.data, snap.header_len) }
			append_body(mut b, snap, 0, snap.body_len)
			return b
		}
		.head {
			return unsafe { (&u8(snap.response.data)).vbytes(snap.header_len) }
		}
		.not_modified {
			return unsafe { (&u8(snap.not_modified.data)).vbytes(snap.not_modified.len) }
		}
		.partial {
			length := end - start + 1
			mut b := []u8{cap: head_room + asset.content_type.len + asset.cache_control.len +
				int(length)}
			write_206_head(mut b, asset, snap, start, end)
			if snap.in_memory {
				unsafe { b.push_many(&u8(snap.response.data) + snap.header_len + int(start), int(length)) }
			} else {
				append_body(mut b, snap, start, length)
			}
			return b
		}
	}
}

// ---- snapshots: loading, revalidation, publication --------------------------

// snap returns the representation's current snapshot.
@[inline]
fn (v &Variant) snap() &Snap {
	return unsafe { &Snap(C.atomic_load_ptr(voidptr(&v.cur))) }
}

// current returns the snapshot to serve. Without follow_disk it is one atomic
// load. With it, once per window the first request to win the CAS on
// next_check (every request when revalidate_ms is 0) stats the file and, when
// the file changed, rebuilds the snapshot. No allocation unless it rebuilds.
@[inline]
fn (v &Variant) current() &Snap {
	s := v.snap()
	if !v.follow {
		return s
	}
	if v.window_ms > 0 {
		now := C.vanilla_sa_now_ms()
		mut due := stdatomic.load_u64(&v.next_check)
		if now < due {
			return s
		}
		if !C.atomic_compare_exchange_strong_u64(voidptr(&v.next_check), &due, now + v.window_ms) {
			return s // another request checks this window
		}
	}
	return v.revalidate(s)
}

// revalidate stats the file and rebuilds the snapshot when its signature
// differs from `s`'s. A failed stat (ENOENT while the file is being replaced,
// a deleted file, or no longer a regular file) keeps serving the last good
// snapshot.
@[noinline]
fn (v &Variant) revalidate(s &Snap) &Snap {
	mut st := C.vanilla_sa_sig{}
	if C.vanilla_sa_stat(&char(v.path.str), &st) != 0 || sig_eq(st, s.sig) {
		return s
	}
	return v.refresh(s)
}

// refresh builds and publishes the snapshot of the file's new version. One
// thread at a time (`busy`): the others keep serving `seen` meanwhile, so a
// change is not rebuilt once per racing request, and `prev` always chains to
// the snapshot that was published before it (a snapshot built by a losing
// thread would be reachable from nothing while a borrowed send might still
// point into it). A failed build (the file is still changing, is being
// replaced, or is no longer a regular file) keeps `seen`; the next check
// retries.
@[noinline]
fn (v &Variant) refresh(seen &Snap) &Snap {
	mut idle := u32(0)
	if !C.atomic_compare_exchange_strong_u32(voidptr(&v.busy), &idle, 1) {
		return seen
	}
	defer {
		C.atomic_store_u32(voidptr(&v.busy), 0)
	}
	cur := v.snap()
	if voidptr(cur) != voidptr(seen) {
		return cur // already republished by another thread
	}
	n := load_snap(v, seen) or { return seen }
	C.atomic_store_ptr(voidptr(&v.cur), voidptr(n)) // seq_cst: publishes every field of n
	return n
}

@[inline]
fn sig_eq(a C.vanilla_sa_sig, b C.vanilla_sa_sig) bool {
	return a.ino == b.ino && a.size == b.size && a.mtime_ns == b.mtime_ns
		&& a.ctime_ns == b.ctime_ns && a.dev == b.dev
}

// load_snap builds a snapshot of the version of `v`'s file that is on disk
// now, chained to `prev` (nil at boot). The signature comes from fstat on the
// opened fd, so Content-Length always matches the bytes behind that fd. A body
// kept in RAM must read in full and the file must fstat the same afterwards,
// or the half-written version is refused (none) and the caller keeps the one
// it has. A disk-backed snapshot keeps its fd open forever; any other closes it.
fn load_snap(v &Variant, prev &Snap) ?&Snap {
	mut sig := C.vanilla_sa_sig{}
	$if windows {
		// No follow_disk on Windows (new() refuses it): the file is read once.
		body := os.read_bytes(v.path) or { return none }
		sig.size = body.len
		mut resp := []u8{cap: head_room + v.ctype.len + v.cache.len + body.len}
		tag_at := write_200_head(mut resp, v, sig.size)
		header_len := resp.len
		resp << body
		return finish_snap(v, prev, sig, mut resp, tag_at, header_len, true, -1)
	} $else {
		fd := C.vanilla_sa_open(&char(v.path.str))
		if fd < 0 {
			return none
		}
		if C.vanilla_sa_fstat(fd, &sig) != 0 {
			C.vanilla_sa_close(fd)
			return none
		}
		large := is_large(v.threshold, sig.size)
		in_memory := (!large || v.keep_memory) && sig.size <= max_ram_body
		mut resp := []u8{cap: head_room + v.ctype.len + v.cache.len + if in_memory {
			int(sig.size)
		} else {
			0
		}}
		tag_at := write_200_head(mut resp, v, sig.size)
		header_len := resp.len
		if in_memory {
			got := core.append_file_region(mut resp, fd, 0, sig.size)
			mut again := C.vanilla_sa_sig{}
			if got != sig.size || C.vanilla_sa_fstat(fd, &again) != 0 || !sig_eq(sig, again) {
				C.vanilla_sa_close(fd)
				unsafe { resp.free() }
				return none
			}
		}
		mut keep_fd := fd
		if in_memory && !large {
			C.vanilla_sa_close(fd)
			keep_fd = -1
		}
		return finish_snap(v, prev, sig, mut resp, tag_at, header_len, in_memory, keep_fd)
	}
}

// finish_snap writes the ETag into its placeholder and wraps `resp`. The ETag
// is the wyhash of the body when the body is in RAM, else of the file's size
// and mtime_ns, so a disk-backed file is never read just to hash it. Either
// way it is stable across restarts and replicas: dev, ino and ctime, which
// differ between copies of one file (overlay mounts, a restore), only decide
// when to rebuild.
fn finish_snap(v &Variant, prev &Snap, sig C.vanilla_sa_sig, mut resp []u8, tag_at int, header_len int, in_memory bool, file_fd int) &Snap {
	tag := if in_memory {
		wyhash.wyhash_c(unsafe { &u8(resp.data) + header_len }, u64(resp.len - header_len),
			0)
	} else {
		wyhash.wyhash64_c(u64(sig.size), u64(sig.mtime_ns))
	}
	put_hex16(mut resp, tag_at + 1, tag)
	etag := unsafe { tos(&u8(resp.data) + tag_at, etag_placeholder.len) }
	return &Snap{
		sig:          sig
		response:     resp
		header_len:   header_len
		body_len:     sig.size
		in_memory:    in_memory
		file_fd:      file_fd
		etag:         etag
		not_modified: build_304(etag, v.cache, v.vary)
		prev:         prev
	}
}

// ---- response construction (no Builder, no interpolation) -------------------

// put appends a string's bytes.
@[inline]
fn put(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// put_dec appends the decimal digits of `n`, written in place (no allocation
// once `out` has the room).
@[inline]
fn put_dec(mut out []u8, n i64) {
	start := out.len
	unsafe { out.grow_len(20) }
	mut digits := unsafe { (&u8(out.data) + start).vbytes(20) }
	w := strconv.write_dec(n, mut digits)
	unsafe {
		out.len = start + w
	}
}

const hex_digits = '0123456789abcdef'

// put_hex16 overwrites b[at..at+16] with the 16 lowercase hex digits of `x`.
@[direct_array_access]
fn put_hex16(mut b []u8, at int, x u64) {
	for i in 0 .. 16 {
		b[at + i] = hex_digits[int((x >> u64(60 - 4 * i)) & 0xf)]
	}
}

// write_200_head writes a representation's 200 header block for a body of
// `size` bytes, with an ETag placeholder, and returns the placeholder's offset.
fn write_200_head(mut b []u8, v &Variant, size i64) int {
	put(mut b, 'HTTP/1.1 200 OK\r\nContent-Type: ')
	put(mut b, v.ctype)
	put(mut b, '\r\nContent-Length: ')
	put_dec(mut b, size)
	put(mut b, '\r\n')
	if v.encoding != '' {
		put(mut b, 'Content-Encoding: ')
		put(mut b, v.encoding)
		put(mut b, '\r\n')
	}
	if v.vary {
		put(mut b, 'Vary: Accept-Encoding\r\n')
	}
	put(mut b, 'Cache-Control: ')
	put(mut b, v.cache)
	put(mut b, '\r\nETag: ')
	tag_at := b.len
	put(mut b, etag_placeholder)
	put(mut b, '\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n')
	return tag_at
}

// build_304 precomputes a representation's 304. RFC 9110 §15.4.5: it carries
// the ETag, Cache-Control and Vary the 200 would have carried.
fn build_304(etag string, cache string, vary bool) []u8 {
	mut b := []u8{cap: head_room + cache.len}
	put(mut b, 'HTTP/1.1 304 Not Modified\r\nETag: ')
	put(mut b, etag)
	put(mut b, '\r\nCache-Control: ')
	put(mut b, cache)
	put(mut b, '\r\n')
	if vary {
		put(mut b, 'Vary: Accept-Encoding\r\n')
	}
	put(mut b, 'Connection: keep-alive\r\n\r\n')
	return b
}

// write_206_head appends the 206 Partial Content header block (no body) for
// bytes [start, end] of an identity snapshot, straight into `out`. RFC 9110
// §15.3.7: it carries the ETag, Cache-Control and Vary the 200 would have
// carried.
fn write_206_head(mut out []u8, asset &Asset, snap &Snap, start i64, end i64) {
	put(mut out, 'HTTP/1.1 206 Partial Content\r\nContent-Type: ')
	put(mut out, asset.content_type)
	put(mut out, '\r\nContent-Range: bytes ')
	put_dec(mut out, start)
	out << `-`
	put_dec(mut out, end)
	out << `/`
	put_dec(mut out, snap.body_len)
	put(mut out, '\r\nContent-Length: ')
	put_dec(mut out, end - start + 1)
	put(mut out, '\r\nAccept-Ranges: bytes\r\nETag: ')
	put(mut out, snap.etag)
	put(mut out, '\r\nCache-Control: ')
	put(mut out, asset.cache_control)
	put(mut out, '\r\n')
	if asset.negotiable {
		put(mut out, 'Vary: Accept-Encoding\r\n')
	}
	put(mut out, 'Connection: keep-alive\r\n\r\n')
}

// append_body appends bytes [off, off+length) of a disk-backed snapshot's body
// to `out`, read from its fd with no allocation once `out` has the room. A
// short read (the file shrank under a Content-Length already written) is
// zero-filled so the response stays framed. Never reached on Windows, where
// every body is in RAM.
fn append_body(mut out []u8, snap &Snap, off i64, length i64) {
	$if !windows {
		got := core.append_file_region(mut out, snap.file_fd, off, length)
		missing := length - got
		if missing > 0 && missing <= i64(max_int) - i64(out.len) {
			start := out.len
			unsafe {
				out.grow_len(int(missing))
				vmemset(&u8(out.data) + start, 0, int(missing))
			}
		}
	}
}

// is_large reports whether a file of `size` bytes should be served from disk
// with sendfile(2). Only Linux is disk-backed; other OSes always preload, so
// their behavior is unchanged regardless of the threshold.
fn is_large(threshold i64, size i64) bool {
	$if linux {
		return threshold > 0 && size >= threshold
	}
	return false
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

// if_range_allows reports whether a satisfiable Range may be served as a 206:
// the request has no If-Range, or its If-Range is `etag` (the identity ETag)
// exactly. RFC 9110 §13.1.5: entity tags are compared strongly, so a weak
// `W/` tag never matches, and neither does an HTTP-date (it would be compared
// with a Last-Modified this module never sends). Byte-level, no allocation.
@[direct_array_access]
fn if_range_allows(req &request_parser.HttpRequest, etag string) bool {
	sl := req.get_header_value_slice('If-Range') or { return true }
	buf := req.buffer
	mut s := sl.start
	mut e := sl.start + sl.len
	for s < e && (buf[s] == ` ` || buf[s] == `\t`) {
		s++
	}
	for e > s && (buf[e - 1] == ` ` || buf[e - 1] == `\t`) {
		e--
	}
	if e - s != etag.len {
		return false
	}
	for k in 0 .. etag.len {
		if buf[s + k] != etag[k] {
			return false
		}
	}
	return true
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
fn parse_range_slice(buf []u8, sl request_parser.Slice, size i64) ?(i64, i64) {
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
	sz := size
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
// bounds check in the caller instead of aliasing a valid offset. The ceiling is
// far above any real asset and clear of i64 overflow.
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

// Above any real asset (64 PiB) yet far enough below i64 max that one more
// `v * 10 + digit` step never wraps.
const range_num_ceiling = i64(u64(1) << 56)

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

// enc_slot is the index of an encoding's representation in Asset.reps.
@[inline]
fn enc_slot(e Encoding) int {
	return match e {
		.br { slot_br }
		.gzip { slot_gzip }
	}
}

// slot_token is the Content-Encoding token of a representation slot.
fn slot_token(slot int) string {
	return match slot {
		slot_br { 'br' }
		slot_gzip { 'gzip' }
		else { '' }
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
