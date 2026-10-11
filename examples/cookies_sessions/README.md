# cookies_sessions — server-side sessions behind a hardened cookie

HTTP is stateless; a session adds state with a cookie that carries only an
opaque, unguessable id, while the data stays on the server. This example
shows the parts that make that safe:

- the id is 32 bytes from a CSPRNG, never a counter or a timestamp;
- the cookie carries `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/` and a
  `Max-Age` that matches the server-side expiry;
- logout deletes the server-side session, not just the cookie;
- the session store is bounded, so a login flood cannot exhaust memory.

It is **not authentication**: `POST /login` mints a session for the fixed
user `user-42` where a real app would first check credentials (see
[examples/auth](../auth/)).

## Run

```sh
v -prod run examples/cookies_sessions/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Routes: `POST /login`,
`/me`, `/logout`; anything else is `404`.

```sh
curl -i -X POST localhost:3000/login
```

```
HTTP/1.1 200 OK
Set-Cookie: sid=6fd01f41271deee09958b0b3c74d9fc1dd33c8d6fc8aa95c2de1e1ccb44f10ba; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400
Content-Length: 0
```

`/login` changes server state, so any other method gets
`405 Method Not Allowed` with `Allow: POST` and no cookie.

With a cookie jar, the session follows along:

```sh
curl -s -c jar.txt -X POST localhost:3000/login -o /dev/null
curl -i -b jar.txt localhost:3000/me
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 18

{"user":"user-42"}
```

No cookie, an unknown id (`-H 'Cookie: sid=deadbeef'`) or an expired session:

```
HTTP/1.1 401 Unauthorized
Content-Length: 0
```

Log out, and the same id stops working:

```sh
curl -i -b jar.txt localhost:3000/logout
```

```
HTTP/1.1 200 OK
Set-Cookie: sid=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0
Content-Length: 0
```

`curl -i -b jar.txt localhost:3000/me` (`-b` only reads the jar, so it
replays the old `sid`) now gets `401 Unauthorized`.

## How it works

- **A bounded, expiring store.** `Store` is a `map[string]Session` behind a
  `sync.RwMutex`, shared by all workers through a closure in `main()`. Each
  session expires `session_ttl_s` (24 h) after creation, the same const that
  feeds the cookie's `Max-Age`. `get` treats an expired session as absent;
  `create` sweeps expired ones at most every `sweep_every_s` (60 s); `/logout`
  deletes. `max_sessions` (100,000) caps the table and fails **closed**: a new
  login gets `503` with `Retry-After: 60` rather than evicting a live user
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **Injected clock.** `create` and `get` take `now` (`handle` passes the
  monotonic `time.sys_mono_now()`), so the tests drive expiry without sleeping.
- **Cookie parsed in place.** `cookie_value` scans the `Cookie` header by
  offsets and matches the name only at a pair boundary followed by `=`, so
  `xsid=` never counts as `sid`. `session_id` returns the value as a `tos`
  view, which `get` and `delete` only hash and compare, never keep
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Owned strings only where they must outlive the request.** `new_token`
  allocates the id and the per-session `csrf_token`: they live in the store
  as map keys and values. Each is one allocation, the 64 hex bytes and a
  NUL: `rand.read` fills a stack array and the hex is written straight into
  the string's own bytes. That happens
  once per successful login, bounded by `max_sessions`.
- **Consts around the dynamic part.** `resp_logout`, `resp_401`, `resp_405`
  and `resp_503` are whole consts; `/login` is `resp_login_prefix`, the sid,
  `resp_login_suffix`; `/me` writes its Content-Length with `wi` and appends
  the body parts with `core.append_str`. The `${}` inside `resp_503` and
  `resp_login_suffix` runs once, at const init
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v test examples/cookies_sessions/src
```

[main_test.v](src/main_test.v) checks the cookie scanner's rules, the store
(round trip, unknown id, unguessable ids, server-side expiry, the sweep, the
cap failing closed), and the full flow through `handle` with raw requests:
login sets every cookie attribute and a 64-hex id, `/me` frames the body
exactly, logout deletes the session and expires the cookie, a replayed id is
refused, `/login` is POST-only, a full store answers 503, and missing, bogus,
empty and `xsid=` cookies all get 401. `new_token` is checked to cost one
allocation (the string itself).

## See also

- [examples/csrf](../csrf/) — tokens for state-changing requests on top of `SameSite`
- [examples/auth](../auth/) — check credentials before minting a session, or use bearer tokens instead
- [examples/rate_limit](../rate_limit/) — the store cap bounds memory; a limiter bounds login rate
- [examples/cors](../cors/), [examples/security_headers](../security_headers/)
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
