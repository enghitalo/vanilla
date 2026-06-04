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

## 1. Handlers are pure functions

A request handler is a **total function of `(request) -> (response)`**. It must
not touch the socket, read globals, or perform hidden I/O.

```v
fn handle(req request_parser.HttpRequest) []u8 {
    // read req fields, build bytes, return. Nothing else.
}
```

**Do**

- Treat the parsed request as immutable input.
- Build the full response in memory and return it as `[]u8`.
- Keep all framing decisions (Content-Length, chunking) in the core, not in
  the handler.

**Don't**

- Read from `client_conn_fd` inside a handler — the body is already framed for
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

**Don't**

- Copy the whole body to inspect a few bytes.
- Build intermediate `string`s in a loop — concatenation reallocates.

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

### 3b. Dynamic responses → pre-sized builder, write parts separately

For responses with dynamic values, use `strings.new_builder` seeded with a
capacity estimate (grows at most once), write the **literal segments as string
constants**, and write integers with `write_decimal` — which formats into a
stack buffer with **no intermediate string allocation**.

```v
fn json_response(status int, reason string, body string) []u8 {
    mut sb := strings.new_builder(96 + body.len) // header overhead + body
    sb.write_string('HTTP/1.1 ')
    sb.write_decimal(status)        // no .str(), no alloc
    sb.write_u8(` `)
    sb.write_string(reason)
    sb.write_string('\r\nContent-Type: application/json\r\nContent-Length: ')
    sb.write_decimal(body.len)
    sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
    sb.write_string(body)
    return sb
}
```

Compare to the slow form — every `${}` here allocates:

```v
// DON'T: 3+ hidden allocations per response
sb.write_string('HTTP/1.1 ${status} ${reason}\r\n')
sb.write_string('Content-Length: ${body.len}\r\n')
```

**Do**

- Precompute fixed responses as `const`; reuse them.
- Keep literal header text in plain string literals, not interpolated ones.
- Use `write_decimal` (ints), `write_u8` (single bytes), `write_string` (literals).
- Seed the builder with `header_overhead + body.len`.
- Always send an accurate `Content-Length` (or `Transfer-Encoding: chunked`).
- Set `Connection: keep-alive` unless you intend to close.

**Don't**

- Use `${}` to assemble response lines on the hot path.
- Call `.str()` / `int.str()` just to concatenate — `write_decimal` avoids it.
- Forget the blank line (`\r\n\r\n`) between headers and body.
- Compute the body twice (once for the length, once for the payload).

> `${}` is fine **off** the hot path — in `eprintln`/`error()` for logs and
> diagnostics, where readability beats the one-time allocation. That's how the
> core uses it.

---

## 4. Allocate on the hot path with intent

See [V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md) and the memory notes for detail. Key
points:

- `[]u8{len: n}` is **zeroed**; `[]u8{cap: n}` is **uninitialized (noscan)** —
  use the `cap` form and append/read into the spare capacity when you'll
  overwrite the bytes anyway.
- A large `cap` is not free: it adds GC pressure. Size to the realistic case,
  not the worst case.
- Reuse buffers per-connection instead of allocating per-request where the
  lifetime allows it.

---

## 5. Side effects go through pools, off the hot path

Databases, upstreams, and other blocking resources must not stall the event
loop.

**Do**

- Use a **connection pool** (see [examples/database](../examples/database)).
- Keep the pool sized to the worker/thread model; don't open a connection per
  request.
- Return a clean `503` / `504` when a resource is exhausted rather than blocking
  indefinitely.

**Don't**

- Open and close a socket/connection inside every handler invocation.
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

- Wipe caches and free the port between runs; sandboxed `wrk` is noisy — prefer
  A/B comparisons or a micro-benchmark.
- Build with `-prod` for any timing run.

  ```sh
  v -prod .
  wrk -H 'Connection: keep-alive' --connections 512 --threads 16 \
      --duration 10s http://localhost:3000
  ```

**Don't**

- Compare a `-prod` build against a debug build.
- Report a single noisy run as a result.

---

## Checklist before opening a PR

- [ ] Handler stays a pure `(request) -> response` function.
- [ ] No new hidden I/O or shared mutable state on the hot path.
- [ ] Responses carry correct framing and standard headers.
- [ ] Inputs are bounded and validated.
- [ ] Tests added/updated (raw-request E2E where it fits).
- [ ] `helgrind` clean; benchmark shows no regression.
- [ ] No new abstraction layer that wasn't strictly necessary.
