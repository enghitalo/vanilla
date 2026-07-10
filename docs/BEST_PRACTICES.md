<img src="../logo.png" alt="vanilla Logo" width="80">

# Best Practices

Guidelines for writing fast, correct, and maintainable code with the **vanilla**
HTTP server. They follow the project's three rules from
[CONTRIBUTING.md](../CONTRIBUTING.md):

> 1. Don't slow down performance.
> 2. Always keep abstraction to a minimum.
> 3. Don't complicate it.

Everything below is a concrete way to honor those rules.

---

## 1. Handlers append into the connection's write buffer (zero-alloc)

A request handler is a **pure function of the request that APPENDS the complete
raw response into `out`** — the connection's persistent, server-owned write
buffer — and returns a `core.Step`. It must not touch the socket, read globals,
or perform hidden I/O.

```v
// out is the connection's reused write buffer. Append the full response
// (status line + headers + body) into it; the server batches everything
// appended during one readiness event into a single send. Never free or keep it.
// Return .done when the response is complete; append a canned error response
// and return .close on a bad request; park on an fd via worker.watch(...) and
// return .suspend to wait without blocking the worker (§5).
fn handle(req []u8, mut out []u8, mut worker core.Worker) core.Step {
    // parse req, append bytes into out. Nothing else.
    return .done
}
```

> **Why append instead of returning `[]u8`?** Returning a freshly-built `[]u8`
> per request is one heap allocation (plus a copy into `out`) per request. That
> is invisible on a laptop but **compounds catastrophically under V's GC at high
> core counts**: on the 64-core HttpArena, switching the handler from
> `out << build()` to appending directly into `out` took **json from 115K→485K
> req/s (+322%)** and, once the *last* per-request allocation (the router's
> `all_before('?')`) was also removed, **pipelined from 2.4M→34.9M (+1365%)**.
> Per-request allocation is the single biggest performance lever at scale —
> keep the hot path at **zero allocations**.

**Do**

- Treat the parsed request as immutable input.
- Append the full response **into `out`** (status line + headers + body); let
  the core batch and send it.
- Keep all framing decisions (Content-Length, chunking) in the core, not in
  the handler.

**Don't**

- Read from `worker.client_fd` inside a handler — the body is already framed for
  you.
- Mutate shared state without synchronization (see §6).
- Block on disk, DNS, or a database call on the hot path without a pool (see §5).

---

## 2. Stay zero-copy: work with slices, not copies

The request body and headers are **views (`Slice`) into the request buffer**.
Reach for the bytes you already have before allocating new ones.

**Do**

- Parse over the existing buffer: `req.body.to_string(req.buffer)` only when you
  truly need a `string`.
- Compare header names/values against the slice directly.
- Defer `.clone()` / `.to_string()` until the byte data must outlive the buffer.
- Build a map lookup key as a non-owning view — `unsafe { tos(ptr, len) }` —
  when the map never retains it (it only hashes the key bytes). The
  [static_assets module](../http_server/static_assets/static_assets.v#L273-L281)
  is the canonical example: `key := tos(&buf[rs], rel_len)`, a view straight into
  the request buffer, so routing costs no allocation.
- **Whenever a view suffices, use a view.** `unsafe { (&buf[start]).vbytes(len) }`
  is the `[]u8` twin of `tos`: a header-only window over existing memory
  ("the data is reused, NOT copied" — builtin), with none of the per-call
  slice-marking of `buf[a..b]` (see
  [V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md)). Feed views to any API that only
  *reads* its input — hash/hmac/argon2, base64 decode, comparisons.
  [examples/auth](../examples/auth/src/main.v) passes password, API key and
  bearer token as views straight from the request buffer. Two rules: guard
  `len > 0` before taking `&buf[start]` (indexing bounds-checks), and never
  let a view outlive the buffer it borrows.

**Don't**

- Copy the whole body to inspect a few bytes.
- Build intermediate `string`s in a loop — concatenation reallocates.
- Build a lookup key with a slice expression like `route[8..]` — V `string.substr`
  does `malloc_noscan(len+1)` + `memcpy`, a fresh heap string **every request**
  (a permanent leak under `-gc none`). Isolated proof (2026-06): 20M lookups into
  the same `map[string]int`, `-prod -gc none` — `route[8..]` grows RSS +625 MiB,
  monotonic (~31 B/request); `tos(route.str + 8, route.len - 8)` stays flat at
  +28 KiB. The vanilla library already uses the `tos` view; an HttpArena benchmark
  handler is what regressed here.

---

## 3. Avoid `${}` interpolation on the hot path

String interpolation (`'... ${x} ...'`) is **not free in V**: it allocates a new
`string`, and for non-string values it first calls `.str()` — another
allocation — to format them. On a per-request response builder that overhead is
real and adds GC pressure. The core proves the pattern: it never interpolates to
build responses.

### 3a. Static responses → precompute as `const ... .bytes()`

If a response never changes, build it **once at compile time** and send the
bytes directly. This is exactly what the core does
([response.c.v](../http_server/http1_1/response/response.c.v)):

```v
const status_413_response = 'HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
```

No allocation, no formatting — ever.

### 3b. Dynamic responses → append parts straight into `out`

For responses with dynamic values, append the literal segments and the integers
**directly into `out`** — no intermediate `strings.Builder`, no return-then-copy.
Two tiny no-alloc helpers are all you need: one that pushes a string's bytes, and
one that writes an integer's decimal digits (itoa into a stack scratch).

```v
@[inline]
fn ws(mut out []u8, s string) {
    unsafe { out.push_many(s.str, s.len) } // append bytes, no allocation
}

fn wi(mut out []u8, n i64) { /* itoa into a stack buffer, append digits */ }

fn write_json(mut out []u8, body string) {
    ws(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
    wi(mut out, i64(body.len)) // no .str(), no alloc
    ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
    ws(mut out, body)
}
```

A `strings.new_builder` (seeded with `header_overhead + body.len`, written via
`write_string`/`write_decimal`) is still fine where you genuinely need a `string`
result — but on the response hot path, appending into `out` avoids the builder
allocation *and* the builder→`out` copy. **Fully static** responses should be a
precomputed `const ... .bytes()` appended with `out << the_const`.

Two things that make the builder go further when a dynamic string is
unavoidable:

- `strings.Builder` **is** `[]u8` (`pub type Builder = []u8`), so you can hand
  the builder's bytes to any `[]u8` API *mid-assembly* and keep appending —
  [examples/auth](../examples/auth/src/main.v) builds `header.payload`, hmac-signs
  the builder directly, then appends the signature: one buffer, zero
  intermediate strings — and `return sb` satisfies a `[]u8` return type.
- **"Slow route" is not an excuse to concatenate.** A login route that pays
  ~200 ms of argon2id still frames its response with `ws`/`wi` and builds its
  JWT in one builder. Rules stay simple by having no carve-outs; the only
  place `${}` belongs is off-path diagnostics (below).

Compare to the slow form — every `${}` here allocates:

```v
// DON'T: 3+ hidden allocations per response
sb.write_string('HTTP/1.1 ${status} ${reason}\r\n')
sb.write_string('Content-Length: ${body.len}\r\n')
```

**Do**

- Precompute fixed responses as `const`; reuse them.
- Keep literal header text in plain string literals, not interpolated ones.
- Format ints with `strconv.write_dec`/`write_dec_u` (zero-alloc, into your `[]u8`)
  or `Builder.write_decimal`; `write_u8` (single bytes), `write_string` (literals).
- Seed the builder with `header_overhead + body.len`.
- Always send an accurate `Content-Length` (or `Transfer-Encoding: chunked`).
- Set `Connection: keep-alive` unless you intend to close.

**Don't**

- Use `${}` to assemble response lines on the hot path.
- Concatenate strings (`+`) or interpolate **anywhere in request-serving
  code** — even on a deliberately slow route. Every `'${a}.${b}'` is an
  allocation the builder/append patterns above do for free.
- Call `.str()` / `int.str()` just to concatenate — `strconv.write_dec` avoids it.
- Forget the blank line (`\r\n\r\n`) between headers and body.
- Compute the body twice (once for the length, once for the payload).

> `${}` is fine **off** the hot path — in `eprintln`/`error()` for logs and
> diagnostics, where readability beats the one-time allocation. That's how the
> core uses it.

**Worked example — the `Date` header.** `examples/date_header`, `examples/efficient_date`
and `examples/async_date_timerfd` cache the 1-second-resolution `Date` line and just
append it. `date_header` now builds the response from two `const ... .bytes()` halves +
the cached line appended straight into `out` — no per-request `strings.Builder` (which
also leaked under `-gc none`, §4). `efficient_date` checks the current second with a
cheap `C.time()` instead of constructing a full calendar `time.utc()` on every request.
Honest measurement (wrk `-t8 -c512`, 8 workers pinned, load generator on separate cores):
at the I/O-bound throughput ceiling the three are indistinguishable from each other AND
within run-to-run noise (~3-4%) of a response carrying **no `Date` header at all**. So the
payoff is a zero-allocation, minimal-CPU hot path — mandatory under `-gc none` and
valuable for latency/headroom — **not** raw req/s. Correct, cheap, paid once per second.

> **Worked example — content negotiation.**
> [examples/compression](../examples/compression/src/main.v) takes the const
> pattern to its conclusion: a static body is compressed ONCE at
> init (stdlib brotli/zstd/gzip) into four **complete** const responses, and the
> per-request work is parse → whole-token scan of the `Accept-Encoding` bytes by
> offsets → one `out <<` append. Emitted-C-verified: zero slice/alloc calls in
> the handler.
>
> **Worked example — auth.** [examples/auth](../examples/auth/src/main.v) applies the
> same byte discipline where responses *can't* all be consts: argon2id login
> (slow by design), JWT signed in a single builder, verification over
> `vbytes`/`tos` views of the token, `ws`/`wi` framing the one dynamic response.

---

## 4. Allocate on the hot path with intent

The build mode differs by backend: **epoll ships `-prod -gc none`** — no garbage
collector, **nothing is ever freed**, so a per-request allocation is not "GC
pressure" but a permanent **leak** that grows RSS linearly with traffic; the hot
path must be *literally allocation-free*. **io_uring ships `-prod`** with the
default Boehm GC (per-request allocs are reclaimed). On the pinned V master the
GC's allocation lock is gone (thread-local alloc), so default-GC allocation scales
across cores — the alloc-free patterns below still matter (they cut GC
**collection** pauses), and remain mandatory under `-gc none`. See
[V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md) and the
[wiki](https://github.com/enghitalo/vanilla/wiki/Memory-Management-under-gc-none).

The recurring zero-allocation patterns:

- **Reuse a per-worker buffer** — reset `len=0`, grow to a high-water mark, keep
  it. The worker is single-threaded, so one buffer is safe across requests (this
  is what the per-worker render scratch does). This is the single most important
  pattern.
- **Borrow, don't copy** — return `tos`/slice views into the read buffer; defer
  `.clone()`/`.bytes()` until bytes must outlive the buffer (they rarely do —
  responses are built synchronously before the buffer is recycled).
- **Append bytes directly** — `unsafe { out.push_many(s.str, s.len) }`; never
  build an intermediate `string`/`[]u8` just to append it.
- **Pool structs on a free-list** — reuse a heap object across requests, resetting
  its fields on release (the per-worker `ConnState` and per-request `Stash` pools
  do this), instead of `&T{}` per request.
- **No error-boxing on the hot path** — `error("msg")` allocates a `MessageError`;
  on a hot `!T` "not found" return the cached `error_sentinel` (alloc-free, like
  `none` for `?T`) or a plain-int twin (`find_byte_idx`, `frame_request_length_lim_idx`).
- **No transient array literals** — `buf << [u8(0),0,0,0]` heap-allocates a
  temporary array; append the elements or use a module `const`. (Empty `[]T{}` at
  `len==0,cap==0` no longer allocates on the pinned V — that leak is fixed.)
- **Sizing (default-GC builds only):** `[]u8{cap: n}` is uninitialized/noscan,
  `{len: n}` is zeroed, and a large `cap` is GC pressure. Under `-gc none` it is
  the *reuse* that matters, not the flag — a fresh buffer of any size leaks.

---

## 5. Side effects go through the async runtime + pools, off the hot path

Databases, upstreams, and other blocking resources must not stall the event
loop. The watch runtime exists exactly for this: a handler that must wait calls
`worker.watch(ext_fd, interest, continuation, udata)` and returns `.suspend`; the
worker parks the connection, serves others, and runs the continuation when
`ext_fd` is ready. The DB driver (`pg_async`), upstream calls, and timers are all
consumers of this one primitive — see the
[wiki](https://github.com/enghitalo/vanilla/wiki/Async-Postgres-and-Pipelining).

For Postgres specifically, `pg_async` is a native (no-libpq) wire client with a
per-worker pool and **cross-request pipelining** (`max_inflight` queries per
connection). Pool connections are **persistent** (`watch_persistent`): a client
disconnecting mid-query tombstones the parked request rather than closing the
connection, so the pooled conn (and its SCRAM handshake) survives client churn.

**Do**

- Use the **pool**, not a connection per request; build params/queries into
  reused per-worker buffers (the DB path is allocation-free under `-gc none`).
- Under saturation, **shed with the honest status**: `503 Service Unavailable`
  when the pool is momentarily full, not `400`/`404`. A backpressure shed is not
  a client error — misreporting it as `4xx` showed up as spurious failures in the
  benchmark (see the wiki's *Gotchas* page). Genuine `400` (bad body) / `404`
  (missing row) stay as they are.
- Keep the pool sized to the worker/thread model.

**Don't**

- Open/close a socket or connection inside every handler invocation.
- Block the worker on a DB/upstream call — `watch` + `.suspend` instead.
- Return `200` with empty data for a *write* that was shed (it's a lie about a
  mutation) — `503` is the honest answer. (The backpressure policy is tracked in
  [vanilla#51](https://github.com/enghitalo/vanilla/issues/51).)
- Log synchronously to disk on the hot path — batch or hand off (see
  [examples/middleware](../examples/middleware) access log).

---

## 6. Concurrency: no shared mutable state without protection

The server is multi-threaded, lock-free, and uses `SO_REUSEPORT`. Memory safety
is a first-class guarantee — keep it that way.

**Do**

- Prefer per-connection / per-request state over global state.
- If you must share, protect it (atomics, channels, or a lock) and measure the
  cost.
- Verify with the race checker before merging:

  ```sh
  v -prod -gc none .
  valgrind --tool=helgrind ./vanilla
  ```

**Don't**

- Mutate a package-level `mut` variable from a handler.
- Assume handlers run serially — they don't.

---

## 7. Follow the HTTP standards

vanilla targets [RFC 9112](https://datatracker.ietf.org/doc/rfc9112/) and the
[IANA Field Name Registry](https://www.iana.org/assignments/http-fields/http-fields.xhtml).

**Do**

- Use canonical, registered header field names.
- Frame bodies by `Content-Length` or `Transfer-Encoding: chunked` — never
  guess.
- Return correct status codes and reason phrases.
- Treat header names case-insensitively when matching.

**Don't**

- Emit non-standard headers when a registered one exists.
- Send a body with a status that forbids one (`204`, `304`).

---

## 8. Security defaults

- Validate and bound every input: enforce request-size limits
  (see [examples/request_limits](../examples/request_limits)).
- Add the standard protective headers
  (see [examples/security_headers](../examples/security_headers)).
- Apply CORS, CSRF, and rate limiting where relevant
  ([cors](../examples/cors), [csrf](../examples/csrf),
  [rate_limit](../examples/rate_limit)).
- Never reflect raw user input into responses without encoding (`json.encode`
  for JSON, escape for HTML).
- Don't leak internal errors to clients — log detail server-side, return a
  generic message.

---

## 9. Test without a running server

Handlers are pure, so you can feed them raw requests directly via
`handle_request()` — no listening socket required.

**Do**

- Write end-to-end tests that pass raw request bytes and assert on the response
  bytes (see [examples/simple](../examples/simple) `*_test.v`).
- Cover malformed input, truncated bodies, and oversized requests.
- Exercise edge cases with raw requests:

  ```sh
  printf "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" \
    | nc localhost 3000
  ```

See [examples/TESTING.md](../examples/TESTING.md) for the full guide.

---

## 10. Benchmark before and after every perf change

Performance claims must be measured, not assumed.

**Do**

- Wipe caches (`v wipe-cache`) and free the port between runs; sandboxed `wrk` is
  noisy — prefer A/B comparisons or a micro-benchmark.
- Build with `-prod` for any timing run; build `-prod -gc none` to match
  production.
- To tell a real change from machine noise, drive micro-benchmarks through
  [`bench/measure.sh`](../bench/measure.sh). It pins the work to one core, prints
  the environment that shaped the numbers (governor, turbo, SMT sibling) with the
  exact fix when it isn't quiesced, and reports the **minimum** across N runs — not
  the mean. The minimum is the right estimator: every source of noise (an
  interrupt, a migration, a turbo step-down) only makes a run *slower*, so the
  fastest run is closest to the true cost. The reported spread is your noise floor
  — a delta smaller than the spread is not measurable on that machine.

  ```sh
  v -prod -gc none -o /tmp/bench bench/request_parser/request_parser_bench.v
  bench/measure.sh /tmp/bench              # min / median / spread
  BENCH_PERF=1 bench/measure.sh /tmp/bench # + perf stat (cycles, IPC, misses)
  ```

  ```sh
  v -prod -gc none .
  wrk -H 'Connection: keep-alive' --connections 512 --threads 16 \
      --duration 10s http://localhost:3000
  ```

- For any change that touches allocation, **also check the RSS slope under `-gc
  none`** (it must be flat) — measure the growth *in excess of a Boehm build's*,
  and use callgrind to attribute any residual per-request allocation by call
  site. See [V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md) ("Profiling allocations").
- Confirm perf changes on a **high-core** run, not just a laptop: a couple of
  small per-request allocs look like noise at 4–16 cores but can be a multiple-x
  swing at 64 (and under `-gc none`, a runaway leak at scale).

**Don't**

- Compare a `-prod` build against a debug build.
- Report a single noisy run as a result.
- Trust a flat RSS line alone — subtract the Boehm floor first (see above).

---

## Checklist before opening a PR

- [ ] Handler stays a pure `(request) -> response` function.
- [ ] No new hidden I/O or shared mutable state on the hot path.
- [ ] Responses carry correct framing and standard headers.
- [ ] Inputs are bounded and validated.
- [ ] Tests added/updated (raw-request E2E where it fits).
- [ ] `helgrind` clean; benchmark shows no regression.
- [ ] No new abstraction layer that wasn't strictly necessary.
