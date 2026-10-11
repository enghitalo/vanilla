# cors — let an allowlisted origin call you, with credentials

Browsers block a page from reading responses from another origin unless the
server opts in. CORS is that opt-in, and this example shows its two halves:

- **Preflight.** For anything beyond a simple GET/HEAD/POST (custom headers,
  `PUT`/`DELETE`, a JSON content type) the browser first sends `OPTIONS` and
  waits for the allowed methods and headers. Forgetting to answer it is the
  most common CORS bug.
- **The actual request.** The browser checks `Access-Control-Allow-Origin` on
  the response before letting the page read it.

Credentials are allowed, so the server never answers `*` and never reflects an
arbitrary `Origin`: it echoes back only an origin on its allowlist
(`https://app.example.com`, `http://localhost:5173`).

## Run

```sh
v -prod run examples/cors/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) and serves the same
`{"ok":true}` on every path.

A preflight from an allowlisted origin:

```sh
curl -i -X OPTIONS localhost:3000/api -H 'Origin: https://app.example.com' \
  -H 'Access-Control-Request-Method: PUT'
```

```
HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization, X-CSRF-Token
Access-Control-Allow-Credentials: true
Access-Control-Max-Age: 86400
Vary: Origin
Content-Length: 0
```

The same preflight from any other origin, or with no `Origin` at all:

```
HTTP/1.1 403 Forbidden
Vary: Origin
Content-Length: 0
```

An actual request from an allowlisted origin gets the grant:

```sh
curl -i localhost:3000/api -H 'Origin: http://localhost:5173'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: http://localhost:5173
Access-Control-Allow-Credentials: true
Vary: Origin
Content-Length: 11

{"ok":true}
```

From `https://evil.example`, or with no `Origin`, the resource is still
served, just without the grant, so a browser blocks the cross-origin read:

```
HTTP/1.1 200 OK
Content-Type: application/json
Vary: Origin
Content-Length: 11

{"ok":true}
```

## How it works

- **An exact-match allowlist.** `allowed_origins` is a `const` array;
  `origin_allowed` checks membership with `in`. No wildcards, no suffix
  matching, no blind reflection.
- **`Vary: Origin` on every variant**, the plain and `403` ones included. The
  response depends on `Origin`, so without it a shared cache (CDN, reverse
  proxy) could store the plain variant and serve it to an allowed origin,
  whose browser would then block the read.
- **The origin stays in the request buffer.** The handler keeps the `Origin`
  value as offsets; the allowlist check reads a `tos` view of those bytes
  (the array `in` only compares, it keeps nothing), and the echo is a
  `push_many` straight from the buffer
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
  An empty `Origin` counts as absent.
- **Consts around the one dynamic part.** Each response is a `const` head
  (`preflight_head`, `ok_cors_head`, appended with `core.append_str`), the
  echoed origin, and a `const` tail (`preflight_tail`, `ok_cors_tail`), all
  appended with `core.append_str`. The fixed responses `resp_403` and
  `resp_ok_plain` are whole consts. Nothing is concatenated or interpolated
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **Routing in place.** `slice_eq` compares the method `Slice` against
  `'OPTIONS'` byte by byte, without building a string.
- Edit `allowed_origins` and the `Access-Control-Allow-Methods` /
  `-Headers` lists in `preflight_tail` to fit your front-end; if you change
  the `{"ok":true}` body, update its `Content-Length: 11` too.

## Tests

```sh
v test examples/cors/src
```

[main_test.v](src/main_test.v) calls `handle` directly: the allowlist,
the preflight for an allowed and a forbidden origin, the echoed origin and
credentials header on simple requests, the plain response for a disallowed
or missing origin, `Vary: Origin` on every variant, and the canned 400 with
`.close` for a malformed request, and that no variant allocates (a
`gc_heap_usage()` delta over 20k rounds).

## See also

- [examples/csrf](../csrf/) — CORS decides who may read; CSRF tokens stop
  forged writes
- [examples/security_headers](../security_headers/) — other headers every response should carry
- [examples/middleware](../middleware/) — cross-cutting wrappers composed with `chain()`
- [examples/auth](../auth/), [examples/cookies_sessions](../cookies_sessions/) — the credentials CORS lets through
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
