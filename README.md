<img src="./logo.png" alt="vanilla Logo" width="100">

# vanilla

A minimalist, high-performance HTTP server written in [V](https://vlang.io).

## Features

- **Fast**: Multi-threaded, non-blocking I/O, lock-free, copy-free, I/O multiplexing, `SO_REUSEPORT` (native load balancing on Linux)
- **Modular**: Easy to extend with custom controllers and handlers.
- **Memory Safety**: No race conditions.
- **No Magic**: Transparent and straightforward.
- **E2E Testing**: Test handlers in-process by passing raw requests directly to `handle_request()`, or drive a running server over a real socket with `net.dial_tcp` and a read deadline (see [`tests/backend_behaviors_test.v`](tests/backend_behaviors_test.v)).
- **SSE Friendly**: Built-in Server-Sent Events support (sync and async).
- **ETag Friendly**: Conditional GETs with `ETag` and `If-None-Match` headers.
- **Database Friendly**: Example with PostgreSQL connection pool.
- **Graceful Shutdown**: Drain in-flight requests on `SIGTERM`/`SIGINT` via `srv.shutdown(grace_ms)`.
- **Multiple Backends**: epoll, io_uring (Linux), kqueue (macOS), IOCP (Windows).
- **Local IPC**: listen on a unix domain socket (`ServerConfig.unix_socket_path`) instead of TCP — ≈3× lower RTT than TCP loopback, filesystem permissions as access control; dial other local services with `transport.dial_unix`/`dial_tcp`.
- **One Handler Contract**: a single `handler` signature covers every use case, with every input as an explicit, self-describing parameter — append the response and return `.done`, suspend/resume on any fd (DB sockets, timers, upstream proxies) with `event_loop.watch_fd(...)` + `.suspend`, and reach lock-free per-worker state (e.g. a per-thread DB connection — no shared pool, no mutex) via the `worker_state` parameter.
- **Compliant with HTTP standards**: Follows [RFC 9112](https://datatracker.ietf.org/doc/rfc9112/) and the [IANA Field Name Registry](https://www.iana.org/assignments/http-fields/http-fields.xhtml). A dedicated [`examples/conformance/`](examples/conformance/) handler is probed in CI by [h1spec](https://github.com/dropseed/h1spec) and [Http11Probe](https://github.com/MDA2AV/Http11Probe) — see [Conformance Testing](#conformance-testing).

---

## Usage Examples

### 1. Simple HTTP Server

```v
import server
import core

fn handle_request(request []u8, mut response []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	// Parse the request and APPEND the complete raw HTTP response
	// (status line + headers + body) to `response`. The server owns it,
	// reuses it across requests and batches pipelined responses into a
	// single send — never free or keep it. Return `.done` when the
	// response is complete, `.close` to flush-and-drop the connection, or
	// `.suspend` after parking the request via `event_loop.watch_fd(...)`.
	response << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'.bytes()
	return .done
}

fn main() {
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		handler:         handle_request
		io_multiplexing: backend
	})!
	srv.run()
}
```

### 2. End-to-End Testing

Call the handler directly — no server needed:

```v
fn test_handle_request() {
	request := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	mut response := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle_request(request, mut response, -1, unsafe { nil }, mut event_loop) == .done
	assert response.starts_with('HTTP/1.1 200 OK'.bytes())
}
```

Or drive a running server over a real client socket — spawn `srv.run()` on a
thread, then send raw requests with `net.dial_tcp` and read the responses under a
deadline. This exercises the full framing / keep-alive / suspend-resume path and
never hangs on a stalled stream. See
[`tests/backend_behaviors_test.v`](tests/backend_behaviors_test.v)
for the pattern (pipelining, framing across TCP segments, timeouts, graceful
shutdown) and the `*_end_to_end_test.v` files under [`examples/`](examples/) for
per-app end-to-end tests.

### 3. Graceful Shutdown

```v
import server
import os

fn main() {
	mut srv := server.new_server(server.ServerConfig{ ... })!

	os.signal_opt(.term, fn [srv] (_ os.Signal) {
		srv.shutdown(2000) // drain up to 2 s, then exit
		exit(0)
	}) or {}

	srv.run()
}
```

### 4. Startup hook (`after_server_start`)

`run()` blocks in the accept loop, so there is no "server is up" return to hook
onto. `after_server_start` fills that gap: a callback that fires **once**, on the
main thread, the moment every listener is bound and the workers are spawned —
right before `run()` blocks. Works on every backend (epoll / io_uring / kqueue /
IOCP). Use it to log readiness, register in service discovery, write a
PID/health/ready file, notify a supervisor, or — in tests — signal a channel so a
client proceeds the instant the server is ready instead of polling for it:

```v
ready := chan bool{cap: 1}
mut srv := server.new_server(server.ServerConfig{
	handler:            handle_request
	after_server_start: fn [ready] () {
		ready <- true
	}
})!
spawn fn [mut srv] () {
	srv.run()
}()
_ := <-ready // deterministic readiness — the server is now accepting
```

### 5. Server-Sent Events (SSE)

**Run the example:**

```sh
v -prod run examples/sse
```

**Subscribe (front-end):**

```html
<script>
  const es = new EventSource("http://localhost:3000/events");
  es.onmessage = e => document.body.innerHTML += `<p>${e.data}</p>`;
</script>
```

**Broadcast a message:**

```sh
curl -X POST http://localhost:3000/broadcast
```

### 6. ETag Support

```sh
curl -v http://localhost:3000/user/1
curl -v -H "If-None-Match: c4ca4238a0b923820dcc509a6f75849b" http://localhost:3000/user/1
```

### 7. Database Example (PostgreSQL)

**Start the database:**

```sh
docker-compose -f examples/database/docker-compose.yml up -d
```

**Run the server:**

```sh
v -prod run examples/database
```

**Example handler (pool captured via closure):**

```v
fn main() {
	mut pool := new_connection_pool(pg.Config{ ... }, 5) or { panic(err) }

	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         fn [mut pool] (request []u8, mut response []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			// Use pool.acquire() / pool.release() for DB access;
			// append the raw HTTP response to `response`.
			return .done
		}
	})!
	srv.run()
}
```

---

## More Examples

| Directory | Description |
|---|---|
| `examples/tiny/` | Minimal "Hello, World!" — the benchmark target |
| `examples/simple/` | Basic CRUD routing |
| `examples/simple2/` | CRUD with helper utilities |
| `examples/simple3/` | CRUD with a response builder |
| `examples/auth/` | Argon2id password hashing (RFC 9106), JWT with `exp` (HMAC-SHA256), API key auth |
| `examples/chunked_streaming/` | Chunked transfer encoding |
| `examples/compression/` | `Accept-Encoding` negotiation over precompressed brotli/zstd/gzip const responses |
| `examples/conformance/` | RFC 9112/9110-conformant handler (rejects malformed requests with the right 4xx/5xx); probed in CI by h1spec + Http11Probe |
| `examples/cookies_sessions/` | Cookie-based sessions |
| `examples/cors/` | CORS preflight and origin allowlist |
| `examples/csrf/` | CSRF token protection |
| `examples/database/` | PostgreSQL connection pool |
| `examples/date_header/` | RFC 7231 `Date` header (shared cache, zero-alloc hot path) |
| `examples/efficient_date/` | Cached `Date` header (per-worker, lazy 1×/s refresh) |
| `examples/etag/` | ETag and conditional requests |
| `examples/graceful_shutdown/` | SIGTERM/SIGINT drain |
| `examples/hexagonal/` | Hexagonal architecture |
| `examples/ip_block/` | IP allowlist / blocklist |
| `examples/json_api/` | JSON API with multipart upload |
| `examples/middleware/` | Middleware chain (auth, RBAC, 404) |
| `examples/observability/` | `/healthz`, `/readyz`, `/metrics` |
| `examples/proxy_aware/` | `X-Forwarded-For` / real-IP extraction |
| `examples/rate_limit/` | Token-bucket rate limiting |
| `examples/redirects/` | 301/303/308 redirects |
| `examples/request_limits/` | 413/431 body and header size limits |
| `examples/security_headers/` | HSTS, CSP, and other security headers |
| `examples/sse/` | Server-Sent Events (sync broadcast) |
| `examples/spa_static_assets/` | CSR/WASM SPA bundle (`application/wasm`, `.br`/`.gz`, immutable caching, SPA fallback) |
| `examples/static_files/` | Static file serving (MIME, Range, ETag, traversal safety) |
| `examples/url_form/` | Query-string and URL-encoded form parsing |
| `examples/veb_like/` | veb-style declarative routing |
| `examples/video_stream/` | HTTP video streaming |
| `examples/async_sse/` | SSE via async handler (suspend/resume on fd) |
| `examples/async_db_pg/` | PostgreSQL queries via async handler |
| `examples/async_timer/` | Async per-request timer |
| `examples/io_uring_demo/` | io_uring backend demonstration (Linux) |

---

## End-to-End Testing

Two layers, no bespoke test mode on the server:

- **In-process** — call the handler directly (`handle_request(req, mut out, ...)`)
  and assert on the bytes it appends. Deterministic, no sockets, no threads; ideal
  for routing and response-shape assertions.
- **Over a real socket** — spawn `srv.run()` on a thread, connect with
  `net.dial_tcp`, and read responses under a per-read deadline (so a broken stream
  fails fast instead of hanging). This drives the real backend end to end —
  epoll / io_uring / kqueue — including pipelining, request framing across TCP
  segments, keep-alive, `Expect: 100-continue`, half-close, read timeouts, and the
  async suspend/resume path. See
  [`tests/backend_behaviors_test.v`](tests/backend_behaviors_test.v)
  and the `*_end_to_end_test.v` files under [`examples/`](examples/).

---

## Conformance Testing

[`examples/conformance/`](examples/conformance/) is a handler written to be
**correct under an HTTP/1.1 conformance probe** rather than to show off a feature:
it calls the stdlib `request_parser.validate_http1()` plus the field-syntax and
framing checks in [`validate.v`](examples/conformance/src/validate.v), so
malformed requests get the RFC-mandated status instead of being served as valid.
Two probes drive it from CI — [h1spec](https://github.com/dropseed/h1spec)
(RFC 9112/9110, every push) and [Http11Probe](https://github.com/MDA2AV/Http11Probe)
(~215 tests incl. request-smuggling, on merge).

The scorecard below is the live `h1spec --strict` result, **rewritten by CI on
every merge to `main`** — 🟢 passed, ⚪ blocked (no response — transient or a
tracked backend edge), 🔴 a real conformance gap. Both the deterministic
`v test examples/conformance/src` layer **and** the live `h1spec` probe gate the
build: a merge is blocked by any handler-decision regression *and* by any 🔴 real
conformance failure over a live socket. (⚪ blocked does not gate — it can be
socket-timing noise on a hosted runner, and the `v test` layer already asserts
those decisions.)

<!-- CONFORMANCE_SCORECARD:START -->
**Live `h1spec --strict` scorecard** — 33/33 of the checks that get an answer pass.

🟢 **33 pass**

> [!TIP]
> **Fully conformant.** Every `h1spec --strict` check passes over a live socket — [#103](https://github.com/enghitalo/vanilla/issues/103) is fixed, so the probe is now a hard gate.

**Request line — RFC 9112 §3**

| | Check | |
|:--:|---|---|
| 🟢 | Simple GET accepted | pass |
| 🟢 | POST with Content-Length body | pass |
| 🟢 | OPTIONS * request-target accepted | pass |
| 🟢 | Absolute-form request-target accepted | pass |
| 🟢 | CONNECT authority-form accepted | pass |
| 🟢 | Invalid HTTP version rejected | pass |
| 🟢 | Malformed request line rejected | pass |

**Headers — RFC 9112 §5**

| | Check | |
|:--:|---|---|
| 🟢 | Missing Host header rejected | pass |
| 🟢 | Duplicate Host rejected | pass |
| 🟢 | Invalid Host value rejected | pass |
| 🟢 | Invalid header name rejected | pass |
| 🟢 | Obsolete line folding rejected | pass |
| 🟢 | Space before colon rejected | pass |
| 🟢 | Null byte in header rejected | pass |

**Body — RFC 9112 §6–7**

| | Check | |
|:--:|---|---|
| 🟢 | Chunked encoding accepted | pass |
| 🟢 | Chunked + HTTP/1.0 rejected | pass |
| 🟢 | Chunked + Content-Length rejected | pass |
| 🟢 | Chunked + Content-Length closes connection | pass |
| 🟢 | Unknown transfer-coding rejected | pass |
| 🟢 | Chunked not-final coding rejected | pass |
| 🟢 | Invalid Content-Length rejected | pass |
| 🟢 | Conflicting Content-Length rejected | pass |
| 🟢 | Invalid chunk-size rejected | pass |
| 🟢 | Missing chunk terminator rejected | pass |
| 🟢 | Expect: 100-continue handling | pass |

**Response semantics — RFC 9110**

| | Check | |
|:--:|---|---|
| 🟢 | HEAD response has no body | pass |
| 🟢 | Error response is self-delimiting | pass |

**Connection — RFC 9112 §9**

| | Check | |
|:--:|---|---|
| 🟢 | Keep-alive default (HTTP/1.1) | pass |
| 🟢 | Connection: close honored | pass |
| 🟢 | HTTP/1.0 closes by default | pass |

**Hardening — implementation-defined limits**

| | Check | |
|:--:|---|---|
| 🟢 | Oversized request line | pass |
| 🟢 | Header flood | pass |
| 🟢 | Oversized header | pass |

_h1spec `--strict`, live socket · commit `53051b0` · [run log](https://github.com/enghitalo/vanilla/actions/runs/29631256523) · regenerated by CI on every merge_
<!-- CONFORMANCE_SCORECARD:END -->

<sub>Live-probe pass/blocked split shifts run to run (the [#103](https://github.com/enghitalo/vanilla/issues/103) half-close teardown is timing-dependent); the `v test` gate and [`examples/conformance/README.md`](examples/conformance/README.md) are the stable references. Two tracked core gaps: [#103](https://github.com/enghitalo/vanilla/issues/103) (half-close) and [#104](https://github.com/enghitalo/vanilla/issues/104) (CL+TE framing).</sub>

---

## Installation

### From the Repository Root

1. Create the target directory:

```bash
mkdir -p ~/.vmodules/enghitalo/vanilla
```

2. Copy this repository into it:

```bash
cp -r ./ ~/.vmodules/enghitalo/vanilla
```

3. Run an example:

```bash
v -prod crun examples/simple
```

### Via `v install`

```bash
v install https://github.com/enghitalo/vanilla
```

---

## Benchmarking

```sh
# Basic throughput
wrk -H 'Connection: keep-alive' --connections 512 --threads 16 --duration 30s http://localhost:3000

# Conditional GET (ETag)
wrk -t16 -c512 -d30s -H "If-None-Match: c4ca4238a0b923820dcc509a6f75849b" http://localhost:3000/user/1
```

See [BENCHMARK_RESULTS_MACOS.md](BENCHMARK_RESULTS_MACOS.md) for full benchmark results on Apple M4.

---

## Documentation

| Resource | Description |
|---|---|
| [Wiki](https://github.com/enghitalo/vanilla/wiki) | Architecture deep-dives, async reactor, memory management under `-gc none`, Postgres pipelining, and lessons learned |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The module tree, the one-direction dependency rule between modules, and where new protocols/platforms land |
| [docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md) | How to write handlers, build responses, allocate, handle concurrency, security, testing, and benchmarking |
| [docs/V_PERF_TOOLBOX.md](docs/V_PERF_TOOLBOX.md) | V performance attributes, array flags, the C escape hatch, profiling allocations, and known gotchas |
| [docs/PERF_GAP_ANALYSIS.md](docs/PERF_GAP_ANALYSIS.md) | Comparison against the fastest HTTP servers (tokio, io_uring C, Zig, Rust) and what was done to close the gaps |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Rules, raw-request testing with netcat/socat, benchmarking commands |
| [CHECKLIST.md](CHECKLIST.md) | Full improvement backlog with phases, priorities, and progress tracking |

---

## Roadmap

### vanilla — future improvements

- [ ] Per-worker `SO_REUSEPORT` accept on epoll — eliminate the single central accept thread (the io_uring backend already does per-worker accept; epoll still round-robins fds from one acceptor). Blocked by clean multi-server shutdown lifecycle.
- [ ] Dynamic route matching (`/user/:id`) with a trie or radix tree
- [ ] Query-string parser (`?key=value&…`) as a zero-copy slice view
- [x] Case-insensitive header lookup (IANA registry compliance) — `get_header_value_slice` / `count_header` fold ASCII case
- [x] `Host` header validation (RFC 9112 §3.2) — `validate_http1()` (exactly-one Host); demonstrated end-to-end in `examples/conformance/`
- [ ] Reject `Content-Length` + `Transfer-Encoding` at the framing layer ([#104](https://github.com/enghitalo/vanilla/issues/104)) — the smuggling case the conformance handler can't fix alone
- [ ] Flush a queued response before tearing down a half-closed connection ([#103](https://github.com/enghitalo/vanilla/issues/103)) — unblocks the live h1spec/Http11Probe gate
- [x] Request timeouts — `Limits.read_timeout_ms` (408) / `write_timeout_ms`, enforced by the per-worker deadline sweep
- [x] Chunked transfer-encoding in the request parser (`frame_chunked_total`)
- [ ] HTTP/2 support (multiplexing, HPACK, server push)
- [ ] WebSocket upgrade (framing, ping/pong, close handshake)
- [x] TLS/HTTPS — epoll backend via `ServerConfig.tls_config` (e.g. `tls.new_self_signed()`); other backends are plaintext
- [ ] HTTPS example (`examples/https/`)
- [x] Body-size cap + max-connections via `Limits` (`max_body_bytes` → 413, `max_request_bytes`, `max_connections`); a per-connection request-count limit is still open
- [ ] Response caching layer (ETag + `Last-Modified` auto-generation)
- [ ] Logging middleware example (`examples/logging/`)
- [ ] API documentation (godoc-style, inline)
- [ ] Architecture documentation (per-module design notes)
- [ ] Security best-practices guide (injection, timing, header limits)
- [ ] Performance tuning guide (`-gc none`, `taskset`, `ulimit`, kernel parameters)
- [ ] Example READMEs for every `examples/` directory
- [ ] Backend stress tests (high-concurrency, FD exhaustion, partial send/recv)
- [ ] Request-parser edge-case tests (malformed requests, split TCP segments)
- [ ] End-to-end integration test suite across all backends

### V language — upstream issues vanilla filed (all resolved)

Limitations in the V compiler and standard library that vanilla's hot paths
exercised. We filed them upstream; as of the pinned V master build
(`badd3466…`) **every one is fixed**. Kept here as a record — and as a guide to
what the current pin buys and which workarounds it retires.

- [x] **`[]T{}` allocated even at `len == 0, cap == 0`** — fixed: `__new_array`
  now guards on `cap > 0`, so a zero-length/zero-cap literal or default-initialized
  array field no longer calls `alloc_array_data`. The append-or-`const` workaround
  is no longer needed. ([vlang/v#27487](https://github.com/vlang/v/issues/27487))
- [x] **GC allocation did not scale across cores** — fixed by **thread-local
  allocation**: Boehm's `GC_malloc` no longer takes a process-global lock, so N
  workers allocate concurrently instead of serializing (16 cores ≈ 16×, not ≈ 1×).
  This removes the GC-lock penalty that was the main reason for `-gc none`; `-gc none`
  is still used where the hot path is already alloc-free.
  ([vlang/v#27488](https://github.com/vlang/v/issues/27488), [#27486](https://github.com/vlang/v/issues/27486))
- [x] **`error()` boxed a `MessageError` on every call** — fixed: builtin now
  exports **`error_sentinel`**, a cached allocation-free `IError`; a hot "not found"
  `!T` path can `return error_sentinel` (like `none` for `?T`) instead of allocating.
  (The `Ok`-side Result construction is a separate cost — addressed in vanilla by the
  plain-`int` framing twin `frame_request_length_lim_idx`.)
  ([vlang/v#27508](https://github.com/vlang/v/issues/27508))
- [x] **No zero-alloc integer formatter in the stdlib** — fixed:
  **`strconv.write_dec(n i64, mut buf []u8)`** and `write_dec_u(n u64, …)` write
  decimal digits into a caller-provided buffer with no allocation — use these instead
  of `.str()` / `${}` on the response hot path.
  ([vlang/v#27509](https://github.com/vlang/v/issues/27509))
- [x] **`array.slice()` marked the source buffer on every call** — closed: V added a
  `.noslices` array flag, but `a[start..]` still marks by default, so vanilla keeps
  its hand-built non-marking `buf_view` window — now used by **both** the epoll and
  io_uring backends. ([vlang/v#27507](https://github.com/vlang/v/issues/27507))
- [x] **`&Struct{}` in an `if`-expression branch miscompiled in some build modes** —
  fixed in cgen; the statement-form (`mut x := &T(unsafe{nil}); if … {}`) workaround
  is no longer required. ([vlang/v#27329](https://github.com/vlang/v/issues/27329))
- [x] **stdlib formatter / KDF gaps** — `strings.Builder.write_decimal` gained an
  unsigned `u64` variant + JS-backend parity ([vlang/v#27510](https://github.com/vlang/v/issues/27510));
  bcrypt/scrypt/pbkdf2 are now documented in the crypto README
  ([vlang/v#27511](https://github.com/vlang/v/issues/27511)).
- **`runtime.nr_cpus()` ignores CPU affinity** *(not a V change — handled
  vanilla-side)*: it is `sysconf`, blind to `taskset`/cpuset, so on a pinned or
  CPU-capped host it over-counts. vanilla sizes its pool from `core.worker_count()`
  = `VANILLA_WORKERS` → `nr_cpus()`; **set `VANILLA_WORKERS`** to pin the worker count
  inside a cpuset or CPU-limited container. (An affinity-aware auto-count was tried
  and reverted — it under-sized the DB profiles.)
