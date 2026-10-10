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
// and return .close on a bad request; park on an fd via event_loop.watch_fd(...)
// and return .suspend to wait without blocking the worker (§5). Every input is
// an explicit parameter: client_fd (who), worker_state (this thread's
// make_state value), event_loop (how to wait).
fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
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

- Read from `client_fd` inside a handler — the body is already framed for
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
  [static_assets module](../static_assets/static_assets.v#L388-L396)
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

### 3a. Static responses → a `const` string, appended with `core.append_str`

If a response never changes, write it **once, as a `const` string**, and append
it with [`core.append_str`](../core/append_str.v):

```v
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

core.append_str(mut out, resp_404)
```

No allocation, no formatting — ever. A `const` string is static data, and the
inlined append compiles to a few fixed-size moves: 2.5 ns for a 102-byte
response against 4.7 ns for `out << resp` with a `const ... .bytes()`, whose
bytes are also copied to the heap at startup
([V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md#appending-a-static-response)). Keep
`.bytes()` for a const used as a `[]u8` value — returned, compared, compressed,
or passed to `C.send` — and for the library's public `[]u8` consts
(`out << response.status_413_response`).

### 3b. Dynamic responses → append parts straight into `out`

For responses with dynamic values, append the literal segments and the integers
**directly into `out`** — no intermediate `strings.Builder`, no return-then-copy.
`core.append_str` pushes a string's bytes; for integers, `strconv.write_dec` (or a
small local `wi`, itoa into a stack scratch) writes the decimal digits.

```v
fn wi(mut out []u8, n i64) { /* itoa into a stack buffer, append digits */ }

fn write_json(mut out []u8, body string) {
    core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
    wi(mut out, i64(body.len)) // no .str(), no alloc
    core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n')
    core.append_str(mut out, body)
}
```

A `strings.new_builder` (seeded with `header_overhead + body.len`, written via
`write_string`/`write_decimal`) is still fine where you genuinely need a `string`
result — but on the response hot path, appending into `out` avoids the builder
allocation *and* the builder→`out` copy. **Fully static** responses are a `const`
string appended with `core.append_str` (§3a).

Two things that make the builder go further when a dynamic string is
unavoidable:

- `strings.Builder` **is** `[]u8` (`pub type Builder = []u8`), so you can hand
  the builder's bytes to any `[]u8` API *mid-assembly* and keep appending —
  [examples/auth](../examples/auth/src/main.v) builds `header.payload`, hmac-signs
  the builder directly, then appends the signature: one buffer, zero
  intermediate strings — and `return sb` satisfies a `[]u8` return type.
- **"Slow route" is not an excuse to concatenate.** A login route that pays
  ~200 ms of argon2id still frames its response with `core.append_str`/`wi` and builds its
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
append it. `date_header` now builds the response from two `const` string halves +
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
> `vbytes`/`tos` views of the token, `core.append_str`/`wi` framing the one dynamic response.

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
- **Append bytes directly** — `core.append_str(mut out, s)`; never
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
`event_loop.watch_fd(fd, interest, continuation, watch_payload)` and returns `.suspend`; the
worker parks the connection, serves others, and runs the continuation when
`ext_fd` is ready. The DB driver (`pg_async`), upstream calls, and timers are all
consumers of this one primitive — see the
[wiki](https://github.com/enghitalo/vanilla/wiki/Async-Postgres-and-Pipelining).

For Postgres specifically, `pg_async` is a native (no-libpq) wire client with a
per-worker pool and **cross-request pipelining** (`max_inflight` queries per
connection). Pool connections are **persistent**: park on a pooled fd with
`event_loop.watch_fd_persistent(...)`, never `watch_fd`. Then a client
disconnecting mid-query tombstones the parked request rather than closing the
connection. The continuation still runs when the reply arrives (its response is
discarded), so it drains the reply and releases the slot, and the pooled conn
(and its SCRAM handshake) survives client churn. That draining run may step to
another fd like any continuation: a `watch_fd_persistent` fd runs it the same
way when ready. After a `watch_fd` step (a backoff timer), the runtime closes
that fd once the run returns and the run is never resumed, and a continuation
cannot tell that its client is gone: release the pool slot before such a
step. Nor is a run resumed after a watch the runtime refuses: a `watch_fd` on
the departed client's fd number, and a `watch_fd_persistent` on it unless a
pooled connection of this worker now has that number. Watch one fd per step:
a second watch on the same fd replaces the first, but a run that moves on to
another fd and back leaves a slot on both. With a plain `watch_fd` the
runtime closes the pooled fd and the continuation never runs: the slot leaks,
and once every slot has leaked the worker sheds every query with 503
([vanilla#190](https://github.com/enghitalo/vanilla/issues/190)). Keep
`watch_fd` for per-request fds (a timerfd, a pipe), which must be closed with
their request.

**Do**

- Use the **pool**, not a connection per request; build params/queries into
  reused per-worker buffers (the DB path is allocation-free under `-gc none`).
- Read results with the typed `Row` accessors (`int4`, `text`, `uuid_into`,
  `time`, `numeric_i64_scaled`, `array_iter`, …): they decode the binary
  values in place and allocate nothing, errors included, and the `_into`
  variants append into a buffer you reuse. When you walk an `array_iter`
  yourself, append each element with `push_many`: `out << v.bytes` inside that
  loop makes V move the iterator to the heap, an allocation per call. The
  bytes the accessors return borrow the connection's buffer: copy what must
  outlive the continuation. A typed accessor rejects SQL NULL; read a nullable
  column with `row.col(i)` and test `is_null`. To address columns by name,
  resolve each index once per result (`cols := res.columns()!`, then
  `cols.index('name')`), not once per row. The accessors check a value's
  width, not its column's type: when the query doesn't fix the types, compare
  `cols.type_oid(i)` with `oid_*` once per result.
- Under saturation, **shed with the honest status**: `503 Service Unavailable`
  when the pool is momentarily full, not `400`/`404`. A backpressure shed is not
  a client error — misreporting it as `4xx` showed up as spurious failures in the
  benchmark (see the wiki's *Gotchas* page). Genuine `400` (bad body) / `404`
  (missing row) stay as they are.
- Keep the pool sized to the worker/thread model.
- Expect pooled connections to die (restart, failover, `pg_terminate_backend`,
  idle or lifetime caps): the pool skips a broken connection and re-dials it
  without blocking, so `release` it on every path, error or not. Decide retries
  on the typed error — `err is pg_async.PgError && err.sqlstate == '40001'` —
  and on `conn.is_broken()` for a lost connection, never on the message text.
- Call third-party HTTP APIs through `http1_1.upstream`, the same shape for
  HTTP: a per-worker `Pool` per origin (built in `make_state`, maintenance
  started in `on_worker_start`), `acquire()` / `send()` + `.suspend` in the
  handler, `advance()` in the continuation, `release()` on every path. Shed
  with 503 when `acquire()` has nothing, answer 502 / 504 from `failure()`
  with `.done`. Its views (`body_view`, `header_value`) borrow the exchange's
  buffer until `release()`. Request heads are validated (a CR/LF/NUL in a
  target or a header fails the exchange instead of injecting a line); share one
  `tls.new_client` config across workers. An HTTPS origin may be an IP
  address: its certificate must then carry it as an `IP:` SAN, as for a
  database (below). See
  [examples/https_upstream](../examples/https_upstream/src/main.v).
- Talk TLS to any database that is not on the same host: `ssl_mode:
  .verify_full` (with `ssl_root_cert` for a private CA; the system bundle
  otherwise) is what managed PostgreSQL needs (Aurora DSQL, RDS with
  `rds.force_ssl`, Cloud SQL, Azure, Supabase, Neon) and the only mode that
  authenticates the server — `.require` encrypts against a passive eavesdropper
  but accepts any certificate. Build with `-d vanilla_tls` (Mbed TLS 4, the
  library the HTTPS server uses); without it every TLS mode fails to connect
  rather than falling back to plaintext. The query path is unchanged: the same
  pool, the same `watch_fd_persistent` parking, zero allocations per query;
  the trusted CAs are parsed once per pool and each connection's TLS session
  is allocated once and re-armed on every re-dial. TLS 1.3 only. To reach the
  database by IP address, its certificate must carry that address as an `IP:`
  SAN: `.verify_full` matches an IP host (`10.0.0.5`, or any spelling
  getaddrinfo dials as an address, such as `fe80::1%eth0`) against iPAddress
  SANs only (never a `DNS:` spelling, a wildcard or the CN) and sends it no
  SNI (RFC 9525, RFC 6066; CPython's `ssl` does the same for `10.0.0.5`).
  That is stricter than libpq, whose `verify-full` also takes a `DNS:` or CN
  spelling of the IP: a certificate psql accepts by IP may need an `IP:` SAN
  here.

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
- Verify with the race detector before merging — ThreadSanitizer, with the V
  file:line stacks of both accesses in each report:

  ```sh
  v -race -o vanilla .
  ./vanilla          # drive it with real traffic; exit status 66 = a race was found
  v -race test tests/
  ```

  CI runs the epoll e2e suites under `-race`
  ([race_detector.yml](../.github/workflows/race_detector.yml)). Prefer it to
  `valgrind --tool=helgrind`, which does not model C11 atomics and reports
  atomically published data (the BirthQueue ring, #164) as races.

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
- Never `panic` on request input; answer a `4xx`/`5xx` instead. A V `panic`
  exits the whole process (all workers, every open connection), not just the
  worker that hit it, and vanilla installs no recovery around handler calls.
  Run the server under a supervisor that restarts it (systemd `Restart=always`,
  a container restart policy).

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

See the README's [End-to-End Testing](../README.md#end-to-end-testing) section
for both layers (in-process and over a real socket), and
[VTEST.md](VTEST.md) for the `vtest` scripted client that drives a running
server.

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

## Checklist before every commit / PR

- [ ] **`v fmt -w .` run from the repo root, changes included.** CI gates on
      `v fmt -verify .` with the latest V — an unformatted file (even a
      pre-existing one a newer formatter rule now rewrites) fails the whole PR.
- [ ] Handler stays a pure `(request) -> response` function.
- [ ] No new hidden I/O or shared mutable state on the hot path.
- [ ] Responses carry correct framing and standard headers.
- [ ] Inputs are bounded and validated.
- [ ] Tests added/updated (raw-request E2E where it fits).
- [ ] `v -race` clean; benchmark shows no regression.
- [ ] No new abstraction layer that wasn't strictly necessary.
