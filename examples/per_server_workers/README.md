# per_server_workers — size each server's worker pool

Every vanilla server starts one worker thread per CPU (or `VANILLA_WORKERS`).
Run two servers in one process and that doubles: 2 × `nr_cpus` threads
competing for the same cores. `ServerConfig.workers` sets one server's pool
size, so co-hosted servers can split the machine between them.

Here a main API server on `:8080` takes most of the cores and a small admin
server on `:8081` gets two workers (one on machines with fewer than 4 CPUs),
so the pools add up to `nr_cpus`.

## Run

```sh
v -prod run examples/per_server_workers/src
```

Linux only (it uses the epoll backend and exits with a message elsewhere).
Ports `8080` and `8081` are fixed in [main.v](src/main.v). On a 16-CPU
machine:

```
per-server workers: api :8080 = 14, admin :8081 = 2 (nr_cpus=16)
listening on http://localhost:8081/
listening on http://localhost:8080/
```

```sh
curl -i localhost:8080/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 4
Connection: keep-alive

main
```

```sh
curl -i localhost:8081/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 5
Connection: keep-alive

admin
```

The process runs 18 threads (`ls /proc/<pid>/task | wc -l`): 14 + 2 workers
plus one acceptor thread per server. An explicit `workers` wins over
`VANILLA_WORKERS`: with `VANILLA_WORKERS=3` the count is still 18.

## How it works

- **`workers: N` per `ServerConfig`.** `main` computes `admin_workers` and
  `main_workers` from `runtime.nr_cpus()` and passes each to its own
  `server.new_server`. `workers: 0`, the default, keeps the process-wide
  default.
- **Two servers, one process.** The admin server's `run()` blocks, so it runs
  in a `spawn`ed thread; the API server's `run()` takes the main thread.
- **Same meaning, different topology per backend.** `workers` is always the
  number of worker threads. On epoll that is one acceptor plus N event loops;
  on io_uring it is N shared-nothing rings, each with its own `SO_REUSEPORT`
  listener.
- **The handlers build their replies per request.** `api_handler` and
  `admin_handler` append a string literal's `.bytes()`, one allocation per
  request. A `const` string appended with `core.append_str` avoids it
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/per_server_workers/src
```

[main_test.v](src/main_test.v) builds servers with `new_server` and never runs
them: `new_server` sizes the per-worker arrays without spawning threads, so
the checks are deterministic. Two epoll servers with `workers: 5` and
`workers: 9` get pools of 5 and 9; `workers` unset falls back to
`nr_cpus` (the test assumes `VANILLA_WORKERS` is not set); io_uring with
`workers: 6` gets 6 threads and 6 listeners. The tests bind ports
18181–18184.

## See also

- [examples/io_uring_demo](../io_uring_demo/) — choosing the backend
- [examples/mesh](../mesh/) — two servers in one process, an edge on TCP and a backend on a unix socket
- [server/README.md](../../server/README.md) — worker count defaults and `VANILLA_WORKERS`
- [BEST_PRACTICES §6 — concurrency](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)
