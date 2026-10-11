# io_uring_demo — one handler, and where the backend is chosen

A hello-world server whose point is the `io_multiplexing` field of
`server.ServerConfig`: the handler is the same on every backend, and the
backend (epoll, io_uring, kqueue, IOCP) is a single config value.

**As written it does not run on io_uring.** [main.v](src/main.v) passes
`unsafe { server.IOBackend(0) }`, the first value of the per-OS enum: `epoll`
on Linux, `kqueue` on macOS. That is also why it builds and runs everywhere
(CI runs it on macOS too). To try io_uring, change that line to
`io_multiplexing: .io_uring` (Linux only), as shown below.

## Run

```sh
v -prod run examples/io_uring_demo/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Every request gets the
same reply:

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 13
Connection: keep-alive

Hello, World!
```

**On io_uring.** With `io_multiplexing: .io_uring` the startup line says so
and the replies are byte-identical:

```
listening on http://localhost:3000/ (io_uring)
```

The backend needs a kernel with io_uring that is not disabled
(`/proc/sys/kernel/io_uring_disabled` is `0`) or blocked by a seccomp policy
(GitHub's hosted runners deny `io_uring_setup`). Each worker owns a ring, and
rings count against the locked-memory limit (`ulimit -l`): here, with 16
workers and an 8 MiB limit, one worker failed `io_uring_setup` and the
process exited. `VANILLA_WORKERS=4` ran cleanly. No liburing is needed: the
backend makes the raw `io_uring_setup` / `io_uring_enter` syscalls.

[probe.c](probe.c) is a separate C check against liburing (`gcc probe.c
-luring`). It reports whether the kernel supports `IORING_OP_ACCEPT`, though
it prints that as "multishot accept supported": the flag it tests,
`IO_URING_OP_SUPPORTED`, means the opcode is supported at all, not multishot.

## How it works

- **The backend is config, not code.** `server.new_server` takes
  `io_multiplexing`; the handler signature (`core.Handler`) and the bytes it
  appends do not change. On io_uring each worker runs its own ring with its
  own `SO_REUSEPORT` listener; on epoll one acceptor feeds the worker loops
  (see [examples/per_server_workers](../per_server_workers/)).
- **The handler builds its reply per request.** `handle_request` turns a
  string literal into a fresh array with `.bytes()` and appends it, which is
  one allocation per request. The pattern to copy is
  [examples/tiny](../tiny/)'s `const` string appended with `core.append_str`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **No parsing.** Whatever arrives, even garbage, gets the same 200.

## Tests

```sh
v test examples/io_uring_demo/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly: `GET /`,
other methods and paths, garbage and an empty buffer all get the exact
response, and it appends after a response already in `out`. The tests do not
touch any backend; the io_uring backend's own end-to-end tests live in
[tests/io_uring_backend_test.v](../../tests/io_uring_backend_test.v).

## See also

- [examples/tiny](../tiny/) — the same server, written the zero-allocation way
- [examples/per_server_workers](../per_server_workers/) — worker counts per backend
- [BEST_PRACTICES §4 — allocation, and why io_uring builds use the GC](../../docs/BEST_PRACTICES.md#4-allocate-on-the-hot-path-with-intent)
