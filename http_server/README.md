# HTTP Server Module

`http_server` is vanilla's core: a multi-threaded, non-blocking HTTP/1.1 server
with pluggable I/O backends. Handlers are pure — `fn (req []u8, fd int, mut out
[]u8) !` — they receive the raw request bytes and **append** the raw response to a
server-owned buffer; the server batches everything appended during one readiness
event into a single send and reuses the buffer across requests.

## Backends

Selected via `ServerConfig.io_multiplexing` (`IOBackend`). One worker thread per
core; per-connection read/response buffers are pooled, so the hot path does no
per-request allocation.

| Platform | Backend | Accept model | Handlers supported |
|---|---|---|---|
| Linux | `.epoll` *(default)* | one central acceptor → round-robins fds to per-worker epolls | `request_handler`, `stateful_handler`, `async_handler`, TLS |
| Linux | `.io_uring` | per-worker `SO_REUSEPORT` listener + multishot accept (kernel 5.19+) | `request_handler` (stateless) |
| macOS | kqueue | per-worker | `request_handler`, `async_handler` |
| Windows | IOCP | per-worker | `request_handler` |

## Handler paths

Provide **exactly one** of:

- **`request_handler`** — `fn (req []u8, fd int, mut out []u8) !`, stateless. All backends.
- **`stateful_handler` + `make_state`** — lock-free per-worker state (e.g. a DB
  connection): `make_state` runs once per worker, then every request on that worker
  is dispatched with it. Linux/epoll only.
- **`async_handler` (+ optional `make_state`)** — may PARK a request on any fd via
  `ac.watch(...)` and resume by a continuation in the worker loop (DB sockets,
  upstreams, timers, `EPOLLOUT` backpressure). Linux/epoll + macOS/kqueue.

`on_worker_start` arms clientless background watches (e.g. a periodic timerfd that
refreshes per-worker state with no extra thread). Linux/epoll, plaintext only.

## Minimal server

```v
import vanilla.http_server

fn handle(req []u8, fd int, mut out []u8) ! {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll // or .io_uring on Linux
		request_handler: handle
	})!
	server.run() // blocks
}
```

`new_server(ServerConfig) !Server` validates the config (e.g. rejects more than one
handler path, or a backend that doesn't support the chosen handler); `server.run()`
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

- `http_server.c.v` — `new_server`, `ServerConfig`, `Server`, `shutdown`.
- `backend_epoll/` — epoll worker (`worker_linux.c.v`), connection state + buffer
  pool (`conn_state_linux.c.v`), async reactor (`async_linux.c.v`), TLS
  (`tls_conn_linux.c.v`).
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
