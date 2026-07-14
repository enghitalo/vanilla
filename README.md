<img src="./logo.png" alt="vanilla Logo" width="100">

# vanilla

A minimalist, high-performance HTTP server written in [V](https://vlang.io).

## Features

- **Fast**: Multi-threaded, non-blocking I/O, lock-free, copy-free, I/O multiplexing, `SO_REUSEPORT` (native load balancing on Linux)
- **Modular**: Easy to extend with custom controllers and handlers.
- **Memory Safety**: No race conditions.
- **No Magic**: Transparent and straightforward.
- **E2E Testing**: End-to-end testing without running a persistent server — pass raw requests directly to `handle_request()` or use `server.test(...)`.
- **SSE Friendly**: Built-in Server-Sent Events support (sync and async).
- **ETag Friendly**: Conditional GETs with `ETag` and `If-None-Match` headers.
- **Database Friendly**: Example with PostgreSQL connection pool.
- **Graceful Shutdown**: Drain in-flight requests on `SIGTERM`/`SIGINT` via `server.shutdown(grace_ms)`.
- **Multiple Backends**: epoll, io_uring (Linux), kqueue (macOS), IOCP (Windows).
- **Async Handler**: Suspend/resume requests on any fd (DB sockets, timers, upstream proxies) — all in the worker's event loop, zero extra threads.
- **Stateful Handler**: Lock-free per-worker state (e.g. a per-thread DB connection — no shared pool, no mutex).
- **Compliant with HTTP standards**: Follows [RFC 9112](https://datatracker.ietf.org/doc/rfc9112/) and the [IANA Field Name Registry](https://www.iana.org/assignments/http-fields/http-fields.xhtml). A dedicated [`examples/conformance/`](examples/conformance/) handler is probed in CI by [h1spec](https://github.com/dropseed/h1spec) and [Http11Probe](https://github.com/MDA2AV/Http11Probe) — see [Conformance Testing](#conformance-testing).

---

## Usage Examples

### 1. Simple HTTP Server

```v
import http_server

fn handle_request(req_buffer []u8, client_conn_fd int, mut out []u8) ! {
	// Parse the request and APPEND the complete raw HTTP response
	// (status line + headers + body) to `out`. The server owns `out`,
	// reuses it across requests and batches pipelined responses into a
	// single send — never free or keep it.
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'.bytes()
}

fn main() {
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		request_handler: handle_request
		io_multiplexing: backend
	})!
	server.run()
}
```

### 2. End-to-End Testing

Call the handler directly — no server needed:

```v
fn test_handle_request() {
	request := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	mut out := []u8{}
	handle_request(request, -1, mut out)!
	assert out.starts_with('HTTP/1.1 200 OK'.bytes())
}
```

Or use the server's built-in test mode:

```v
mut server := http_server.new_server(http_server.ServerConfig{ ... })!
responses := server.test([request1, request2]) or { panic(err) }
```

### 3. Graceful Shutdown

```v
import http_server
import os

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{ ... })!

	os.signal_opt(.term, fn [server] (_ os.Signal) {
		server.shutdown(2000) // drain up to 2 s, then exit
		exit(0)
	}) or {}

	server.run()
}
```

### 4. Server-Sent Events (SSE)

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

### 5. ETag Support

```sh
curl -v http://localhost:3000/user/1
curl -v -H "If-None-Match: c4ca4238a0b923820dcc509a6f75849b" http://localhost:3000/user/1
```

### 6. Database Example (PostgreSQL)

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

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: fn [mut pool] (req_buffer []u8, fd int, mut out []u8) ! {
			// Use pool.acquire() / pool.release() for DB access;
			// append the raw HTTP response to `out`.
		}
	})!
	server.run()
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
| `examples/static_assets/` | CSR/WASM SPA bundle (`application/wasm`, `.br`/`.gz`, immutable caching, SPA fallback) |
| `examples/static_files/` | Static file serving (MIME, Range, ETag, traversal safety) |
| `examples/url_form/` | Query-string and URL-encoded form parsing |
| `examples/veb_like/` | veb-style declarative routing |
| `examples/video_stream/` | HTTP video streaming |
| `examples/async_sse/` | SSE via async handler (suspend/resume on fd) |
| `examples/async_db_pg/` | PostgreSQL queries via async handler |
| `examples/async_timer/` | Async per-request timer |
| `examples/io_uring_demo/` | io_uring backend demonstration (Linux) |

---

## Test Mode

`Server.test` accepts an array of raw HTTP requests, sends them directly to the server socket, and processes each one sequentially. After receiving the response for the last request, the server shuts down automatically. This enables efficient end-to-end testing without running a persistent server process.

---

## Conformance Testing

vanilla ships [`examples/conformance/`](examples/conformance/) — a handler
written to be **correct under an HTTP/1.1 conformance probe** rather than to show
off a feature. It calls the stdlib `request_parser.validate_http1()` plus extra
field-syntax and framing checks, so malformed requests get the RFC-mandated
status (`400` / `405` / `501` / `505`) instead of being served as if valid.

Two probes run against it, both driven from CI:

| Tool | What it checks | In CI |
|---|---|---|
| [h1spec](https://github.com/dropseed/h1spec) | RFC 9112/9110 request-line, header, body, connection, and hardening checks (Python, plain TCP) | [`conformance_h1spec.yml`](.github/workflows/conformance_h1spec.yml) — every push/PR |
| [Http11Probe](https://github.com/MDA2AV/Http11Probe) | ~215 tests incl. request-smuggling, normalization, cookies (.NET 10) | [`conformance_http11probe.yml`](.github/workflows/conformance_http11probe.yml) — push to `main` + manual, non-blocking |

Latest h1spec result on `main` (auto-updated by CI on merge):

<!-- CONFORMANCE_H1SPEC:START -->
_Not yet recorded — runs on the next push to `main`._
<!-- CONFORMANCE_H1SPEC:END -->

Run the server and probe it yourself:

```sh
v -prod run examples/conformance/src
# then, in another shell:
uvx --from git+https://github.com/dropseed/h1spec h1spec --strict localhost:3000
```

**How CI gates it.** The authoritative check is `v test examples/conformance/src`
— the handler's conformance decisions asserted directly (no socket), so it is
deterministic and blocks merges on any regression. The live-socket probes are
**report-only**: they post a scorecard to the run summary and PR, but do not fail
the build. This is deliberate — both probes half-close the client write side
after each request, and vanilla's backend currently drops the response on that
half-close ([#103](https://github.com/enghitalo/vanilla/issues/103)), which would
otherwise make a fully-conformant handler look red. See the example's
[README](examples/conformance/README.md) for the full check list and the two
tracked core-vanilla limitations
([#103](https://github.com/enghitalo/vanilla/issues/103),
[#104](https://github.com/enghitalo/vanilla/issues/104)).

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
