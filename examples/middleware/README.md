# Middleware — the recommended pattern

How cross-cutting concerns compose on vanilla **without** a framework. No
middleware registry, no DI, no dynamic dispatch — just pure function
composition, honoring Invariant 2 of the [implementation plan](../../IMPLEMENTATION_PLAN.md).

There are exactly two shapes, used for two different jobs.

## File layout

| File                                 | Responsibility                                                                                                  |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| [`chain.v`](src/chain.v)             | The composition primitive — `Handler` / `Middleware` types and `chain()`.                                       |
| [`decorators.v`](src/decorators.v)   | **Global** middleware: `with_security_headers` + the single-allocation `inject_headers`.                        |
| [`access_log.v`](src/access_log.v)   | **Global** middleware: a buffered, zero-alloc, no-reparse access log written to a file.                         |
| [`auth.v`](src/auth.v)               | **Per-route** guards (Pattern A): `require_auth`, `require_role`, `auth_error_response`.                         |
| [`controllers.v`](src/controllers.v) | The router (`route`) + controllers; each declares its own auth policy.                                          |
| [`main.v`](src/main.v)               | Wiring: `chain(route, with_security_headers, access_log_mw(log))` + flush-on-shutdown + `server.run()`.         |

## 1. Global middleware → `fn (next) fn` wrappers, composed with `chain()`

For concerns that apply to **every** response (security headers, access logging).
Composed once at startup, so the hot path pays only the (inlinable) wrapper calls
— no per-request bookkeeping.

```v
handler := chain(route, with_security_headers, access_log_mw(log))
// request flow:  security -> log -> route
// response flow: route -> log -> security   (first listed = outermost)
```

## 2. Per-route auth → an explicit guard at the top of the controller ("Pattern A")

For policy that **varies per route** (public vs private vs role-gated). The guard
is right there in the controller — you read the policy where the handler is, and
no hidden mechanism can apply (or forget) it.

```v
// PUBLIC — no guard
fn handle_home(_ HttpRequest) []u8 { return ok_json(...) }

// PRIVATE — any authenticated user
fn handle_profile(req HttpRequest) []u8 {
	user := require_auth(req) or { return auth_error_response(err) }   // 401
	...
}

// ROLE-GATED — admins only
fn handle_admin(req HttpRequest) []u8 {
	user := require_role(req, 'admin') or { return auth_error_response(err) }  // 401 or 403
	...
}
```

## The access log, made efficient

The handler closure runs concurrently on every worker and gets only the request
bytes + fd — no worker id, no thread-local. So a shared log has to be fast
*and* correct without per-worker state. [`access_log.v`](src/access_log.v) does it
with three wins over the naive `println` + `decode_http_request`:

- **No syscall per request.** The log is a buffered C stream opened in append
  mode (`fopen(path, "ab")`); `fwrite` accumulates in glibc's ~8 KB buffer and
  flushes in batches, so hundreds of requests share one `write(2)`.
- **No full parse.** `"METHOD PATH"` is the contiguous prefix of the request line
  (up to the 2nd space) — found with one `memchr`. Headers are never scanned.
- **No heap allocation.** The line is assembled in a stack buffer and written in
  **one** `fwrite`. glibc holds the stream lock for that single call, so the line
  is atomic across workers (no interleaving) without any userspace mutex.

> Buffered means the tail is lost if not flushed — `main.v` flushes on
> SIGINT/SIGTERM. The next optimization (lock-free **per-worker** buffers) needs
> a thread-local slot, which this server doesn't expose to the handler; the glibc
> stream lock is the only remaining contention point.

## The rules (why it stays fast)

- **Decorators inject headers with `inject_headers()` — a single allocation.**
  The naive `resp.bytestr()` + concat + `.bytes()` does **three** allocations per
  response and breaks the zero-alloc-on-hot-path budget.
- **The access log neither parses nor allocates** — one `memchr`, a stack buffer,
  a buffered `fwrite`. Logging is the classic place a careless decorator silently
  halves throughput.
- **`chain()` is composed once at startup** — no dynamic dispatch, ~2 ns per wrapper.
- **Guards read only the cheap zero-copy slices they need** (`get_header_value_slice`,
  ~25 ns), never a full decode.

## Benchmarks

### Micro-bench (ns/op, no network — `v -prod run bench/middleware/middleware_bench.v`)

5M iterations, this machine (16 cores). The point is each **A/B**: single-alloc
header injection vs the naive string round-trip; the cost of `chain`; and
producing a log line the cheap way vs decode + interpolate.

| Operation                                   | Total (5M) | ~ns/op |
| ------------------------------------------- | ---------: | -----: |
| `inject_headers` (1 alloc, **recommended**) |     300 ms |    ~60 |
| `inject_headers_string` (3 allocs, naive)   |     520 ms |   ~104 |
| direct handler call (no middleware)         |     109 ms |    ~22 |
| `chain` 3-deep call (3 middlewares)         |     167 ms |    ~33 |
| access log line — decode + interpolate (old)|     613 ms |   ~123 |
| access log line — memchr + assemble (new)   |      77 ms |    ~15 |

→ the single-allocation injector is **≈1.7× cheaper**; a 3-deep chain adds
**~2 ns per wrapper**; the zero-alloc/no-parse log line is **≈8× cheaper** (and
drops ~4 allocations) — before counting the batched-vs-per-request syscall win.

### End-to-end throughput (`wrk -t16 -c512 -d20s`, keep-alive)

Each request goes through the full path: parse → dispatch → (auth guard) →
build → `access_log_mw` (buffered `fwrite`) → `with_security_headers`. Wiped V
cache + freed port first; single run, sandbox (numbers swing run-to-run — treat
as a ballpark, not a gate). For reference, the [veb_like](../veb_like)
dynamic-route baseline is ~310k req/s.

| Route        | Policy                  | Requests/sec | Avg latency |
| ------------ | ----------------------- | -----------: | ----------: |
| `GET /`      | public (no guard)       |  **361,081** |     1.36 ms |
| `GET /me`    | `require_auth` (Bearer) |  **333,586** |     1.43 ms |
| `GET /admin` | `require_role('admin')` |  **335,137** |     1.50 ms |

→ the buffered file logger is **faster than the old per-request `println`** (public
rose ~314k → ~361k); the per-route auth guard costs ~7% versus the public route.
The wrapper pattern carries no structural overhead.

## Run

```sh
v -prod run examples/middleware/src      # serve on :3000 (access log -> ./access.log)
v test examples/middleware/src           # pure tests (composition + auth + log format)
v -prod run bench/middleware/middleware_bench.v   # ns/op micro-bench
```

```sh
curl localhost:3000/                                         # 200 (public)
curl -i localhost:3000/me                                    # 401
curl localhost:3000/me    -H 'Authorization: Bearer tok-alice'   # 200 (user)
curl localhost:3000/admin -H 'Authorization: Bearer tok-alice'   # 403 (wrong role)
curl localhost:3000/admin -H 'Authorization: Bearer tok-root'    # 200 (admin)
tail -f access.log                                           # GET /me 200, ...
```

> The token table in `user_for_token` is **demo only** — in production validate a
> signed JWT (see [examples/auth](../auth)) instead of a static map.
