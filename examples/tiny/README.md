# tiny — the smallest vanilla server

One `const` response and one handler that appends it, whatever arrives: no
parsing, no routing, no state. It is the floor every other example builds on,
and the plaintext target that [bench/wrk.sh](../../bench/wrk.sh) and
[bench/load.sh](../../bench/load.sh) drive.

## Run

```sh
v -prod run examples/tiny/src
```

It listens on `:3000` (the `ServerConfig` default; [main.v](src/main.v) sets
only the handler). Every method and path gets the same reply:

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 13
Connection: keep-alive

Hello, World!
```

`curl -i -X POST localhost:3000/anything -d x` returns the same bytes.

## How it works

- **A `const` string, appended.** `hello_world_response` is the whole
  response, status line to body, as a module `const`. The handler calls
  `core.append_str(mut out, hello_world_response)`: one copy into the
  connection's reused write buffer, no allocation
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **Append, never overwrite.** `out` may already hold the responses to
  earlier pipelined requests in the same batch; the handler only adds to it
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)).
- **The server does the rest.** Framing, malformed requests (the canned 400),
  keep-alive, timeouts and worker threads (one per CPU, or `VANILLA_WORKERS`)
  all live in `server`, not in the handler.

## Tests

```sh
v test examples/tiny/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly: the reply is
the same for any request (even garbage or an empty buffer), it appends after
bytes already in `out`, and 20k requests through one reused buffer leave the
GC's allocation counter unchanged.

## Benchmark

```sh
v -prod run examples/tiny/src &
wrk -H 'Connection: keep-alive' -c 512 -t 16 -d 10s http://localhost:3000
```

[bench/wrk.sh](../../bench/wrk.sh) runs this workload against its recorded
baseline (510,197 req/s, `wrk -t16 -c512`) and fails on a regression of more
than 5%.

## See also

- [examples/simple](../simple/) — the next step: parse the request and route
  on method and path
- [BEST_PRACTICES §10 — benchmark before and after](../../docs/BEST_PRACTICES.md#10-benchmark-before-and-after-every-perf-change)
