# Server Module (the engine)

`server` is vanilla's engine: a multi-threaded, non-blocking server with
pluggable I/O backends (HTTP/1.1 today; protocols are sibling top-level
modules over this one engine). There is ONE handler contract — `core.Handler` —
and every input is an explicit, self-describing parameter (nothing hides in a
context object):

```v
fn (request []u8, mut response []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step
```

The handler is pure on the hot path: it receives the raw request bytes,
**appends** the raw response to the server-owned `response` buffer, and
returns a `core.Step`. The server batches everything appended during one
readiness event into a single send and reuses the buffer across requests.

## Backends

Selected via `ServerConfig.io_multiplexing` (`IOBackend`). One worker thread per
core; per-connection read/response buffers are pooled, so the hot path does no
per-request allocation.

| Platform | Backend | Accept model | Notes |
|---|---|---|---|
| Linux | `.epoll` *(default)* | one central acceptor → round-robins fds to per-worker epolls | `.suspend` watches, `make_state`, `on_worker_start`, TLS |
| Linux | `.io_uring` | per-worker `SO_REUSEPORT` listener + multishot accept (kernel 5.19+) | `.suspend` watches (oneshot `IORING_OP_POLL_ADD`), `make_state` |
| macOS | kqueue | per-worker | `.suspend` watches, `make_state` |
| Windows | IOCP | one central acceptor → round-robins fds to per-worker IOCP ports | `.done`/`.close` only (`.suspend` closes), `make_state`, limits + timeouts |
| any POSIX | `.poll` *(`-d vanilla_poll`)* | every worker polls the ONE shared listener (no SO_REUSEPORT assumed) | the QNX/VxWorks portability floor (`backend_poll/`): same request semantics, O(nfds), `.done`/`.close` only, never a default |

## The handler contract

`ServerConfig.handler` covers every use case with one signature:

- **Plain response** — append the raw response (status line + headers + body)
  to `response` and return **`.done`**. Static routes append a precomputed
  `const ... .bytes()`.
- **Errors** — append the canned error response (e.g.
  `response.tiny_bad_request_response`) and return **`.close`**: whatever is in
  `response` is flushed, then the connection is dropped.
- **Waiting on an fd** — PARK the request on any fd via
  `event_loop.watch_fd(fd, interest, continuation, watch_payload)` and return
  **`.suspend`**; the worker resumes the continuation (a `core.WakeFn`, which
  receives `ready_fd`/`ready_fd_error`/`watch_payload` as explicit parameters)
  when the fd is ready — DB sockets, upstreams, timers, write backpressure —
  all in the worker's own event loop. Linux epoll + io_uring and macOS/kqueue;
  on TLS and Windows/IOCP a `.suspend` closes the connection (no watch reactor
  there yet).
- **Per-worker state** — set `make_state`: it runs once per worker thread, and
  every handler call on that worker receives the value as the
  **`worker_state`** parameter (e.g. a per-thread DB connection — no shared
  pool, no mutex).

`on_worker_start` arms clientless background watches (e.g. a periodic timerfd that
refreshes per-worker state with no extra thread). Linux/epoll, plaintext only.

## Minimal server

```v
import vanilla.server
import vanilla.core

fn handle(request []u8, mut response []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	response << 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!'.bytes()
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll // or .io_uring on Linux
		handler:         handle
	})!
	srv.run() // blocks
}
```

`new_server(ServerConfig) !Server` validates the config; `srv.run()`
spawns the workers and blocks; `srv.shutdown(grace_ms int)` shuts the listeners
and drains in-flight requests up to the grace period.

## Request limits (`ServerConfig.limits`)

`Limits` gates abusive requests at the framing/accept layer. Every field
defaults to 0 = unlimited and costs nothing unless set — with one exception:
`idle_timeout_ms = 0` **inherits** `read_timeout_ms`, so setting a read timeout
alone also reaps idle keep-alive connections. With both at 0 nothing is armed.

| field | effect |
|---|---|
| `max_header_bytes` | **431** once the header block exceeds it |
| `max_body_bytes` | **413** from the declared `Content-Length`, before buffering the body |
| `max_request_bytes` | ceiling on a single buffered request (headers + body) |
| `max_connections` | refuse new connections past this many concurrent (checked at accept). Pair it with `read_timeout_ms` and `write_timeout_ms`: without a deadline, connections that never send (or peers that vanish without a FIN) hold their slots forever and the server stops accepting. `idle_timeout_ms` alone is not enough — it only bounds the wait for a request's first byte, so a peer that sends one byte and stalls is bounded by `read_timeout_ms` alone, and a peer that stops reading a response by `write_timeout_ms` alone |
| `read_timeout_ms` | a request (head + body) must arrive complete within this long, else close. The **first** request's clock starts at **accept**, so it also bounds a connection that never sends a byte and the TLS handshake; a later request's clock starts at its first byte. Not refreshed on progress (the slowloris bound) — size it for your largest upload. **408** only if part of the request arrived and no earlier response is still being sent (plaintext epoll / poll / iocp); otherwise — and always on TLS / io_uring — the connection is closed silently |
| `write_timeout_ms` | close a connection whose parked response can't drain in time |
| `idle_timeout_ms` | keep-alive: once a response is fully sent, how long to wait for the first byte of the next request before closing **silently** (no 408). `0` ⇒ `read_timeout_ms`; `-1` (any negative) ⇒ never. With no read timeout it also bounds a new connection's wait for its first byte (over TLS, its first decrypted byte, so the handshake too). Never applies to a request parked on a watch, a parked write, or a taken-over connection (WebSocket, h2c) |

Deadlines are enforced by each worker's sweep, which runs every
`Limits.sweep_interval_ms()` (a quarter of the shortest timeout, clamped to
25–250 ms): a connection is closed at most one interval after its deadline.

Use `idle_timeout_ms: -1` when a handler hands its fd to another thread to
stream (the fd-handoff pattern in `examples/sse` and `examples/video_stream`):
the core has seen the response finish, so the connection looks idle to it.
Behind a load balancer that pools upstream connections, keep `idle_timeout_ms`
longer than the balancer's own idle timeout, or it will reuse a connection the
server is closing and answer 502.

**kqueue (macOS) enforces none of `max_connections`, `read_timeout_ms`,
`write_timeout_ms` or `idle_timeout_ms` yet** — only the header/body size
limits. Do not rely on it to reap connections.

## TLS

Set `ServerConfig.tls_config` (e.g. `tls.new_self_signed()`) and `certificates` for
HTTPS on the **epoll** backend; the other backends are plaintext. The handshake
is bounded from accept, before any TLS record arrives: by `read_timeout_ms`,
or, when that is 0, by `idle_timeout_ms` (a new connection's idle deadline runs
until its first decrypted byte, so it covers the whole handshake). A client
that connects and never finishes its handshake is closed (silently) once the
deadline expires. Still set a read timeout on any public HTTPS server:
`idle_timeout_ms` alone does not bound a request that has started arriving
(slowloris).

HTTP/1.1 pipelining works over TLS as over plaintext: every complete request
a read burst carries is answered, in order, and the responses go out
together. While a response waits for the socket to drain (WANT_WRITE),
nothing more is read or answered on that connection; the requests pipelined
behind it are answered once it is out.

Every worker can serve TLS. How much of the crypto runs in parallel depends on
how Mbed TLS was built. Its PSA Crypto state (the key store, the RNG) is
shared by the whole process:
- **Built with `MBEDTLS_THREADING_C` and `MBEDTLS_THREADING_PTHREAD`:** Mbed
  TLS locks that state itself, and the workers run their crypto in parallel.
- **Built without them** (the upstream default config, and distro packages
  such as Arch's): every call into Mbed TLS takes one process-wide lock, so
  the workers take turns in the crypto library. That covers handshakes, and
  record crypto unless kTLS carries it. Parsing, handlers and syscalls still
  run in parallel. The server says so at startup when it runs more than one
  TLS worker, and `tls.parallel_crypto()` reports which build is linked.

## Internals (where to look)

- `../core/core.v` — the handler contract: `Handler`, `Step`, `WakeFn`, `EventLoop`.
- `server.c.v` — `new_server`, `ServerConfig`, `Server`, `shutdown`.
- `backend_epoll/` — epoll worker (`worker_linux.c.v`), connection state + buffer
  pool (`conn_state_linux.c.v`), request serving + watch reactor
  (`async_linux.c.v`), TLS (`tls_conn_linux.c.v`).
- `server_io_uring_linux.c.v` + `../io_uring/` — the io_uring backend.
- `../http1_1/request_parser/` — request framing (`frame_request_length_lim`/`_idx`
  with the non-marking `buf_view` window; chunked via `frame_chunked_total`).
- `../kqueue/`, `../iocp/` — macOS / Windows backend syscall wrappers.

## Performance

Worker count = `VANILLA_WORKERS` env → `runtime.nr_cpus()` (set `VANILLA_WORKERS`
inside a cpuset/CPU-capped container). The hot path is allocation-free (pooled
per-connection buffers, zero-copy `buf_view` request windows, one batched send per
readiness event). epoll ships `-prod -gc none`; io_uring ships `-prod` (default
GC). See [../docs/V_PERF_TOOLBOX.md](../docs/V_PERF_TOOLBOX.md) and
[../docs/BEST_PRACTICES.md](../docs/BEST_PRACTICES.md).
