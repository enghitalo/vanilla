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
- **Compliant with HTTP standards**: Follows [RFC 9112](https://datatracker.ietf.org/doc/rfc9112/) and the [IANA Field Name Registry](https://www.iana.org/assignments/http-fields/http-fields.xhtml).

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
| `examples/auth/` | Password hashing, JWT (HMAC-SHA256), API key auth |
| `examples/chunked_streaming/` | Chunked transfer encoding |
| `examples/compression/` | gzip response compression |
| `examples/cookies_sessions/` | Cookie-based sessions |
| `examples/cors/` | CORS preflight and origin allowlist |
| `examples/csrf/` | CSRF token protection |
| `examples/database/` | PostgreSQL connection pool |
| `examples/date_header/` | RFC 7231 `Date` header |
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

- [ ] Per-worker `SO_REUSEPORT` accept on epoll (eliminate the single shared accept thread; blocked by clean multi-server shutdown lifecycle)
- [ ] Dynamic route matching (`/user/:id`) with a trie or radix tree
- [ ] Query-string parser (`?key=value&…`) as a zero-copy slice view
- [ ] Case-insensitive header lookup (IANA registry compliance)
- [ ] `Host` header validation (RFC 9112 §7.2)
- [ ] Request timeouts (idle read / total request deadline)
- [ ] Chunked transfer-encoding in the request parser
- [ ] HTTP/2 support (multiplexing, HPACK, server push)
- [ ] WebSocket upgrade (framing, ping/pong, close handshake)
- [ ] TLS/HTTPS — complete V TLS bindings and integrate into the backends
- [ ] HTTPS example (`examples/https/`)
- [ ] Per-connection request-count limit and body-size cap exposed via `ServerConfig`
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

### V language — upstream improvements needed

These are limitations in the V compiler and standard library that affect vanilla directly.
They are tracked as upstream issues.

- [ ] **`[]T{}` allocates even at `len == 0, cap == 0`** — `alloc_array_data(0)` is called unconditionally; under `-gc none` every default-initialized array field is a permanent leak ([vlang/v#27487](https://github.com/vlang/v/issues/27487))
- [ ] **GC allocation does not scale across cores** — the default Boehm GC is effectively single-threaded for allocation; 16 workers perform the same as 1 ([vlang/v#27488](https://github.com/vlang/v/issues/27488))
- [ ] **`error()` boxes a `MessageError` on every call** — even when the result is discarded with `or {}`; a "not found" fast path that returns `!T` still allocates per call on the hot path. Confirmed at codegen level (`error()` → `builtin___v_error` → `HEAP(MessageError, …)` → `memdup`), unlike `none` which uses a cached const ([vlang/v#27508](https://github.com/vlang/v/issues/27508))
- [ ] **`int.str()` and `${}` string interpolation allocate** — there is no zero-alloc integer-to-`[]u8` formatter in the stdlib (`${x}` → `int_str` malloc, `${x:08d}` → `str_intp` Builder+string); callers must reach for custom helpers (`write_decimal`, `emit_int`) ([vlang/v#27509](https://github.com/vlang/v/issues/27509))
- [ ] **`runtime.nr_cpus()` ignores CPU affinity** — `sched_getaffinity` is not consulted; `taskset -c 0` still reports all cores, making CPU-pinning profiles misleading
- [ ] **`&Struct{}` in an `if`-expression branch miscompiles in some build modes** — the generated C is invalid (the `(T*)` cast is torn in half by `direct_heap_struct_init` hoisting inside a ternary); the workaround is the statement form with a `mut x := &T(unsafe{nil})` pre-declaration. Minimal repro + root cause confirmed on V HEAD ([vlang/v#27329](https://github.com/vlang/v/issues/27329))
- [x] **`strings.Builder.write_decimal` already exists** — a zero-alloc `i64` decimal writer (`vlib/strings/builder.c.v`), so `write_string(n.str())` is unnecessary; use it directly. Remaining gaps: no unsigned `u64` variant and the JS backend lacks it ([vlang/v#27510](https://github.com/vlang/v/issues/27510))
- [x] **`argon2id`, `bcrypt`, `scrypt`, `pbkdf2`, `hkdf` all ship in `vlib/crypto`** (pure-V, no C bindings) — the stdlib *does* have memory-hard KDFs (argon2, scrypt). Only gap: bcrypt/scrypt/pbkdf2 aren't documented in the crypto README ([vlang/v#27511](https://github.com/vlang/v/issues/27511))
