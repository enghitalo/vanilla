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
| Linux | `.epoll` *(default)* | one central acceptor → round-robins fds to per-worker epolls | `.suspend` watches, park deadlines, server push (subscriptions, mailbox), `make_state`, `on_worker_start`, TLS |
| Linux | `.io_uring` | per-worker `SO_REUSEPORT` listener + multishot accept (kernel 5.19+) | `.suspend` watches (oneshot `IORING_OP_POLL_ADD`), `make_state` |
| macOS | kqueue | one central acceptor → round-robins fds to per-worker kqueues | `.suspend` watches, `make_state` |
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
  all in the worker's own event loop. An fd the app owns and reuses across
  requests (a pooled DB or upstream connection) parks with
  `event_loop.watch_fd_persistent(...)` instead, so a client that disconnects
  mid-wait does not close it (epoll and io_uring; the kqueue runtime does not
  honor it yet). On epoll the continuation still runs when that fd is ready,
  with `event_loop.orphaned()` true, to drain the reply (its answer is
  discarded). Linux epoll (plain HTTP and HTTPS) + io_uring and
  macOS/kqueue; on Windows/IOCP a `.suspend` closes the connection (no watch
  reactor there yet).
- **Bounding a wait** — a park lasts as long as its fd takes, unless it has a
  deadline: `Limits.park_timeout_ms` for every park, or one per watch with
  `event_loop.watch_fd_deadline(..., timeout_ms)` /
  `watch_fd_persistent_deadline(...)` (< 0 exempts one). When it passes
  first, the continuation runs once with `event_loop.timed_out()` true (the
  fd is not ready): answer 504 and return `.done`, or re-arm to keep waiting.
  The watch it stops waiting on is retired — a request-owned fd leaves the
  event loop; a persistent fd keeps a tombstone that consumes the reply still
  due, in order, in a run that sees `event_loop.orphaned()` (see
  `core.EventLoop.timed_out`, `core.EventLoop.orphaned`). The epoll worker
  enforces it, with or without TLS; on io_uring and kqueue a deadline watch is
  a plain watch.
  `event_loop.watch_fd_background(...)` arms a clientless watch from a handler
  or continuation (fire-and-forget I/O on the worker, e.g. pg_async's
  CancelRequest; epoll worker only, false elsewhere).
- **Server push** — a taken-over connection (WebSocket, SSE, h2c) can
  `event_loop.subscribe(wake_fn, sub_state)`: it keeps reading its client,
  and its wake fn (a `core.WakeFn`, called on its own worker between client
  bursts) gets every other event, told apart by `event_loop.reason()`:
  `.posted` (`ConnHandle.post_wake` / `post_bytes` from any thread; read
  `post_tag()` / `post_data()`), `.timeout` (`event_loop.wake_after(ms)`, no
  `Limits` needed), `.shutdown` (`Server.shutdown`), and last `.closed`,
  exactly once whatever closed it — free the subscription's state there. The
  `ConnHandle` subscribe returns is generation-checked on its worker: a post
  for a connection that is gone is dropped (`Server.push_stats().stale`),
  never delivered to the connection that reuses its fd number. Posts need
  `ServerConfig.push_mailbox_slots > 0` (a bounded ring per worker, ~280 B a
  slot; a post never blocks and reports `.full` / `.too_big` / `.ok`); past
  `push_watermark_bytes` (default 1 MiB) pending, a subscriber is closed. A
  subscription does not park the connection and does not hold
  `shutdown(grace)`. Epoll worker only (plain HTTP and HTTPS): elsewhere
  `subscribe` returns a nil handle and posts report `.unsupported`. See
  `examples/websocket_chat`, `examples/sse` (a stream with no frames to read:
  a drain-only takeover plus a subscription), `examples/async_sse` (a timer
  stream, no mailbox) and `core/conn_handle.v`.
- **Per-worker state** — set `make_state`: it runs once per worker thread, and
  every handler call on that worker receives the value as the
  **`worker_state`** parameter (e.g. a per-thread DB connection — no shared
  pool, no mutex).
- **Connection identity** — `event_loop.conn_id()` names the connection a
  handler, continuation, `ConnHandler` or wake fn serves: one value for every
  request of a keep-alive connection, never given to another connection in
  the process (other workers and other servers included). Cache what
  belongs to the connection (peer credentials, the peer's address) under
  it, not under `client_fd`, whose number the next connection gets: in a
  per-worker table indexed by fd that keeps the id beside the value, since
  nothing reports a plain connection's close. Never what a request's
  headers establish (`Authorization`, cookies): a proxy's pooled connection
  carries many users' requests. It is a field load; each worker takes ids
  from one process-wide counter 65,536 at a time, when a connection's state
  is made. Epoll worker only (plain HTTP and HTTPS); elsewhere, and where
  there is no client, it is 0: unknown, don't cache.

`on_worker_start` arms clientless background watches (e.g. a periodic timerfd that
refreshes per-worker state with no extra thread). Linux/epoll, plain HTTP or
HTTPS.

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

On POSIX, if SIGPIPE still has its default action, `new_server` makes the
whole process ignore it: a write to a peer that has closed or reset the
connection fails with `EPIPE` instead of killing the process, and the server
closes that connection. A SIGPIPE handler the application installed before
`new_server` is kept. An ignored signal is inherited across exec, so a child
process that relies on SIGPIPE's default action should restore it.

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
| `park_timeout_ms` | the default deadline of a request parked on a watch (`.suspend`): past it, the continuation runs once with `event_loop.timed_out()` true and answers (504). Per park — a re-arm gets a fresh one — and overridden per watch by `watch_fd_deadline` (< 0 exempts a watch). The only bound on a parked request: none of the above applies to one. Epoll worker only |

Deadlines are enforced by each worker's sweep, which runs every
`Limits.sweep_interval_ms()` (a quarter of the shortest timeout, clamped to
25–250 ms): a connection is closed at most one interval after its deadline.
Park deadlines are not swept: each worker keeps them in a min-heap and wakes
for the earliest, so one fires within about a millisecond of its time, with
or without any other timeout set. A request parked with a deadline holds
`shutdown(grace)` only until that deadline answers it.

Use `idle_timeout_ms: -1` when a handler hands its fd to another thread to
stream (the fd-handoff pattern in `examples/video_stream`): the core has seen
the response finish, so the connection looks idle to it. A stream on server
push (`examples/sse`) needs no such opt-out: a taken-over connection is not
idle-reaped.
Behind a load balancer that pools upstream connections, keep `idle_timeout_ms`
longer than the balancer's own idle timeout, or it will reuse a connection the
server is closing and answer 502.

**kqueue (macOS) enforces none of `max_connections`, `read_timeout_ms`,
`write_timeout_ms`, `idle_timeout_ms` or `park_timeout_ms` yet** — only the
header/body size limits. Do not rely on it to reap connections. io_uring
enforces every timeout but the park deadlines.

### Running out of file descriptors

Every connection holds an fd, as do the server's own listeners and epoll/ring
fds and whatever handlers open (database and upstream pools, files). Once the
process reaches `RLIMIT_NOFILE` (`ulimit -n`; systemd gives services a soft
limit of 1024 unless `LimitNOFILE=` says otherwise), `accept()` fails with
`EMFILE` until an fd is freed. The epoll, io_uring and poll acceptors then stop
accepting for `socket.accept_pause` (50 ms) at a time rather than retrying at
once: new clients wait in the listen backlog and are accepted once a
connection closes, and stderr gets one notice per acceptor at most every
10 s. `ENFILE`, `ENOBUFS` and `ENOMEM` are handled the same way. (kqueue still
retries at once: [#154](https://github.com/enghitalo/vanilla/issues/154).)

Raise the limit to fit the connections you expect, and set `max_connections`
below it: a client over that cap gets a prompt close instead of a wait in the
backlog. [../docs/PERF_TUNING.md](../docs/PERF_TUNING.md) covers raising it
(shell, systemd, Docker), the listen backlog and `net.core.somaxconn`, and the
per-connection memory that `max_connections` bounds.

## TLS

Set `ServerConfig.tls_config` (`tls.new_self_signed()`, or
`tls.new_from_pem(cert, key)` for a CA-issued certificate) for HTTPS on the
**epoll** backend; `new_server` refuses it on the other backends rather than
serve plaintext. (`ServerConfig.certificates`
is not read: [#287](https://github.com/enghitalo/vanilla/issues/287).) The handshake
is bounded from accept, before any TLS record arrives: by `read_timeout_ms`,
or, when that is 0, by `idle_timeout_ms` (a new connection's idle deadline runs
until its first decrypted byte, so it covers the whole handshake). A client
that connects and never finishes its handshake is closed (silently) once the
deadline expires. Still set a read timeout on any public HTTPS server:
`idle_timeout_ms` alone does not bound a request that has started arriving
(slowloris).

An HTTPS connection is served by the same epoll worker, connection state
and reactor as a plain one (`backend_epoll/tls_conn_linux.c.v` adds the
handshake and the record I/O), so everything in the handler contract above
works over TLS too: pipelining, `.suspend` with park deadlines and
`watch_fd_background`, takeover (WebSocket over TLS), server push
(`subscribe`, the mailbox, `wake_after`), `on_worker_start`, streamed large
uploads and `Expect: 100-continue`, and a `.close` that sends all of its
response before it closes. The limits are the same as well: a peer that
pipelines without reading is closed once the worker holds 8 MiB unsent for
it (`core.max_pending_write_bytes`), so hand a large body off with
`core.queue_file` rather than appending it whole. Two things differ: a read
timeout closes silently (no 408: it would go out as plaintext), and code that
touches the client socket itself sees TLS records, not HTTP, on a
userspace-TLS connection (a readable watch on the client's own fd, or the
fd-handoff pattern of `examples/video_stream`, where another thread writes to
it).

After the handshake the record crypto moves into the kernel (kTLS) when the
host has the `tls` module; otherwise the connection stays on Mbed TLS, and the
server logs the fallback once. A file body handed off with `core.queue_file`
(static_assets does it for files of at least `sendfile_min_bytes`) leaves a
kTLS connection with `sendfile(2)`, with no userspace copy; on a
userspace-TLS connection the worker reads it and sends it through Mbed TLS a
chunk at a time (64 KiB), the first one behind the headers. A request
pipelined behind a file is answered once the file is out: until then the
connection reads and answers nothing more (the plain path instead reads the
rest of the file into its write buffer, which past the 8 MiB cap closes the
connection).
`tls_config.set_ktls(false)` keeps every new connection on Mbed TLS (tests of
that path, or an operator kill switch).

Every worker can serve TLS. How much of the crypto runs in parallel depends on
how Mbed TLS was built. Its PSA Crypto state (the key store, the RNG) is
shared by the whole process:
- **Built with `MBEDTLS_THREADING_C` and `MBEDTLS_THREADING_PTHREAD`:** Mbed
  TLS locks that state itself, and the workers run their crypto in parallel.
  To build it so, run this in the Mbed TLS 4 source tree before configuring
  it with CMake (the TLS CI lane's threading leg does the same):
  `python3 scripts/config.py set MBEDTLS_THREADING_C && python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD`.
  Compile vanilla against the headers that build installs, since the options
  change struct layouts.
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

Worker count = `ServerConfig.workers` → `VANILLA_WORKERS` env → `runtime.nr_cpus()`
(set `VANILLA_WORKERS` under `taskset`, a cpuset or a CPU-capped container:
`nr_cpus()` counts the host's online CPUs). The hot path is allocation-free (pooled
per-connection buffers, zero-copy `buf_view` request windows, one batched send per
readiness event). epoll ships `-prod -gc none`; io_uring ships `-prod` (default
GC). For deployment (CPU split, `VANILLA_PIN_CPUS`, fd and locked-memory limits,
backlog sysctls, buffer sizing, io_uring and kTLS host requirements) see
[../docs/PERF_TUNING.md](../docs/PERF_TUNING.md); for handler code,
[../docs/V_PERF_TOOLBOX.md](../docs/V_PERF_TOOLBOX.md) and
[../docs/BEST_PRACTICES.md](../docs/BEST_PRACTICES.md).
