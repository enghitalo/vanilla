# security_headers — harden every response in one place

Six response headers that cost nothing to send and close whole classes of
browser-side attacks, added by **one wrapper around the handler** so no route
can forget them:

| Header | Value here | Stops |
|---|---|---|
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains` | protocol downgrade (HSTS) |
| `Content-Security-Policy` | `default-src 'self'` | most XSS: scripts, styles and connections from other origins |
| `X-Content-Type-Options` | `nosniff` | MIME sniffing |
| `X-Frame-Options` | `DENY` | clickjacking through `<iframe>` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | referrer leaks to other sites |
| `Permissions-Policy` | `geolocation=(), camera=(), microphone=()` | powerful browser APIs |

The wrapper is a plain function from `core.Handler` to `core.Handler`: no
framework, no registry. The same shape composes logging, auth gates, CORS or
rate limiting (see [examples/middleware](../middleware/)).

## Run

```sh
v -prod run examples/security_headers/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) and answers every
request with the same small HTML page.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Strict-Transport-Security: max-age=63072000; includeSubDomains
Content-Security-Policy: default-src 'self'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), camera=(), microphone=()
Content-Type: text/html
Content-Length: 15

<h1>secure</h1>
```

Pipelined requests each get their own hardened response:

```sh
printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /other HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' \
  | socat -t1 - TCP:localhost:3000
```

## How it works

- **One wrap, every response.** `with_security_headers(app)` runs the inner
  handler, then splices the header block in right after its status line. It
  forwards every input unchanged (`client_fd`, `worker_state`, `event_loop`),
  so the wrapped handler can still key on its connection or read its
  `make_state` value. It only touches a response whose handler returned
  `.done`: a `.suspend` has not answered yet, and a `.close` (the canned 400)
  goes out as is.
- **In-place splice, no allocation.** `insert_after_status_line` appends
  `headers.len` bytes to grow `out`, `vmemmove`s the tail right and copies the
  headers into the gap. Once the connection's write buffer has reached its
  high-water mark this allocates nothing.
- **Offsets, never a slice of `out`.** The wrapper records `start := out.len`
  before calling `next` and scans from there, so the earlier responses of a
  pipelined batch are left alone. It never slices `out`: a slice marks the
  server's buffer and its `clear()` would then drop it after every flush
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Consts.** The page is a `const` string appended with `core.append_str`;
  the header block is a `const []u8` (`.bytes()`) because it is passed to
  the splice as bytes.
- The values are a strict starting point. `default-src 'self'` blocks inline
  scripts and third-party assets: loosen the CSP per app, and send HSTS only
  once the site is served over HTTPS for good.

## Tests

```sh
v test examples/security_headers/src
```

[main_test.v](src/main_test.v) calls the wrapped handler directly: all six
headers present, status line first and body intact, byte-exact output after an
earlier response already in `out` (a pipelined batch), a buffer without CRLF
left untouched. One check drives a live server through `vtest.drive` to prove
the wrapper hands `client_fd` and `worker_state` to the inner handler.

## See also

- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
- [BEST_PRACTICES §3a — static responses as `const` strings](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)
- [examples/middleware](../middleware/) — global wrappers composed with `chain()`
- [examples/cors](../cors/), [examples/csrf](../csrf/) — other cross-cutting security concerns
