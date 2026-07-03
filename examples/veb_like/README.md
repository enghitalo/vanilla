# veb-like router (production reference)

A small, fast HTTP router declared with method attributes and dispatched by a
comptime-unrolled matcher — kept faithful to the project values (no magic,
bytes-in/bytes-out handlers, static dispatch allocation-free, and responses
framed from consts — never `${}`-interpolated) while being safe to put in
front of real traffic.

## Declaring routes

Annotate `App` methods with `@['METHOD /path']`. The router supports two kinds of
dynamic segment:

- **`:param`** — matches exactly one path segment (stops at the next `/`).
- **`*name`** — a **catch-all**: matches the rest of the path, slashes included.
  Must be the last segment.

```v
@['GET /users/:id/posts/:post_id']        // two params
@['GET /files/*path']                      // catch-all: /files/css/app.css -> "css/app.css"
fn (app App) get(req HttpRequest, params map[string]Slice) []u8 { ... }
```

`params[':id']` (or `params['*path']` for a catch-all) is a `Slice` into the
request buffer (zero-copy). The handlers here read it as a byte **view** (see
`p()` in `main.v`) and JSON-escape it straight into the response — call
`.to_string(req.buffer)` only when the bytes must outlive the request buffer.
Query values come from `req.get_query('name')`.

### Every route shape, exercised

The example registers the full variety (see `main.v` and the tests):

| Pattern | Kind |
|---------|------|
| `GET /users`, `POST /users` | static |
| `GET\|PUT\|PATCH\|DELETE /users/:id` | one param at the end, many verbs (→ 405 lists all) |
| `GET /users/:id/profile` | param + literal tail |
| `GET /users/:user_id/posts/:post_id` | two params |
| `GET /users/:user_id/posts/:post_id/comments/:comment_id` | three params, deep |
| `GET /tags/:a/:b/:c` | three consecutive params |
| `GET /search/:term` | single param |
| `GET /files/*path`, `GET /proxy/*upstream` | catch-all (captures slashes) |

Matching is positional and case-sensitive; a `:param` never spans `/` (use `*` for
that), and the query string is ignored for matching (`/users/42?x=/y` still hits
`/users/:id`). The router is a linear comptime-unrolled scan — O(routes) per
request, simple, and lean on allocation: a static hit allocates nothing for
routing; a dynamic or wildcard hit allocates only the `params` map it hands the
handler, created only **after** the match is validated (a non-match allocates
nothing). A trie would trade that for O(path-length) at the cost of "no magic".

## Files

| File | Role |
|------|------|
| `main.v` | `App`, the route handlers, and the production server config |
| `router.v` | dispatch (hot path) + 404/405 resolution (cold path) |
| `router_static.v` | exact `METHOD /path` matcher |
| `router_dynamic.v` | `:param` matcher + extraction, `*` catch-all matcher, attr scan |
| `responses.v` | const-framed JSON responses (computed `Content-Length`) + JSON escaping straight into the body builder |

## Production properties

- **Never crashes on bad input** — a request the parser rejects is answered
  `400`, not `panic`ked (a panic would take down the whole worker thread).
- **Correct HTTP status** — `404` for an unknown path; `405 Method Not Allowed`
  (with an `Allow` header) when the path exists under another method.
- **Accurate `Content-Length`** — computed from the body, never hand-typed.
- **`application/json`** for JSON bodies.
- **Safe output** — URL-derived values (`:params`, query) are JSON-escaped, so a
  `"` or `\` can't break or forge the response (no JSON injection).
- **Query-string–correct matching** — the path is matched up to `?`, so neither a
  query nor a `/` inside it (e.g. `?redirect=/home`) can cause a false `404`.
- **Bounded** — `Limits` cap header/body size and concurrent connections, and
  read/write timeouts reap slow or stalled peers.
- **Graceful shutdown** — `SIGTERM`/`SIGINT` stop new accepts and drain in-flight
  requests before exit (clean rolling deploys).

## Run

```sh
v -prod run examples/veb_like
# GET  /users
# POST /users
# GET  /users/:id            (also PUT/PATCH/DELETE)
# GET  /users/:id/profile
# GET  /users/:user_id/posts/:post_id
# GET  /search/:term?format=json
# GET  /files/*path
```

## Benchmarks (pre-rewrite records)

Historical numbers (wrk -t8 -c128, loopback), measured **before** the
const-framing / lazy-params-map rewrite — re-measure with `-prod` before
quoting:

| Route | Req/sec |
|-------|---------|
| `GET /users` (static) | ~383k |
| `GET /users/1/posts/2` (dynamic) | ~327k |

Hardening added no measurable hot-path cost: the malformed→400 / 405 / escaping
logic lives on the cold path, and the per-request slash count is hoisted out of
the route loop.
