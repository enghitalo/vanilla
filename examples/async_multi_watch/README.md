# async_multi_watch — one request, several fds in sequence

`/chain` waits on timer A (80 ms), then on a **different** timer B (140 ms),
then answers. Each continuation may arm a new watch and return `.suspend`
again, so one request walks a chain of fds. That is the shape of every "do X,
once it is ready do Y, then reply" flow: connect, send, receive; or a query
whose result feeds a second query.

The steps of one request are sequential: a request waits on one fd at a time.
Different requests overlap freely, because the worker is free between stages.

## Run

```sh
v -prod run examples/async_multi_watch
```

It listens on `:8094` (fixed in [main.v](main.v); [async_pipe](../async_pipe/)
uses the same port, so run one at a time) with the epoll backend; timerfd
makes it Linux-only.

```sh
time curl -i localhost:8094/chain
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 46
Connection: keep-alive

stage A done (80ms), then stage B done (140ms)
real	0m0.227s
```

Any other path gets `404 Not Found` with an empty body. With a single worker,
fifty concurrent chains finish in about the time of one:

```sh
VANILLA_WORKERS=1 v -prod run examples/async_multi_watch
time (seq 50 | xargs -P50 -I{} curl -s localhost:8094/chain -o /dev/null)
```

```
real	0m0.250s
```

## How it works

- **Stage A.** `handle` routes with `route_is` (path bytes up to the first
  `?`, compared in place), then calls
  `event_loop.watch_fd(one_shot_timer(80), .readable, after_a, nil)` and
  returns `.suspend`. `one_shot_timer` creates a `CLOCK_MONOTONIC` timerfd
  and arms it once (`it_interval` zero).
- **Stage B, from a continuation.** `after_a` runs when timer A fires:
  `drain_close` reads its expiration count and closes it (each stage owns its
  own fd), then `after_a` watches a **new** timerfd with `after_b` as the
  continuation and returns `.suspend` again. The request stays parked; only
  the fd it waits on changes.
- **Answer.** `after_b` drains and closes timer B, appends the `resp_chain`
  const and returns `.done`. The 404 and the canned 400 are consts too
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **Watch one fd per step.** Each continuation arms exactly one watch, and
  closes the fd it is done with before moving on. A plain `watch_fd` fd
  belongs to the request: if the client disconnects mid-chain, the runtime
  closes the fd it is parked on
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
- No stage sets a deadline. With `watch_fd_deadline`, each call arms a fresh
  deadline for its own stage, so to bound the whole chain pass the time left
  (see [async_time_limit](../async_time_limit/)).

## Tests

```sh
v test examples/async_multi_watch
```

[main_test.v](main_test.v) runs a live server through
[vtest](../../docs/VTEST.md): `/chain` answers byte-exact (its fixed
`Content-Length` must match the body) and no sooner than 220 ms, after both
timers; `/chains` gets the 404 and a `/chain` on the same keep-alive
connection still works; a malformed request gets the 400 and a closed
connection, and nothing is left parked or open afterwards.

## See also

- [examples/async_timer](../async_timer/) — the single-step version
- [examples/async_pipe](../async_pipe/) — park/resume on a pipe, portable to
  kqueue
- [examples/async_time_limit](../async_time_limit/) — deadlines on parked
  requests
- [examples/https_upstream](../https_upstream/) — a real multi-step chain
  (connect, send, receive) to an upstream
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
