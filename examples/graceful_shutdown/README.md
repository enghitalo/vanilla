# graceful_shutdown — drain in-flight requests on SIGTERM

`docker stop`, Kubernetes and systemd stop a service with SIGTERM (Ctrl-C
sends SIGINT). If the process just dies, every request in flight at that
moment fails, and each rolling deploy or scale-down shows up as a burst of
502s. This example wires both signals to `Server.shutdown(grace_ms)`, which
stops accepting, waits for the requests already being handled, then lets the
process exit cleanly.

The interesting part is not the call but where it is made: never inside the
signal handler. The handler only writes one byte to a pipe; an ordinary
thread blocked on that pipe does the drain and the `exit(0)`.

## Run

```sh
v -prod run examples/graceful_shutdown/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)); every request gets an
empty `200 OK`.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive

```

Then stop it with `kill -TERM <pid>` (or Ctrl-C). Measured with the binary
built from this folder, an idle keep-alive connection open, and SIGTERM:

```
Graceful-shutdown demo on http://localhost:3000/  (send SIGTERM to drain & exit)
listening on http://localhost:3000/
signal received: stop accepting, draining (2s), exiting...
```

The process exited with status 0 after 2 ms: the drain returns as soon as
nothing is in flight, the 2 s grace is only the cap. The idle keep-alive
connection was dropped, and a new `curl localhost:3000/` afterwards fails to
connect (exit 7). SIGINT behaves the same.

This example's only route answers instantly, so there is nothing slow to
drain. To watch a drain, the handler was wrapped locally (not in the repo)
with a route that parks 1.5 s on a timerfd and returns `.suspend`, as
[examples/router](../router/)'s `/delay/:ms` does. Sending SIGTERM 0.3 s into
that request: the request still completed with its `200`, a connection
attempted during the drain was refused, and the process exited about 1.5 s
after the request started, not at the 2 s cap.

## How it works

- **The signal handler does one `write(2)`.** `on_signal` (installed with
  `os.signal_opt` for `.term` and `.int`) writes a byte to `wake`, an
  `os.pipe()`, saving and restoring `errno` around it. It runs in
  async-signal context on whichever thread the kernel interrupted, possibly a
  worker, where `exit()` (atexit handlers, stdio locks) or a spin in
  `shutdown()` could deadlock.
- **A normal thread does the work.** A thread spawned before `srv.run()`
  blocks in `os.fd_read(wake.read_fd, 1)`; on wake-up it logs, calls
  `srv.shutdown(2000)`, then `exit(0)`. It captures `srv` by value: shutdown
  only needs the listener fds and the shared in-flight counters.
- **What `shutdown` does** ([server/server.c.v](../../server/server.c.v)):
  closes the listening sockets so the kernel refuses new connections, then
  sums the per-worker in-flight counters until they reach zero or `grace_ms`
  passes. A request parked with `.suspend` (a DB query, an upstream call, a
  timer) counts as in flight, so size the grace for the slowest of those; an
  endless stream (SSE) holds the drain for the whole grace. The counters are
  per worker, each on its own cache line, so counting costs the hot path
  nothing measurable.
- **The handler** appends a `const` string with `core.append_str`: no
  allocation per request
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/graceful_shutdown/src
```

[main_test.v](src/main_test.v) checks that the handler allocates nothing, then
runs it on a live server
through `vtest.start`: a request is served, `shutdown(2000)` on the idle
server returns in under a second, and afterwards four fresh connections are
all refused. The signal-to-pipe wiring in `main` is not covered by the test
(it needs a separate process); the SIGTERM run above exercises it.

## See also

- [examples/router](../router/) — `/delay/:ms`, a request parked on a timer
  (the kind of in-flight work a drain waits for)
- [examples/async_timer](../async_timer/), [examples/sse](../sse/) —
  suspended requests and long-lived streams
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [BEST_PRACTICES §6 — concurrency](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)
