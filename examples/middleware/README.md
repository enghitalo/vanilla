# Middleware — the recommended pattern

How cross-cutting concerns compose on vanilla **without** a framework. No
middleware registry, no DI, no dynamic dispatch — just pure function
composition, honoring rule 2 of [CONTRIBUTING.md](../../CONTRIBUTING.md)
(keep abstraction to a minimum).

There are exactly two shapes, used for two different jobs.

## File layout

| File                                 | Responsibility                                                                                                   |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| [`chain.v`](src/chain.v)             | The composition primitive — `Handler` / `Middleware` types and `chain()`.                                        |
| [`decorators.v`](src/decorators.v)   | **Global** middleware: `with_security_headers` + `insert_after_status_line`, an in-place, zero-alloc splice.     |
| [`access_log.v`](src/access_log.v)   | **Global** middleware: a buffered, zero-alloc, no-reparse access log written to a file.                          |
| [`auth.v`](src/auth.v)               | **Per-route** guard (Pattern A): `require_auth` (`?User`), the zero-copy `bearer_token`, the 401/403 responses. |
| [`controllers.v`](src/controllers.v) | The router (`route`) + controllers; each declares its own auth policy and appends its response into `out`.      |
| [`main.v`](src/main.v)               | Wiring: `chain(route, with_security_headers, access_log_mw(log))` + flush-on-shutdown + `server.run()`.          |

## 1. Global middleware → `fn (next) fn` wrappers, composed with `chain()`

For concerns that apply to **every** response (security headers, access logging).
Composed once at startup, so the hot path pays only the wrapper calls — no
per-request bookkeeping.

```v
handler := chain(route, with_security_headers, access_log_mw(log))
// request flow:  security -> log -> route
// response flow: route -> log -> security   (first listed = outermost)
```

A wrapper notes where its response starts in `out` (the connection's reused
write buffer, which may already hold earlier pipelined responses), calls
`next`, then works on the bytes from that offset on:

```v
start := out.len
step := next(req_buffer, mut out, client_fd, worker_state, mut event_loop)
if step != .done {
	return step
}
insert_after_status_line(mut out, start, security_headers) // splice in place
```

## 2. Per-route auth → an explicit guard at the top of the controller ("Pattern A")

For policy that **varies per route** (public vs private vs role-gated). The guard
is right there in the controller — you read the policy where the handler is, and
no hidden mechanism can apply (or forget) it. Controllers append their response
into `out`; a denial is a `const` response, not an error value.

```v
// PUBLIC — no guard
fn handle_home(mut out []u8) {
	core.append_str(mut out, home_response)
}

// PRIVATE — any authenticated user
fn handle_profile(req HttpRequest, mut out []u8) {
	user := require_auth(req) or {
		core.append_str(mut out, unauthorized_response) // 401
		return
	}
	...
}

// ROLE-GATED — admins only
fn handle_admin(req HttpRequest, mut out []u8) {
	user := require_auth(req) or {
		core.append_str(mut out, unauthorized_response) // 401
		return
	}
	if user.role != 'admin' {
		core.append_str(mut out, forbidden_response) // 403
		return
	}
	...
}
```

A dynamic body is framed without a builder: sum its length first, then append
the head, the Content-Length digits and the parts.

```v
append_json_ok_head(mut out, admin_name.len + user.name.len + admin_end.len)
core.append_str(mut out, admin_name)
core.append_str(mut out, user.name)
core.append_str(mut out, admin_end)
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

- **The composed chain allocates nothing per request** — every route and
  outcome, checked by `test_chain_allocates_nothing` (20k rounds,
  `gc_heap_usage()`).
- **Never slice `out`.** `out[start..]` marks the write buffer as shared, and
  the worker's `out.clear()` then drops it instead of reusing it, so it is
  reallocated on the next request. Pass the `start` offset instead:
  `insert_after_status_line(mut out, start, …)`, `log.record(req_buffer, out, start)`.
  `test_chain_keeps_the_write_buffer` checks the buffer survives every route.
- **Decorators splice in place.** `insert_after_status_line` appends to make
  room, shifts the tail with `vmemmove` and copies the headers into the gap —
  no new array, no copy back.
- **Controllers append into `out`.** Fixed responses are `const` strings appended
  with `core.append_str`; dynamic ones are framed part by part (`core.append_str`
  + `wi`) — no `${}`, no `strings.Builder`, no return-then-copy.
- **Guards read views, not copies.** The router matches the path as a `tos` view
  into `req_buffer`; `bearer_token` compares the `Bearer ` prefix in place and
  returns the token as a view (matched, never stored); a denial returns `none`,
  not an `error()`.
- **The access log neither parses nor allocates** — one `memchr`, a stack buffer,
  a buffered `fwrite`. Logging is the classic place a careless decorator silently
  halves throughput.
- **`chain()` is composed once at startup** — no dynamic dispatch, a few ns per
  wrapper.

## Benchmarks

### Micro-bench (ns/op, no network — `v -prod run bench/middleware/middleware_bench.v`)

5M iterations, best of 3 runs, Ryzen 7 5800H (16 threads), V 0.5.2 407c52e,
`-prod` (default GC). The point is each **A/B**: the in-place splice vs building
a new array per response; the cost of `chain`; and producing a log line the
cheap way vs decode + interpolate. Each header-injection variant decorates a
response sitting in a reused `out`, cleared with `clear()` after every response
as the epoll worker does.

| Operation                                                  | Total (5M) | ~ns/op |
| ---------------------------------------------------------- | ---------: | -----: |
| `insert_after_status_line` (in place, 0 allocs, **used**)  |     186 ms |    ~37 |
| `inject_headers` (new array + `out[start..]`, old)         |     850 ms |   ~170 |
| `inject_headers_string` (3 allocs + `out[start..]`, naive) |   1,113 ms |   ~223 |
| direct handler call (no middleware)                        |      43 ms |     ~9 |
| `chain` 3-deep call (3 middlewares)                        |     141 ms |    ~28 |
| access log line — decode + interpolate (old)               |     934 ms |   ~187 |
| access log line — memchr + assemble (new)                  |      21 ms |     ~4 |

→ the in-place splice is **≈4.6× cheaper** than the single-allocation injector
it replaced (which also lost the write buffer to `out[start..]`) and **≈6×**
cheaper than the string round-trip; a 3-deep chain adds **~7 ns per wrapper**;
the zero-alloc/no-parse log line is **≈45× cheaper** — before counting the
batched-vs-per-request syscall win.

### End-to-end throughput (`wrk -t16 -c512 -d10s`, keep-alive)

Each request goes through the full path: parse → dispatch → (auth guard) →
append → `access_log_mw` (buffered `fwrite`) → `with_security_headers`. `-prod`
build, wrk on the same Ryzen 7 5800H, access log on `/dev/null`, best of 2
runs. The machine was shared and runs swung by up to 30%: treat these as a
ballpark, not a gate.

| Route        | Policy                  | Requests/sec | Avg latency |
| ------------ | ----------------------- | -----------: | ----------: |
| `GET /`      | public (no guard)       |  **289,328** |     1.78 ms |
| `GET /me`    | `require_auth` (Bearer) |  **284,079** |     1.77 ms |
| `GET /admin` | `require_auth` + role   |  **289,586** |     1.74 ms |

→ the per-route auth guard is within noise of the public route; the wrapper
pattern carries no structural overhead.

## Run

```sh
v -prod run examples/middleware/src      # serve on :3000 (access log -> ./access.log)
v test examples/middleware/src           # composition + auth + log format + zero-alloc chain
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
