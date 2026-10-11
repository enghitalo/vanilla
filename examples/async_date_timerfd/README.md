# async_date_timerfd — a `Date` header refreshed by each worker's own timer

Every response carries a `Date:` line (RFC 9110 §6.6.1), but formatting a
timestamp per request is wasted work: it changes once a second. Here each
worker keeps the line pre-formatted in its own state and a per-worker 1 s
`timerfd`, watched on that worker's event loop, refreshes it. The handler does
no time work at all: it appends the cached bytes.

This is the nginx model mapped onto vanilla's per-worker reactor: no extra
thread, no shared state, no lock. It also shows the **clientless background
watch**, a watch armed from `on_worker_start` that no request parks on.

## Run

```sh
v -prod run examples/async_date_timerfd
```

It listens on `:8097` (fixed in [main.v](main.v)) with the epoll backend, the
only one that runs `on_worker_start`, so it is Linux-only. Every method and
path gets the same reply:

```sh
curl -i localhost:8097/
```

```
HTTP/1.1 200 OK
Date: Sun, 11 Oct 2026 03:57:59 GMT
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

The clock advances with no traffic at all: the timerfd wakes the idle loop
once a second. Three seconds later, after no requests in between:

```sh
sleep 3; curl -i localhost:8097/
```

```
HTTP/1.1 200 OK
Date: Sun, 11 Oct 2026 03:58:02 GMT
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

## How it works

- **Per-worker state, no lock.** `make_state` allocates one `DateCache` per
  worker: a fixed `[37]u8` array seeded from `line_template` (`Date: `, the
  29-byte IMF-fixdate, CRLF) plus `last`, the second currently encoded. Only
  that worker's thread ever touches it: `make_state`, `on_start`, the timer
  continuation and the handler all run on it
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **A clientless background watch.** `on_start` (the `on_worker_start` hook,
  run once per worker before its loop) formats the line, creates a
  `CLOCK_MONOTONIC` timerfd, arms it periodic with `arm_periodic(tfd, 1000)`
  (both `it_interval` and `it_value` set), and calls
  `event_loop.watch_fd(tfd, .readable, date_tick, nil)`. No client parks on
  it: the continuation gets a scratch `out` that is discarded.
- **Re-arm the same fd to keep watching.** `date_tick` reads the 8-byte
  expiration count off the timerfd (draining it, so the level-triggered fd
  goes quiet), rebuilds the line, re-watches the same `ready_fd` and returns
  `.suspend`. That keeps the fd alive for the worker's whole lifetime;
  returning `.done`/`.close` instead would make the runtime detach and close
  it. A timerfd never hangs up, so it ignores `ready_fd_error` (see
  [async_watch_hangup](../async_watch_hangup/) for a source that does).
- **Rewrite only the digits that changed.** `rebuild_at` calls the stdlib's
  `time.update_http_header` on `&dc.line[6]`: within the same minute that is a
  two-byte store of the seconds, and a full reformat happens only on a day
  rollover. The clock is read with `time.unix_now()`, not `time.utc()`.
- **The handler is three appends.** `handle` appends the `head` const, pushes
  the 37 cached bytes with `push_many`, and appends the `tail` const: no
  formatting and no intermediate string on the request path
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v test examples/async_date_timerfd
```

[main_test.v](main_test.v) drives `rebuild_at` directly, with no server and
no wall clock, and compares the cached line byte for byte against vlib's
`http_header_string()`: the first format, an idempotent repeat, every
rollover (second, minute, hour, day), jumps forward and backward across
years, and every second of a 30 s window across midnight. It is Linux-only
(`// vtest build: linux`) because it compiles main.v.

## See also

- [examples/efficient_date](../efficient_date/) and
  [examples/date_header](../date_header/) — the same cached `Date` line,
  refreshed lazily by the request that crosses a second instead of a timer
- [examples/async_timer](../async_timer/) — a timerfd that a request parks on
- [examples/async_watch_hangup](../async_watch_hangup/) — a background watch
  whose source hangs up
- [BEST_PRACTICES §3 — the `Date` header worked example](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
