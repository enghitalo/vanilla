# csrf — double-submit tokens for state-changing requests

Cross-Site Request Forgery makes the victim's browser send a request to your
site from someone else's page, riding on the victim's cookies. The defense is
a secret the other page can neither read nor guess. This example uses two
layers:

- **`SameSite=Strict`** on the token cookie, so the browser does not attach it
  to cross-site requests at all.
- **A double-submit token.** `GET /form` issues 32 CSPRNG bytes as a `csrf`
  cookie; every `POST`/`PUT`/`PATCH`/`DELETE` must echo the same value in an
  `X-CSRF-Token` header. Another origin cannot read your cookies, so it cannot
  forge the matching header.

Safe methods (`GET`, `HEAD`, ...) need no token: they must not change state
anyway.

## Run

```sh
v -prod run examples/csrf/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Every path behaves
the same apart from `GET /form`.

Get a token:

```sh
curl -i localhost:3000/form
```

```
HTTP/1.1 200 OK
Set-Cookie: csrf=25d989acf9bc88b980b82143d202a0bf626c26d1d2757606acdb52e3bbc3d07b; Secure; SameSite=Strict; Path=/
Content-Type: text/html
Content-Length: 0
Connection: keep-alive
```

The cookie is not `HttpOnly`: same-origin JavaScript reads it and copies it
into the header. Send it back both ways:

```sh
TOKEN=$(curl -si localhost:3000/form | sed -nE 's/^Set-Cookie: csrf=([0-9a-f]+);.*/\1/p')
curl -i -X POST localhost:3000/transfer -H "Cookie: csrf=$TOKEN" -H "X-CSRF-Token: $TOKEN"
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive
```

No cookie, no header, an empty value or a mismatch (here
`-H "X-CSRF-Token: 0000"`, or a `DELETE` with the header but no cookie):

```
HTTP/1.1 403 Forbidden
Content-Length: 0
Connection: keep-alive
```

A plain `curl -i localhost:3000/transfer` (a `GET`) passes with `200 OK`.

## How it works

- **Enforce on unsafe methods only.** `is_unsafe` compares the method bytes
  in place against `POST`, `PUT`, `PATCH` and `DELETE` (methods are
  case-sensitive tokens, RFC 9110 §9.1).
- **Cookie parsed in place.** `cookie_value` scans the `Cookie` header and
  returns offsets of the `csrf` value: no `split()`, no map. Matches are
  anchored at segment starts, so a cookie named `xcsrf` never counts as
  `csrf`.
- **Constant-time compare over views.** The guards reject a missing header,
  a missing or empty cookie and an empty token with `403` before any view is
  taken; then both tokens reach `hmac.equal` as `vbytes` views of the request
  buffer
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **The one allocation is the token itself.** `rand.bytes(32)` must produce
  fresh CSPRNG bytes; `write_hex` hex-encodes them straight into `out`
  between the `form_head` and `form_tail` consts. All other responses are
  `const` strings appended with `core.append_str`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- The token is not tied to a session here. In an app with logins, bind it to
  the session (or keep it server-side, the synchronizer pattern) and rotate
  it with the session ID; see [examples/cookies_sessions](../cookies_sessions/).

## Tests

```sh
v test examples/csrf/src
```

[main_test.v](src/main_test.v) calls `handle` directly: `/form` sets a fresh
64-hex token with `SameSite=Strict` and `Secure`, `cookie_value` finds the
right segment and is not fooled by `xcsrf=`, every unsafe method is gated,
missing, mismatched, cookie-less and empty tokens get `403`, a matching pair
gets `200`, `GET` passes, and malformed input gets the canned 400.

## See also

- [examples/cookies_sessions](../cookies_sessions/) — `SameSite`, `HttpOnly` and session rotation
- [examples/cors](../cors/) — the `X-CSRF-Token` header is on its preflight allowlist
- [examples/auth](../auth/), [examples/security_headers](../security_headers/)
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
