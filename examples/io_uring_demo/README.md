# io_uring_demo — one handler, and where the backend is chosen

A hello-world server whose point is the `io_multiplexing` field of
`server.ServerConfig`: the handler is the same on every backend, and the
backend (epoll, io_uring, kqueue, IOCP) is a single config value.

On Linux it runs on **io_uring** when this process can use it, and falls
back to epoll when it cannot (`pick_backend` in [main.v](src/main.v)).
Elsewhere it uses the platform's only backend: kqueue on macOS, IOCP on
Windows.

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

The startup lines say which backend serves it. On a 16-CPU machine running
Linux 7.1 with the common 8 MiB locked-memory limit (`ulimit -l` 8192), after
the listeners' `[socket]` lines:

```
io_uring: 16 rings of 16384 SQ entries do not fit half of RLIMIT_MEMLOCK (`ulimit -l`); every worker starts at 2048 (fell back from 16384)
listening on http://localhost:3000/ (io_uring)
```

Each worker owns a ring. On kernels that charge ring memory to
`RLIMIT_MEMLOCK`, a budget per user (up to 5.11, and from 6.14), the backend
sizes every ring from an even share of half the limit, so that the workers'
own rings fit, smaller when the limit is tight; 5.12 to 6.13 give every
worker a full-size ring. Raise the limit (`ulimit -l unlimited`,
`LimitMEMLOCK=infinity`) for full-size rings everywhere; see
[PERF_TUNING §7](../../docs/PERF_TUNING.md#7-io_uring-host-requirements).

Where io_uring is unavailable (a kernel without it,
`kernel.io_uring_disabled`, a seccomp policy that denies `io_uring_setup`
such as Docker's default or GitHub's hosted runners, or
`VANILLA_NO_IOURING=1`) the same command serves on epoll, with the same
bytes:

```
io_uring is not available to this process; serving on epoll
listening on http://localhost:3000/
```

No liburing is needed: the backend makes the raw `io_uring_setup` /
`io_uring_enter` syscalls.

[probe.c](probe.c) is a separate check, against liburing 2.0 or newer, of what
the kernel offers the backend:

```sh
gcc -o probe examples/io_uring_demo/probe.c -luring && ./probe
```

```
io_uring: available
IORING_OP_ACCEPT: supported
multishot accept: works
```

The probe's op table has no bit for multishot accept
(`IO_URING_OP_SUPPORTED` only says the accept opcode exists), so it connects
to a loopback listener, arms a multishot accept on it and reads the
completion: a kernel older than 5.19 rejects it with `EINVAL`. The backend
itself decides by kernel release.

## How it works

- **The backend is config, not code.** `server.new_server` takes
  `io_multiplexing`; the handler signature (`core.Handler`) and the bytes it
  appends do not change. On io_uring each worker runs its own ring with its
  own `SO_REUSEPORT` listener; on epoll one acceptor feeds the worker loops
  (see [examples/per_server_workers](../per_server_workers/)).
- **Pick io_uring only where it runs.** `pick_backend` asks
  `server.iou_backend_available()`, which sets up one small ring per worker
  the server will spawn (and closes them), so a host that refuses io_uring,
  or cannot fit even the smallest rings, serves on epoll instead. It is a
  check, not a reservation: rings the user's other processes take between
  the check and the workers' setup still count. `VANILLA_NO_IOURING` forces
  the epoll path.
- **The reply is a `const`.** `handle_request` appends `hello_response`, a
  `const` string, with `core.append_str`: no allocation per request, the same
  pattern as [examples/tiny](../tiny/)
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **No parsing.** Whatever arrives, even garbage, gets the same 200.

## Tests

```sh
v test examples/io_uring_demo/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly: `GET /`,
other methods and paths, garbage and an empty buffer all get the exact
response, it appends after a response already in `out`, and 20k requests
through one reused buffer allocate nothing. The tests do not
touch any backend; the io_uring backend's own end-to-end tests live in
[tests/io_uring_backend_test.v](../../tests/io_uring_backend_test.v).

## See also

- [examples/tiny](../tiny/) — the same server on the default backend
- [examples/per_server_workers](../per_server_workers/) — worker counts per backend
- [BEST_PRACTICES §4 — allocation, and why io_uring builds use the GC](../../docs/BEST_PRACTICES.md#4-allocate-on-the-hot-path-with-intent)
