# static_assets — serve a CSR/WASM SPA bundle

Serves a built single-page-app bundle (HTML + JS + **WASM** + CSS, content-hashed
and precompressed) with the reusable `static_assets` module. The
whole request handler is two lines — the module does the four things a bare file
server doesn't, and that a modern WASM SPA needs (GitHub issue #19):

- **`application/wasm` MIME** — required for `WebAssembly.instantiateStreaming`.
- **Precompressed negotiation** — serves the prebuilt `.br`/`.gz` sibling per
  `Accept-Encoding`, with `Content-Encoding` + `Vary: Accept-Encoding`.
- **Caching policy** — content-hashed assets get
  `Cache-Control: public, max-age=31536000, immutable`; `index.html` gets
  `no-cache` so deploys flip atomically by swapping it.
- **SPA fallback** — unknown, non-asset paths (`/users/42`) serve `index.html`
  so client-side deep links and refreshes work; asset-looking 404s
  (`/nope.[hash].wasm`) are still `404`, and `../` traversal is refused.

The `dist/` folder here is a tiny hand-made bundle standing in for the output of
a build (e.g. [`vcsr`](https://github.com/enghitalo/vcsr)). Everything is
precomputed once at boot, so the server stays immutable and lock-free.

### Zero-copy large files via `sendfile(2)`

Files at least `sendfile_min_bytes` (default 256 KiB) are served straight from
disk to the socket with `sendfile(2)` — the body never passes through a
userspace buffer. The handler calls `respond_into(req, mut out)` (not
`respond()`): it appends the headers to `out` and hands the body off to the
worker to stream. This is a Linux/epoll fast path; on TLS, other backends, or
other OSes it transparently falls back to copying the body, so the response is
always correct. Smaller files stay preloaded in RAM and are sent from a single
precomputed buffer. Range, conditional GET, and `Accept-Encoding` negotiation
all work over the `sendfile` path.

### Following the disk (`follow_disk`)

By default a representation is immutable after `new()`. With
`follow_disk: true` a replaced file is served without a restart:

```v
assets := static_assets.new(static_assets.Config{
	root:            'dist'
	follow_disk:     true // rebuild a representation when its file changes
	revalidate_ms:   100  // one stat(2) per representation per 100 ms; 0 = every request
	memory_fallback: true // large files also kept in RAM, for workers that cannot sendfile
})!
```

- A file counts as changed when its (dev, inode, size, mtime_ns, ctime_ns)
  differs, never by "newer mtime", so a rename of a new file and a `cp -p`
  restore of an older one are both seen. The first request after the
  `revalidate_ms` window makes the one stat; the others pay a coarse clock read.
- A new version is a new immutable snapshot (headers, body or fd, ETag, 304),
  published with one atomic pointer store. Requests in flight keep the version
  they loaded, and old versions are never freed, so nothing a worker is still
  sending can change or go away under it. That costs memory (and one fd per
  version of a file served with sendfile), with about one version per change
  and at most two (a request can catch the outgoing file in the middle of the
  rename that replaces it): fine for deploys, not for files rewritten
  continuously.
- Replace files atomically (write a temporary file in the same directory, then
  rename it). Files added or deleted after `new()` are not followed; a deleted
  file keeps serving its last version. Not supported on Windows.
- `memory_fallback` keeps the bytes of files at or above `sendfile_min_bytes`
  in RAM as well, so the io_uring backend (borrowed send) and userspace-TLS
  connections send them from memory instead of reading the file per request.

Each representation (identity, `.br`, `.gz`) has its own strong ETag, a 304
or 206 carries `Vary: Accept-Encoding` when the asset is negotiable (and the
same `Cache-Control` as the 200), and 200, HEAD, 304 and 206 responses
allocate nothing per request (`respond_into` / `respond_req_into`;
`respond_req_into` takes a request the handler already decoded).

A body kept in RAM is hashed by content. A representation served from disk
only (sendfile, without `memory_fallback`) hashes its size and nanosecond
mtime instead, so a replacement with the same size and the same mtime keeps
its ETag: the new bytes are served, but a cache that revalidates with
`If-None-Match` gets a 304 and keeps the old ones.

**API changes (2026-10):** `Asset.etag`, `Asset.body`, `Asset.body_len` and
`Asset.variants` are gone (representations live in per-asset snapshots); use
`AssetServer.etag_for(path)` for the identity ETag. ETags are per
representation and fixed width (`"` + 16 hex digits + `"`); for a file served
from disk with sendfile it is a hash of its size and nanosecond mtime (was:
size and mtime in seconds, in hex), so it stays the same across restarts and
replicas. A Range request is answered from the identity representation, and
its `If-None-Match` and `If-Range` are compared against the identity ETag (an
`If-Range` that is not exactly that ETag, such as another tag, a weak tag or a
date, gets the full 200 instead of the 206).

### Memory: flat RAM, no per-request allocation (2026-06)

This module stays flat on RAM under load for two reasons:

- **Body never hits the heap** — large files stream via `sendfile(2)` straight
  from the page cache to the socket (above), so the response body costs zero
  userspace allocation.
- **Lookup key is a zero-copy view** — routing builds the asset key as a
  non-owning `tos` view straight into the request buffer
  (`key := tos(&buf[rs], rel_len)`, never retained — see
  [`static_assets/static_assets.v:392`](../../static_assets/static_assets.v)),
  not an allocating `substr`, so routing costs no per-request allocation.

A hand-rolled handler that builds its key with `route[8..]` instead would
allocate a fresh heap string every request (`string.substr` →
`malloc_noscan(len+1)` + memcpy). Under `-gc none` that string is never freed —
an unbounded leak. An isolated test (identical `map[string]int`, 20,000,000
lookups, `-prod -gc none`) measured `route[8..]` at +625 MiB (monotonic,
~31 B/request) vs the `tos` view at +28 KiB (flat) — same work, ~22,000x the
RSS. A map lookup only hashes the key bytes and never retains them, so the
non-owning view is safe as a lookup key.

## Running

```sh
v -prod run examples/spa_static_assets/src
```

Then:

```sh
# WASM is served with the correct type + immutable caching
curl -v http://localhost:3000/main.7b2e10.wasm

# the .br sibling is negotiated from Accept-Encoding
curl -v --compressed http://localhost:3000/app.3f5a9c.js

# a client route with no file on disk falls back to index.html
curl -v http://localhost:3000/any/client/route

# an asset-looking path that doesn't exist is a real 404
curl -v http://localhost:3000/missing.deadbeef.wasm
```

## Testing (no socket)

The handler is a pure function of the request bytes, so the behavior is tested
without opening a socket — exactly like the rest of vanilla:

```sh
v test examples/spa_static_assets/src/main_test.v
```

The module's own acceptance tests live in
[`static_assets/static_assets_test.v`](../../static_assets/static_assets_test.v).
