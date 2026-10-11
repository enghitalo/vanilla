# logging — an access log that never writes on the request path

One JSON line per request, written to a file and shipped to a collector,
without a syscall, a lock or an allocation on the request path (#15). The
line goes into the worker's own buffer. The worker's timer, on its own
event loop and between requests, writes the buffer to the file and sends it
on to the collector. A slow disk or a dead collector costs log lines, which are
counted, and never request latency.

```sh
v run examples/logging/src
curl -i http://localhost:8098/
curl http://localhost:8098/stats
tail -f access.log
```

```json
{"ts":"2026-10-11T02:51:55.224Z","worker":0,"method":"GET","path":"/?n=1","status":200,"bytes":78,"dur_us":5,"ua":"smoke/1.0"}
```

| Variable | Default | |
|---|---|---|
| `LOG_FILE` | `access.log` | empty: no file |
| `LOG_MAX_BYTES` | 64 MiB | rotate at this size; `0`: never |
| `LOG_KEEP` | 5 | rotated files kept (`access.log.1` … `.5`) |
| `LOG_FLUSH_MS` | 200 | the timer's period: how long a line can wait in its buffer |
| `COLLECTOR_HOST` | unset | unset: no shipping |
| `COLLECTOR_PORT` | 80 / 443 | |
| `COLLECTOR_PATH` | `/ingest` | |
| `COLLECTOR_HTTPS` | `0` | `1`: TLS 1.3, verify-full (build with `-d vanilla_tls`) |
| `COLLECTOR_CA` | system bundle | a private CA |

`GET /stats` reports the counters: `lines`, `dropped` (lines that never
reached the file), `written`, `write_errors`, `reopens`, `rotations`,
`shipped`, `ship_dropped` (lines the collector never got), `ship_failures`.
They lag by up to one tick: each worker publishes its counts at its own tick.

## The request path

`handle` runs the app, then `record` appends the line into the worker's
buffer, the `make_state` value that only this worker's thread touches:

- **No allocation.** Fields are copied from the request buffer and escaped in
  place. Integers go through `wi` (`strconv.write_dec` into a stack
  scratch, then `push_many`). The timestamp's `YYYY-MM-DDTHH:MM:SS` is
  formatted once a second (`clock_gettime` is a vDSO call, not a syscall).
  `test_logging_allocates_nothing` checks the whole path, the flush included,
  with a `gc_heap_usage` delta.
- **The buffer never grows.** A line's worst case is known before a byte is
  written (fields are capped: method 32 bytes, path 2048, user agent 512; a
  byte escapes to at most 6). A line that does not fit is dropped and counted
  in `dropped`.
- **No syscall per line.** Once the buffer passes `flush_at` (64 KiB of
  256), one `timerfd_settime` makes the timer fire at once instead of at its
  next period: once per 64 KiB, not per line.
- **Always valid JSON.** `"` and `\` are escaped, control bytes become `\n`,
  `\r`, `\t` or `\u00XX`, valid UTF-8 is copied, and each byte of an
  ill-formed sequence becomes `�`. A client cannot end the line or forge
  a field (`test_json_escaping`, `test_hostile_fields_stay_one_valid_line`).

## The tick

`on_worker_start` arms a periodic timerfd as a clientless watch on the
worker's epoll loop (the pattern of `examples/async_date_timerfd`). Its
continuation, `tick`, drains the buffer:

1. **To the file**, in one `write(2)` of many lines. Every worker opens the
   same path with its own `O_APPEND` descriptor. Each write lands at the end
   of the file, and lines never interleave because each write carries whole
   lines. This is nginx's `access_log … buffer=` model. Lines are in order
   within a worker, not across workers: sort by `ts`.
2. **Into the shipping queue**, if a collector is set (below).
3. Worker 0 checks the file's size and rotates it.
4. The worker publishes its counts with atomic adds, once per tick.

## Rotation

- **By size**: worker 0's tick `stat`s the path. Once the file reaches
  `LOG_MAX_BYTES`, it renames `access.log.4` → `.5` … `access.log` →
  `.1` and bumps a shared generation counter. Every worker sees the new
  generation before its next write and reopens the path. Only worker 0
  renames, so no lock is needed. A line that another worker writes between the
  rename and its reopen lands at the end of `.1`: late, never lost. The file
  can exceed the limit by what the workers write in one tick.
- **On `SIGHUP`**, for logrotate. The handler runs in async-signal context on
  whichever thread the kernel interrupts, so it does one async-signal-safe
  thing, an atomic add on the same generation counter. Each worker reopens on
  its own thread:

  ```
  /var/log/app/access.log {
      daily
      rotate 14
      compress
      delaycompress   # a worker may still append to .1 until its next tick
      postrotate
          kill -HUP $(cat /run/app.pid)
      endscript
  }
  ```

## Shipping to a collector

Each worker has its own `http1_1.upstream` pool to the collector (built in
`make_state`, its maintenance started in `on_worker_start`), a bounded queue
(1 MiB) and at most one batch in flight:

- The tick copies the flushed lines into the queue. When the collector is slow
  or down and the queue is full, the lines that do not fit are dropped and
  counted in `ship_dropped`. The file still has them, and the worker never
  waits.
- The tick POSTs the queue's head, up to 256 KiB of whole lines, as
  `application/x-ndjson`. `send()` starts a non-blocking connect or write and
  parks the pool's socket on the worker's loop.
- `on_ship`, the batch's continuation, advances the exchange. It does not
  release the exchange itself: a clientless continuation that returns `.done`
  makes the runtime close the watched fd, and that fd is the pool's keep-alive
  connection. Instead `on_ship` re-arms the timer, so the runtime only takes
  the socket out of epoll, and kicks it. The next tick releases the exchange,
  which keeps the connection, and sends the next batch.
  `test_ships_every_line_over_one_kept_connection` checks that two batches
  share one connection.
- A **2xx** takes the batch off the queue. A **4xx** other than 408 or 429
  will never be accepted, so the batch is dropped and counted. Anything else
  keeps the batch at the head for a retry after a backoff that doubles from
  500 ms up to 30 s: no answer, a timeout (the pool's `response_timeout_ms`,
  5 s), a 5xx, 408 or 429. Delivery is at least once: a batch whose answer was
  lost is sent again.

## Shutdown

On `SIGTERM`/`SIGINT`, as in `examples/graceful_shutdown`, the signal handler
only writes to a pipe. A normal thread calls `srv.shutdown(2000)`, sets a
shared stop flag, and waits until every worker has flushed at its next tick
and acked. The wait is capped, so a worker stuck on a dead disk cannot hold
the exit. Batches still queued for the collector are lost with the process,
but they are already in the file.

## Not covered

- A request that parks (`.suspend`) is logged here as the handler returned,
  not as it ended. Record it from its continuation instead.
- No client address: `getpeername` would be a syscall per request. Behind a
  proxy, take it from `X-Forwarded-For` (`examples/proxy_aware`).
- The Linux epoll plain worker only, the one that runs `on_worker_start`.

## Tests

```sh
v test examples/logging/src
v -race -cc clang test examples/logging/src
```

`src/log_test.v` drives the handler, the escaping, the timestamp (against
`time`), the flush from two workers, the full buffer, the size rotation,
`SIGHUP` after a rename, the tick and the shutdown ack, and the allocation
check, all in process. `src/ship_e2e_test.v` runs the server against a fake
collector on a thread of the test. It checks every line arriving over one
kept connection, a refused collector (drops counted, every request answered),
a 503 retried until accepted, and a collector that never answers (timed out,
then sent again).
