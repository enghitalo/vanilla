# auth — password hashing, JWT and API keys on the stdlib

Three authentication mechanisms, each in the context it fits, built on V's
stdlib alone:

| Route | Mechanism | Cost per request |
|---|---|---|
| `POST /token` | argon2id password check (RFC 9106), answers with a signed JWT | ~200 ms and 64 MiB by design, offloaded off the worker |
| `GET /protected` | `Authorization: Bearer <JWT>` (HS256), signature and `exp` checked | allocates nothing |
| `GET /service` | `X-API-Key`, only its SHA-256 is stored | allocates nothing |

Every secret comparison is constant time (`hmac.equal`), a token without a
future `exp` is rejected, and the signing key comes from the environment,
never from source.

## File layout

| File | What |
|---|---|
| [main.v](src/main.v) | routes, argon2 verify, JWT mint/verify, API-key check, per-worker `AuthState` |
| [offload_nix.c.v](src/offload_nix.c.v) | Linux/macOS: the per-worker argon2 pool and the `.suspend` resume (`token_done`) |
| [offload_windows.c.v](src/offload_windows.c.v) | Windows stub: no pool, logins verify inline |

## Run

The HMAC key is read from `JWT_SECRET` (at least 32 bytes). Without it
`main()` refuses to start:

```
JWT_SECRET must be set to at least 32 random bytes, e.g.
  JWT_SECRET=$(openssl rand -base64 32) v run examples/auth/src
```

```sh
JWT_SECRET=$(openssl rand -base64 32) v -prod run examples/auth/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Startup takes a moment:
the demo user's argon2id hash is computed once at init. The demo credentials
are constants in the source, for the demo only: password
`correct horse battery staple`, API key `secret-api-key-123`.

Log in (the body is the password):

```sh
curl -i -X POST localhost:3000/token -d 'correct horse battery staple'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 139
Connection: keep-alive

{"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLTQyIiwiZXhwIjoxNzkxNjk0NjM1fQ.dxe2lbdfVu7qAJwBCcbEhCYQHljbEOfPZFCwKNeTIrI"}
```

The payload is `{"sub":"user-42","exp":<now + 1 h>}`; the signature depends
on your `JWT_SECRET`. A wrong password gets `401`, a `GET` gets
`405` with `Allow: POST`.

Use the token:

```sh
TOKEN=$(curl -s -X POST localhost:3000/token -d 'correct horse battery staple' | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -i localhost:3000/protected -H "Authorization: Bearer $TOKEN"
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive
```

No token, or a tampered one (`"Bearer ${TOKEN%?}A"`), and likewise an
expired one:

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Length: 0
Connection: keep-alive
```

Service-to-service with the API key:

```sh
curl -i localhost:3000/service -H 'X-API-Key: secret-api-key-123'
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive
```

A wrong or missing key gets a plain `401 Unauthorized`; any other path `404`.

## How it works

- **Passwords: argon2id, never plaintext.** `demo_password_phc` is a PHC
  string (random salt and parameters inside it) made by
  `argon2.generate_from_password`; `verify_password` re-derives and compares
  in constant time. Slow and memory-hard is the security property.
- **The slow login does not block the worker.** On epoll/kqueue,
  `try_offload` copies the password out of the request buffer, queues it on
  this worker's `HashPool` (`hash_pool_size` = 2 threads, `hash_queue_cap` =
  64 pending), watches a pipe with `event_loop.watch_fd` and returns
  `.suspend`. A pool thread runs argon2 and writes a one-byte verdict;
  `token_done` resumes the connection on the worker thread. A full queue sheds
  load with `503` instead of blocking. Windows has no watch reactor, so it
  verifies inline ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
- **Per-worker crypto state.** `make_auth_state` (the `make_state` hook)
  builds one `AuthState` per worker: the HMAC keyed with `jwt_secret`, the
  API-key SHA-256 digest, a bounded payload decode scratch, and the pool.
  Requests reuse them through `worker_state` (`write`/`sum_into`/
  `checksum_into` never allocate); MACs land in stack arrays.
- **JWT signed in place in `out`.** `write_token_200` knows the token's
  length up front (`jwt_len`), writes `Content-Length`, then `append_jwt`
  base64url-encodes header and payload straight into `out`, signs a `vbytes`
  view of those bytes and appends the signature. No builder, no `+`, no `${}`
  even on this slow route
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- **Verification over views.** `bearer_token` returns a view of the header
  after `Bearer ` (scheme matched case-insensitively). `jwt_verify` finds the
  two dots, HMACs a view of `header.payload`, compares the signature in its
  encoded form with `hmac.equal` (so non-canonical base64url spellings are
  rejected), refuses a payload longer than `jwt_payload_b64_max`, decodes it
  into the worker scratch and requires `exp_of(...) > time.unix_now()`
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **API keys hashed, compared in constant time.** `check_api_key` hashes the
  presented key view and `hmac.equal`s it against `known_api_key_hash`; the
  key itself is never stored.
- **Consts and offsets.** Every fixed response (`resp_401_bearer`,
  `resp_405`, `resp_503`, ...) is a `const` string appended with
  `core.append_str`; `slice_eq` routes by comparing the request `Slice` in
  place.
- **No known key fallback.** `load_jwt_secret` falls back to a random
  per-process key when `JWT_SECRET` is short, so even the tests never sign
  with a constant; `main()` itself insists on the real one, since a random key
  would not survive a restart or match across replicas.

## Tests

```sh
v test examples/auth/src
```

[main_test.v](src/main_test.v) feeds raw requests to `handle` and checks the
crypto directly: JWT round-trip, byte-identical to the stdlib HMAC and
base64url, tamper, non-canonical signature, expiry, missing `exp`, oversized
payload and garbage rejection, argon2 verify, the API-key check, and that
`/protected`, `/service`, 404 and 405 (and the login's response writer)
allocate nothing over 20k rounds. [server_end_to_end_test.v](src/server_end_to_end_test.v)
(Linux) drives a one-worker server through `vtest` and shows that a login in
flight does not hold up `/protected`, against an inline-argon2 handler that does.

## See also

- [examples/cookies_sessions](../cookies_sessions/) — server-side sessions instead of bearer tokens
- [examples/csrf](../csrf/) — protect cookie-authenticated forms
- [examples/rate_limit](../rate_limit/) — bound login attempts
- [examples/cors](../cors/), [examples/security_headers](../security_headers/)
- [examples/async_pipe](../async_pipe/) — the pipe-and-`.suspend` pattern the login offload uses
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
