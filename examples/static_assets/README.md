# static_assets — serve a CSR/WASM SPA bundle

Serves a built single-page-app bundle (HTML + JS + **WASM** + CSS, content-hashed
and precompressed) with the reusable `http_server.static_assets` module. The
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

## Running

```sh
v -prod run examples/static_assets/src
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
v test examples/static_assets/src/main_test.v
```

The module's own acceptance tests live in
[`http_server/static_assets/static_assets_test.v`](../../http_server/static_assets/static_assets_test.v).
