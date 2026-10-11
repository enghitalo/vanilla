# efficient_date — a per-worker `Date` cache, refreshed lazily

Every response should carry a `Date:` header (RFC 9110 §6.6.1), and it only
changes once a second. Here each worker keeps its own pre-formatted
`Date: …\r\n` line in its `make_state` value and rebuilds it only when a
request notices the wall-clock second has moved on. Nothing is shared between
threads, so there is no lock, no atomic and no background thread: the same
trick nginx uses with its cached time string.

It is one of two takes on the same problem.
[examples/date_header](../date_header/) shares one cache across all workers,
refreshed by a ticker thread and published through a double buffer; its
README has [a side-by-side comparison](../date_header/README.md#date_header-vs-efficient_date).

## Run

```sh
v -prod run examples/efficient_date
```

It listens on `:8096` (set in [main.v](main.v)) and asks for the epoll
backend, so it is Linux-only. Every method and path gets the same reply:

```sh
curl -i localhost:8096/
```

```
HTTP/1.1 200 OK
Date: Sun, 11 Oct 2026 04:10:16 GMT
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

## How it works

- **Per-worker state.** `make_state` (the `ServerConfig` hook, run once per
  worker) returns a fresh `DateCache`: the unix second the line was built for
  (`sec`) and the line itself (`line`, capacity 40). The handler gets it back
  as `worker_state`, so each worker only ever touches its own cache
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **Lazy refresh.** `handle` calls `dc.refresh()` first. `refresh` reads
  `time.unix_now()` (a plain `time()`, served from the vDSO) and returns at
  once if it equals `dc.sec`. Only on a new second does it clear `line` and
  rebuild it with `time.utc().push_to_http_header`, so the formatting happens
  at most once per second per worker, and only on a worker that is serving
  traffic.
- **Always current.** Because every request checks the second, the header is
  never stale; [date_header](../date_header/)'s ticker can lag up to a second.
- **The handler is three appends.** `core.append_str(mut out, head)`,
  `out << dc.line`, `core.append_str(mut out, tail)`: two `const` halves
  around the cached line, straight into `out`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
  The handler never parses the request.
- **Allocation-free between rebuilds.** The `line` buffer keeps its capacity
  across rebuilds, and `test_handler_allocates_nothing` checks that 20k
  requests leave the GC heap counter all but unchanged
  ([BEST_PRACTICES §4](../../docs/BEST_PRACTICES.md#4-allocate-on-the-hot-path-with-intent)).
  The rebuild itself still appends `'Date: '.bytes()` and `'\r\n'.bytes()`,
  a small allocation once a second.

## Tests

```sh
v test examples/efficient_date
```

[main_test.v](main_test.v) calls `handle` directly and checks the response
byte for byte against vlib's `http_header_string`, bracketing each request
with the clock so the expected second is known: any request (even garbage or
an empty buffer) gets the same answer; the line is rebuilt in place, not
appended to, when the second advances; the handler appends after bytes already
in `out`; and 20k requests through one reused buffer grow the GC heap by less
than 4 KiB (the once-a-second rebuild aside).

## See also

- [examples/date_header](../date_header/) — one shared cache, a ticker thread
  and a lock-free double buffer
- [examples/async_date_timerfd](../async_date_timerfd/) — the same per-worker
  cache, refreshed proactively by a timerfd armed in `on_worker_start`, so the
  handler does no time work at all
- [BEST_PRACTICES §3 — the `Date` header worked example](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
