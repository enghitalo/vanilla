# HTTP Server Module

`http_server` is vanilla's core: a multi-threaded, non-blocking HTTP/1.1 server
with pluggable I/O backends. There is ONE handler contract — `core.Handler`,
`fn (req []u8, mut res []u8, mut ctx core.Ctx) core.Step` — pure on the hot
path: it receives the raw request bytes, **appends** the raw response to a
server-owned buffer, and returns a `core.Step`. The server batches everything
appended during one readiness event into a single send and reuses the buffer
across requests.

## Backends

Selected via `ServerConfig.io_multiplexing` (`IOBackend`). One worker thread per
core; per-connection read/response buffers are pooled, so the hot path does no
per-request allocation.

| Platform | Backend | Accept model | Notes |
|---|---|---|---|
| Linux | `.epoll` *(default)* | one central acceptor → round-robins fds to per-worker epolls | `.suspend` watches, `make_state`, `on_worker_start`, TLS |
| Linux | `.io_uring` | per-worker `SO_REUSEPORT` listener + multishot accept (kernel 5.19+) | `.suspend` watches (oneshot `IORING_OP_POLL_ADD`), `make_state` |
| macOS | kqueue | per-worker | `.suspend` watches, `make_state` |
| Windows | IOCP | per-worker | `.done`/`.close` only (`.suspend` closes), `make_state` |

## The handler contract

`ServerConfig.handler` covers every use case with one signature:

- **Plain response** — append the raw response (status line + headers + body)
  to `res` and return **`.done`**. Static routes append a precomputed
  `const ... .bytes()`.
- **Errors** — append the canned error response (e.g.
  `response.tiny_bad_request_response`) and return **`.close`**: whatever is in
  `res` is flushed, then the connection is dropped.
- **Waiting on an fd** — PARK the request on any fd via `ctx.watch(ext_fd,
  interest, continuation, udata)` and return **`.suspend`**; the worker resumes
  the continuation (a `core.WakeFn`) when the fd is ready — DB sockets,
  upstreams, timers, write backpressure — all in the worker's own event loop.
  Linux epoll + io_uring and macOS/kqueue; on TLS and Windows/IOCP a `.suspend`
  closes the connection (no watch reactor there yet).
- **Per-worker state** — set `make_state`: it runs once per worker thread, and
  every handler call on that worker gets the value via **`ctx.state`** (e.g. a
  per-thread DB connection — no shared pool, no mutex). The client's fd is
  `ctx.client_fd`.

`on_worker_start` arms clientless background watches (e.g. a periodic timerfd that
refreshes per-worker state with no extra thread). Linux/epoll, plaintext only.

## Minimal server

```v
import vanilla.http_server
import vanilla.http_server.core

fn handle(req []u8, mut res []u8, mut ctx core.Ctx) core.Step {
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll // or .io_uring on Linux
		handler:         handle
	})!
	server.run() // blocks
}
```

`new_server(ServerConfig) !Server` validates the config; `server.run()`
spawns the workers and blocks; `server.shutdown(grace_ms int)` shuts the listeners
and drains in-flight requests up to the grace period.

## Request limits (`ServerConfig.limits`)

`Limits` gates abusive requests at the framing/accept layer (0 = unlimited, zero-cost):

| field | effect |
|---|---|
| `max_header_bytes` | **431** once the header block exceeds it |
| `max_body_bytes` | **413** from the declared `Content-Length`, before buffering the body |
| `max_request_bytes` | ceiling on a single buffered request (headers + body) |
| `max_connections` | refuse new connections past this many concurrent (checked at accept) |
| `read_timeout_ms` | **408** + close a connection that can't finish its request in time |
| `write_timeout_ms` | close a connection whose parked response can't drain in time |

## TLS

Set `ServerConfig.tls_config` (e.g. `tls.new_self_signed()`) and `certificates` for
HTTPS on the **epoll** backend; the other backends are plaintext.

## Internals (where to look)

- `core/core.v` — the handler contract: `Handler`, `Step`, `Ctx`, `WakeFn`.
- `http_server.c.v` — `new_server`, `ServerConfig`, `Server`, `shutdown`.
- `backend_epoll/` — epoll worker (`worker_linux.c.v`), connection state + buffer
  pool (`conn_state_linux.c.v`), request serving + watch reactor
  (`async_linux.c.v`), TLS (`tls_conn_linux.c.v`).
- `http_server_io_uring_linux.c.v` + `io_uring/` — the io_uring backend.
- `http1_1/request_parser/` — request framing (`frame_request_length_lim`/`_idx`
  with the non-marking `buf_view` window; chunked via `frame_chunked_total`).
- `kqueue/`, `iocp/` — macOS / Windows backends.

## Performance

Worker count = `VANILLA_WORKERS` env → `runtime.nr_cpus()` (set `VANILLA_WORKERS`
inside a cpuset/CPU-capped container). The hot path is allocation-free (pooled
per-connection buffers, zero-copy `buf_view` request windows, one batched send per
readiness event). epoll ships `-prod -gc none`; io_uring ships `-prod` (default
GC). See [../docs/V_PERF_TOOLBOX.md](../docs/V_PERF_TOOLBOX.md) and
[../docs/BEST_PRACTICES.md](../docs/BEST_PRACTICES.md).
