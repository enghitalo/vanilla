<img src="./logo.png" alt="vanilla Logo" width="100">

# vanilla

A minimalist, high-performance HTTP server written in [V](https://vlang.io).

## Features

- **Fast**: Multi-threaded, non-blocking I/O, lock-free, copy-free, I/O multiplexing, `SO_REUSEPORT` (native load balancing on Linux)
- **Modular**: Easy to extend with custom controllers and handlers.
- **Routing without allocation**: route by `match` over the path's segments with [`http1_1.router`](http1_1/router/router.v), which reads the method and a zero-copy path cursor straight from the request line (the fastest, [`examples/router/`](examples/router/)), or declare `@['GET /users/:id']` methods and let [`http1_1.veb_like`](http1_1/veb_like/router.v) compile them into a trie at startup ([`examples/veb_like/`](examples/veb_like/)). Either way routing allocates nothing — a hit, a 404 or a 405 — and handlers keep the full contract (`.suspend` included).
- **Memory Safety**: No race conditions.
- **No Magic**: Transparent and straightforward.
- **E2E Testing**: Test handlers in-process by passing raw requests directly to `handle_request()`, or drive a running server — TCP or unix socket — with the `vtest` scripted client (raw fds via `transport.dial_tcp`/`dial_unix`; see [`tests/backend_behaviors_test.v`](tests/backend_behaviors_test.v)).
- **SSE Friendly**: Built-in Server-Sent Events support (sync and async).
- **ETag Friendly**: Conditional GETs with `ETag` and `If-None-Match` headers.
- **Database Friendly**: Example with PostgreSQL connection pool.
- **Graceful Shutdown**: Drain in-flight requests on `SIGTERM`/`SIGINT` via `srv.shutdown(grace_ms)`.
- **Multiple Backends**: epoll, io_uring (Linux), kqueue (macOS), IOCP (Windows).
- **Local IPC**: listen on a unix domain socket (`ServerConfig.unix_socket_path`) instead of TCP — ≈2.5–3× lower RTT than TCP loopback ([docs/LOCAL_IPC.md](docs/LOCAL_IPC.md)), filesystem permissions as access control, kernel-verified peer identity (`socket.peer_cred`: pid/uid/gid via `SO_PEERCRED`/`getpeereid`); dial other local services with `transport.dial_unix`/`dial_tcp`.
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
	core.append_str(mut response, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
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

Or drive a running server over a real client socket — the `vtest` module owns
the whole lifecycle (ephemeral bind or unix socket, readiness, shutdown) and
dials raw non-blocking fds through `transport`, with scripts as data. This
exercises the full framing / keep-alive / suspend-resume path and
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

	// A signal handler runs in async-signal context, on whichever thread the
	// kernel interrupts (possibly a worker), so it only writes one byte to a
	// pipe: write(2) is async-signal-safe.
	wake := os.pipe()!
	on_signal := fn [wake] (_ os.Signal) {
		saved := C.errno // leave the interrupted code's errno untouched
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.term, on_signal)!
	os.signal_opt(.int, on_signal)!

	// An ordinary thread waits for that byte, then drains and exits.
	spawn fn [srv, wake] () {
		os.fd_read(wake.read_fd, 1) // blocks until SIGTERM / SIGINT
		srv.shutdown(2000) // stop accepting, drain up to 2 s
		exit(0)
	}()

	srv.run()
}
```

Don't call `srv.shutdown()` or `exit()` inside the signal handler itself.
Neither one is async-signal-safe. `exit()` runs `atexit` handlers and flushes
stdio, so it can deadlock on a lock that the interrupted thread holds. And if the
signal lands on a worker, that worker spins inside `shutdown()` and can't finish
its own in-flight request, so the drain waits out the whole grace period and the
request is dropped anyway. [`examples/graceful_shutdown/`](examples/graceful_shutdown/)
is this pattern as a runnable program.

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
v -prod run examples/sse/src
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
v -prod run examples/database/src
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
| `examples/mesh/` | Local mesh: edge on TCP calling a backend on UDS via `http1_1.client` + a pooled per-worker connection + watch/suspend |
| `examples/https_upstream/` | A handler calling a third-party HTTPS API without blocking its worker: the `http1_1.upstream` pooled client (TLS 1.3 verify-full, keep-alive reuse, deadlines, retries, a resolver thread) |
| `examples/middleware/` | Middleware chain (auth, RBAC, 404) |
| `examples/observability/` | `/healthz`, `/readyz`, `/metrics` |
| `examples/proxy_aware/` | `X-Forwarded-For` / real-IP extraction |
| `examples/rate_limit/` | Token-bucket rate limiting |
| `examples/redirects/` | 301/303/308 redirects |
| `examples/request_limits/` | 413/431 body and header size limits, max connections, read/idle/write timeouts |
| `examples/security_headers/` | HSTS, CSP, and other security headers |
| `examples/sse/` | Server-Sent Events (sync broadcast) |
| `examples/spa_static_assets/` | CSR/WASM SPA bundle (`application/wasm`, `.br`/`.gz`, immutable caching, SPA fallback) |
| `examples/static_files/` | Static file serving (MIME, Range, ETag, traversal safety) |
| `examples/url_form/` | Query-string and URL-encoded form parsing |
| `examples/router/` | Routing as code: `match` over path segments with `http1_1.router`'s zero-copy cursor — the fastest option |
| `examples/veb_like/` | Declarative routing with `http1_1.veb_like`: `@['GET /users/:id']` methods compiled into a trie at startup, zero allocations per request |
| `examples/websocket_echo/` | RFC 6455 WebSocket echo over the connection-takeover seam (`core.queue_takeover` — one engine, two protocols on one connection) |
| `examples/http2_cleartext/` | HTTP/2 (cleartext, prior-knowledge, RFC 9113) over the same seam — the `PRI *` preface flips the connection, then the SAME handler serves h1 and http2 requests |
| `examples/video_stream/` | HTTP video streaming |
| `examples/async_sse/` | SSE via async handler (suspend/resume on fd) |
| `examples/async_db_pg/` | PostgreSQL queries via async handler |
| `examples/pg_transactions/` | An atomic PostgreSQL transaction in one round trip (`async_submit_batch`), run again on a serialization failure (40001) as `pg_async.TxRetry` decides |
| `examples/async_timer/` | Async per-request timer |
| `examples/io_uring_demo/` | io_uring backend demonstration (Linux) |

---

## End-to-End Testing

Two layers, no bespoke test mode on the server:

- **In-process** — call the handler directly (`handle_request(req, mut out, ...)`)
  and assert on the bytes it appends. Deterministic, no sockets, no threads; ideal
  for routing and response-shape assertions.
- **Over a real socket** — drive the server with `vtest` (scripts as data,
  lifecycle owned by the harness) or dial raw fds yourself with
  `transport.dial_tcp`/`dial_unix` + `testkit`'s deadline-bounded `fd_*`
  readers (so a broken stream fails fast instead of hanging). Either way this
  drives the real backend end to end —
  epoll / io_uring / kqueue — including pipelining, request framing across TCP
  segments, keep-alive, `Expect: 100-continue`, half-close, read/idle timeouts
  (not on kqueue, which does not enforce them yet), and the async
  suspend/resume path. See
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

_h1spec `--strict`, live socket · commit `5ea4323` · [run log](https://github.com/enghitalo/vanilla/actions/runs/38100563580) · regenerated by CI on every merge_
<!-- CONFORMANCE_SCORECARD:END -->

<sub>The live-probe pass/blocked split can shift from run to run (⚪ blocked can be socket-timing noise on a hosted runner); the `v test` gate and [`examples/conformance/README.md`](examples/conformance/README.md) are the stable references. The former core gaps [#103](https://github.com/enghitalo/vanilla/issues/103) (half-close), [#104](https://github.com/enghitalo/vanilla/issues/104) (CL+TE framing) and [#109](https://github.com/enghitalo/vanilla/issues/109) (chunk-data CRLF) are fixed, and so are the framing gaps [#184](https://github.com/enghitalo/vanilla/issues/184) (ambiguous framing), [#185](https://github.com/enghitalo/vanilla/issues/185) (chunked trailers and chunk-size lines) and [#186](https://github.com/enghitalo/vanilla/issues/186) (field-value whitespace).</sub>

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
v -prod crun examples/simple/src
```

### Via `v install`

```bash
v install https://github.com/enghitalo/vanilla
```

### System libraries

None on Linux: the io_uring backend drives the kernel ring through the raw
`io_uring_setup` / `io_uring_enter` / `io_uring_register` syscalls, not
liburing, so neither building nor running a vanilla binary needs liburing
(`ldd` lists only libc and libm). Minimal images (`-slim`, distroless) work
as they are.

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
| [docs/LOCAL_IPC.md](docs/LOCAL_IPC.md) | HTTP over unix domain sockets: what loopback TCP costs, measured TCP-vs-UDS numbers, how `unix_socket_path` was built, peer credentials, fd passing, pitfalls |
| [docs/PERF_GAP_ANALYSIS.md](docs/PERF_GAP_ANALYSIS.md) | Comparison against the fastest HTTP servers (tokio, io_uring C, Zig, Rust) and what was done to close the gaps |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Rules, raw-request testing with netcat/socat, benchmarking commands |
| [CHECKLIST.md](CHECKLIST.md) | Full improvement backlog with phases, priorities, and progress tracking |

---

## Roadmap

### vanilla — future improvements

- [ ] Parallelize the epoll central acceptor ([#82](https://github.com/enghitalo/vanilla/issues/82)) — one thread still accepts every connection and round-robins the fds to the workers, so under connection churn the workers sit idle behind it. The plan keeps the central-acceptor model, which has tested faster than per-worker `SO_REUSEPORT` accept on keep-alive: a small pool of acceptor threads sharing the one listener, with `TCP_NODELAY` moved off the accept path. Related: `shutdown()` closes the listener under the live accept thread ([#163](https://github.com/enghitalo/vanilla/issues/163))
- [x] Dynamic route matching (`/user/:id`) — `http1_1.router` (segment cursor + `match`) and `http1_1.veb_like` (attribute routes compiled into a segment trie); zero allocations per request, 404/405/HEAD handled
- [x] Query-string parser (`?key=value&…`) as a zero-copy slice view — `HttpRequest.get_query_slice(key)` returns a `Slice` into the request buffer. Values are raw, not percent-decoded; `examples/url_form/` decodes them once at the edge
- [x] Case-insensitive header lookup (IANA registry compliance) — `get_header_value_slice` / `count_header` fold ASCII case
- [x] `Host` header validation (RFC 9112 §3.2) — `validate_http1()` (exactly-one Host); demonstrated end-to-end in `examples/conformance/`
- [x] Reject ambiguous framing at the framing layer — `Content-Length` + `Transfer-Encoding` ([#104](https://github.com/enghitalo/vanilla/issues/104)), duplicate `Content-Length` and non-chunked `Transfer-Encoding` ([#184](https://github.com/enghitalo/vanilla/issues/184)): the smuggling cases the conformance handler can't fix alone
- [x] Flush a queued response before tearing down a half-closed connection ([#103](https://github.com/enghitalo/vanilla/issues/103)) — unblocks the live h1spec/Http11Probe gate
- [x] Request timeouts — `Limits.read_timeout_ms` / `write_timeout_ms` / `idle_timeout_ms`, enforced by the per-worker deadline sweep. The first request's read deadline starts at accept (it bounds a silent connect and the TLS handshake); 408 only for a partial request, silent close otherwise; idle keep-alive connections are reaped after `idle_timeout_ms` (0 = inherit `read_timeout_ms`, -1 = never). Not enforced on kqueue yet ([#154](https://github.com/enghitalo/vanilla/issues/154))
- [x] Park deadlines ([#200](https://github.com/enghitalo/vanilla/issues/200)) — `Limits.park_timeout_ms` and per-watch `watch_fd_deadline` / `watch_fd_persistent_deadline`: a parked request whose fd never becomes ready gets its continuation once with `event_loop.timed_out()` (answer 504), from a per-worker heap that needs no other timeout; a pooled fd's late reply is drained in order by a tombstone. `pg_async` keeps BackendKeyData and `PgConn.cancel` sends a non-blocking CancelRequest (over TLS when the session is). Epoll plain worker only
- [x] Server push ([#230](https://github.com/enghitalo/vanilla/issues/230)) — a taken-over connection subscribes (`event_loop.subscribe`) and keeps reading its client while its wake fn gets posts from any thread (`core.ConnHandle`, generation-checked, through a per-worker lock-free mailbox: `ServerConfig.push_mailbox_slots`), `wake_after` timers, `.shutdown` and exactly one `.closed`; zero allocations per post; `examples/websocket_chat`. Epoll plain worker only
- [x] Chunked transfer-encoding in the request parser (`frame_chunked_total`), trailer sections included ([#185](https://github.com/enghitalo/vanilla/issues/185))
- [x] HTTP/2 — cleartext prior-knowledge via the takeover seam: HPACK (RFC 7541, Appendix C-verified), multiplexed streams, send-side flow control (`http2/` + `examples/http2_cleartext/`)
- [ ] HTTP/2 follow-ups — TLS + ALPN `h2` ([#142](https://github.com/enghitalo/vanilla/issues/142)), the HTTP/1.1 `Upgrade: h2c` handshake, and a native response path that drops the HTTP/1 round-trip ([#146](https://github.com/enghitalo/vanilla/issues/146))
- [x] WebSocket upgrade (framing, ping/pong, close handshake) — `websocket/` codec + `examples/websocket_echo/` over the takeover seam
- [ ] Server push follow-ups ([#230](https://github.com/enghitalo/vanilla/issues/230)) — a per-connection outbound queue for backpressure ([#23](https://github.com/enghitalo/vanilla/issues/23)), `examples/sse` on `core.ConnHandle`, and backends beyond the epoll plain worker
- [x] TLS/HTTPS — epoll backend via `ServerConfig.tls_config`; `tls.new_self_signed()` issues a localhost/loopback certificate with proper SANs, `sans: ['IP:203.0.113.5']` targets a real host and `persist_dir:` keeps the identity across restarts (or `tls.new_from_pem` for CA-issued certs); the handshake is bounded from accept by `read_timeout_ms` (or, without one, `idle_timeout_ms`). After the handshake the record crypto moves into the kernel (kTLS) when the host supports it, and `static_assets` then `sendfile(2)`s file bodies with no userspace copy. Other backends are plaintext
- [ ] Reject `tls_config` on backends that can't serve TLS ([#156](https://github.com/enghitalo/vanilla/issues/156)) — `new_server` already refuses it on poll and IOCP, but io_uring and kqueue accept it and serve plaintext
- [x] PostgreSQL over TLS — `pg_async.ConnConfig.ssl_mode` (`.require` / `.verify_ca` / `.verify_full`, with `ssl_root_cert` or the system CA bundle), TLS 1.3 through the same Mbed TLS 4 shim as the server (`-d vanilla_tls`); pooled connections re-dial over TLS without blocking, zero allocations per query
- [x] PostgreSQL token authentication ([#197](https://github.com/enghitalo/vanilla/issues/197): Aurora DSQL, RDS IAM) — a cleartext password answered only over TLS and only when `ConnConfig.allowed_auth` lists it, `password_fn` for a fresh credential on every connection attempt, `max_lifetime_ms` + `lifetime_jitter_ms` (connections recycled by the maintenance timer, never on the request path), StartupMessage `params` (`application_name`). A SigV4 token generator is not included yet
- [ ] HTTPS server example (`examples/https/`) — the server side is shown only in `server/README.md` and the `tests/tls_*` suites; `examples/https_upstream/` covers the client side
- [x] Outbound HTTP/1.1 + HTTPS client for handlers ([#229](https://github.com/enghitalo/vanilla/issues/229)) — `http1_1.upstream`: a per-worker pool parked on the reactor (`watch_fd_persistent`), TLS 1.3 verify-full + SNI, resumable framing (`client.Framer`: HEAD, 1xx, close-delimited bodies, keep-alive), pre-use liveness probe + one safe retry, connect/response deadlines from a maintenance timer, DNS off the workers (`Resolver`), IPv4/IPv6 dialing (`transport.dial_addr`), zero allocations per exchange; `examples/https_upstream/`
- [x] Body-size cap + max-connections via `Limits` (`max_body_bytes` → 413, `max_request_bytes`, `max_connections`); pair `max_connections` with a read or idle timeout — reaping silent and idle connections is what frees their slots. A per-connection request-count limit is still open
- [ ] kqueue (macOS) parity ([#154](https://github.com/enghitalo/vanilla/issues/154)) — `max_connections`, read/write/idle timeouts, a per-connection read buffer (split and pipelined requests), and no busy-spin when `accept` hits `EMFILE`
- [ ] IOCP (Windows) parity — the watch reactor for `.suspend` ([#117](https://github.com/enghitalo/vanilla/issues/117)), TLS ([#115](https://github.com/enghitalo/vanilla/issues/115)), `TransmitFile` for static assets ([#114](https://github.com/enghitalo/vanilla/issues/114))
- [ ] `Last-Modified` / `If-Modified-Since` — `static_assets` already precomputes a strong ETag, a 304 and `Cache-Control` per file; no module sends `Last-Modified` yet, and dynamic responses build their own ETag (`examples/etag/`)
- [x] Logging middleware example — `examples/middleware/` (`access_log.v`: a buffered, zero-alloc access log written to a file) and `examples/observability/` (one structured line per request, plus `/healthz`, `/readyz` and `/metrics`)
- [ ] API documentation (godoc-style, inline) — most public functions carry a doc comment; the gaps are mostly in `tls/` and `pg_async/`
- [x] Architecture documentation — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (the module tree, each module's role, the grep-enforced dependency rule) and [server/README.md](server/README.md) (the engine, its backends, limits and TLS)
- [ ] Security best-practices guide (injection, timing, header limits) — [docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md) §8 lists the defaults and points at the `auth`, `cors`, `csrf`, `rate_limit`, `request_limits` and `security_headers` examples; a dedicated guide is still open
- [ ] Performance tuning guide — [docs/V_PERF_TOOLBOX.md](docs/V_PERF_TOOLBOX.md) covers `-gc none` vs the default GC; the operational side (`taskset` + `VANILLA_WORKERS`, `ulimit -n`, `net.core.somaxconn` and other kernel parameters) is still missing
- [ ] Example READMEs for every `examples/` directory — 12 of 50 have one
- [ ] Tests for every example ([#129](https://github.com/enghitalo/vanilla/issues/129)) — 4 example directories still have none (`async_watch_hangup`, `efficient_date`, `io_uring_demo`, `tiny`)
- [ ] Backend stress tests — connect storms, pipelined storms, slow readers with parked writes, large-upload drains, and fd exhaustion (`EMFILE`) at listen and at accept (`tests/accept_starved_test.v`, [#256](https://github.com/enghitalo/vanilla/issues/256)) are covered; a sustained high-concurrency soak is not
- [x] Request-parser edge-case tests — split-point fuzzing over every prefix of a request, malformed and ambiguous framing (`tests/framing_ambiguity_test.v`), chunked trailers (`tests/chunked_trailer_test.v`), requests split across TCP segments (`tests/backend_behaviors_test.v`), plus the h1spec/Http11Probe CI gates
- [ ] End-to-end integration test suite across all backends — `tests/backend_behaviors_test.v` runs the same behaviour checks on epoll, io_uring, poll and IOCP; kqueue joins once it enforces the limits ([#154](https://github.com/enghitalo/vanilla/issues/154))

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
