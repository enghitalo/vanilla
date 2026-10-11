# async_timer — park a request on a timer without blocking the worker

The smallest consumer of vanilla's async runtime, with no database needed:
`/delay?ms=N` parks the request on a `timerfd` and answers `delayed` when it
fires. The handler never sleeps. It registers the fd with
`event_loop.watch_fd(...)`, returns `.suspend`, and the worker goes on serving
other connections until the timer is ready, then runs the continuation.

The same primitive drives an async database query (watch the DB socket), a
reverse proxy (watch the upstream socket) and SSE or WebSocket backpressure
(watch the client for writability). This example is the place to learn it.

## Run

```sh
v -prod run examples/async_timer
```

It listens on `:8091` (fixed in [main.v](main.v)) with the epoll backend;
timerfd makes it Linux-only. `N` comes from the `ms` query parameter: missing,
empty, zero or non-numeric means 200, and anything above 10000 is capped at
10 s, so a client cannot park a request for hours. Every other path answers
`ok` at once.

```sh
time curl -i 'localhost:8091/delay?ms=300'
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 7
Connection: keep-alive

delayed
real	0m0.307s
```

`curl -s localhost:8091/delay` waits the default 200 ms (`real 0m0.206s`), and
`curl -s 'localhost:8091/delay?ms=99999'` the 10 s cap (`real 0m10.007s`).

Parked requests overlap. With a single worker, twenty concurrent 500 ms
delays all finish in about half a second, not ten:

```sh
VANILLA_WORKERS=1 v -prod run examples/async_timer
time (seq 20 | xargs -P20 -I{} curl -s 'localhost:8091/delay?ms=500' >/dev/null)
```

```
real	0m0.516s
```

## How it works

- **Route and query in place.** `route_is` compares the path bytes up to the
  first `?` against a literal, and `delay_ms` reads the `ms` value through
  `req.get_query_slice(ms_key)`, a `Slice` into the request buffer, parsing
  its digits without copying
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
  It stops at `max_ms` as soon as the running value passes it, so a huge
  number cannot overflow.
- **Park.** `handle` creates a `CLOCK_MONOTONIC` timerfd, arms it one-shot
  (`it_value` set, `it_interval` zero) with `timerfd_settime`, calls
  `event_loop.watch_fd(tfd, .readable, timer_done, nil)` and returns
  `.suspend`. The connection stays open and parked; the worker returns to its
  loop.
- **Resume.** When the timer fires, the worker runs `timer_done` with the
  ready fd. It reads the 8-byte expiration count, closes the fd (a plain
  `watch_fd` fd belongs to the request; if the client disconnects first, the
  runtime closes it instead), appends the `resp_delayed` const and returns
  `.done`.
- **Static replies are consts.** `resp_ok`, `resp_delayed` and the canned 400
  (`response.tiny_bad_request_response`, with `.close`) are appended whole
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- The park has no deadline of its own; the `ms` cap is what bounds it. A
  server that waits on something that might never answer should set
  `Limits.park_timeout_ms` or use `watch_fd_deadline` (see
  [async_time_limit](../async_time_limit/)).

## Tests

```sh
v test examples/async_timer
```

[main_test.v](main_test.v) unit-tests `delay_ms` (default, cap, junk,
negative, overflow, `ms` among other parameters) and `route_is` (query
ignored, `/delays` and `/delay/` rejected). On a live server through
[vtest](../../docs/VTEST.md) it checks that `/delay?ms=500` waits at least
500 ms, that other paths answer at once on the same keep-alive connection,
and that a malformed request gets the 400 and a closed connection.

## See also

- [examples/async_multi_watch](../async_multi_watch/) — one request parked on
  two timers in sequence
- [examples/async_pipe](../async_pipe/) — the same park/resume on a pipe, on
  epoll and kqueue
- [examples/async_date_timerfd](../async_date_timerfd/) — a periodic timerfd
  that no request parks on
- [examples/async_time_limit](../async_time_limit/) — park deadlines
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
