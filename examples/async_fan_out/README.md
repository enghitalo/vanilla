# async_fan_out — N operations in parallel, one answer

One request starts N operations at once and answers when the last one has
finished. Its latency is the slowest operation's, not the sum of all of them.
This is fan-out, or aggregation: a gateway calling several upstreams for one
page, a scatter-gather query over shards.

A parked request still waits on **one** fd. Here that fd is an **aggregator**:
an epoll instance of the request's own, with the N operations' fds registered
in it. An epoll fd is readable whenever one of its members is, so the worker
(epoll or io_uring) watches it like any other fd. The engine needs no change,
and requests that don't fan out pay nothing.

`/fan?n=8&ms=200` arms N one-shot timers, member i firing after
`ms*(i+1)/n` ms. They stand in for N upstream calls of different speeds.

## Run

```sh
v -prod run examples/async_fan_out/src
```

It listens on `:8100` (fixed in [src/main.v](src/main.v)) with the epoll
backend; timerfd and the epoll aggregator make it Linux-only. `n` is capped
at 32 (default 8), `ms` at 10 s (default 200). Any other path gets
`404 Not Found`.

```sh
time curl -i 'localhost:8100/fan?n=8&ms=400'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 64
Connection: keep-alive

{"n":8,"done":8,"elapsed_ms":400,"slowest_ms":400,"sum_ms":1800}
real	0m0.409s
```

The eight members one after the other would take `sum_ms`, 1800 ms; together
they take the slowest one's 400 ms. Requests overlap too. With one worker,
sixteen such requests (128 timers) all finish in about the time of one:

```sh
VANILLA_WORKERS=1 v -prod run examples/async_fan_out/src
time (seq 16 | xargs -P16 -I{} curl -s 'localhost:8100/fan?n=8&ms=400' -o /dev/null)
```

```
real	0m0.413s
```

`&budget=MS` bounds the whole fan-out. When it runs out first, the answer is
`504 Gateway Timeout` with how many members made it, and the rest are
cancelled:

```sh
curl -i 'localhost:8100/fan?n=8&ms=400&budget=180'
```

```
HTTP/1.1 504 Gateway Timeout
Content-Type: application/json
Content-Length: 64
Connection: keep-alive

{"n":8,"done":3,"elapsed_ms":181,"slowest_ms":400,"sum_ms":1800}
```

## How it works

- **Start everything, park once.** `handle` takes a `Group` from the
  worker's free list and `launch`es it: `fan_open` creates the aggregator
  (`epoll_create1`), then each member's timerfd is armed and registered in
  it with `fan_add`, the member's index in the event's data. Then one watch,
  on the aggregator, and `.suspend`.
- **Drain what finished, park again.** `on_ready` runs when the aggregator
  is readable. `drain` calls `fan_ready` (`epoll_wait` with a zero timeout),
  which returns the indices of the members that finished, and closes each
  of them. Closing a member also takes it out of the aggregator. While
  members are left it watches the aggregator again (`.suspend`); after the
  last one it closes the aggregator, answers 200 and returns `.done`. A
  real member (an upstream socket) would read its reply at that point, and
  a hangup (`EPOLLHUP`) would end it like a reply. If the aggregator itself
  wakes with an error, or cannot be watched again, `on_ready` closes every
  member and answers `502` instead of waiting on it.
- **Nothing allocated per request.** Each worker's `make_state` value holds
  256 `Group`s, allocated once: member fds in a fixed array, and the
  `fan_ready` scratch. The watch payload points at the group. When all 256
  are in flight, the next request is shed with `503`. The body is appended
  in parts with `core.append_str` and `wi`, its `Content-Length` counted
  first ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- **The budget is the park deadline.** Every watch passes what is left of
  the budget to `watch_fd_persistent_deadline`, which arms a fresh deadline
  per park, so the budget bounds the whole fan-out. Without `budget`, the
  server-wide `Limits.park_timeout_ms` applies (none by default). When the
  deadline passes, `on_ready` runs with `event_loop.timed_out()`. It answers
  504 and cancels every member still open: a timer is re-armed to fire at
  once (an upstream socket would get `shutdown(2)`). Park deadlines are
  enforced by the epoll worker only; on io_uring the budget does nothing.
- [fan_out.h](src/fan_out.h) holds the three epoll calls, so V never models
  `union epoll_data` (see `epoll/epoll_shim.h` for why).

## Who closes what

The request owns every fd it opened: the N members and the aggregator. The
continuation closes each one exactly once, on every path. That decides how
the aggregator is watched: with `watch_fd_persistent_deadline` (caller-owned),
not `watch_fd` (request-owned). Here is what happens on each path:

| path | epoll worker | io_uring worker |
|---|---|---|
| members finish | `on_ready` closes them as they finish, then the aggregator | same |
| budget runs out | `on_ready` answers 504 and cancels the members. The runtime keeps the watch as a **tombstone**: once the cancelled members fire, `on_ready` runs again, orphaned, and closes them and the aggregator | no deadline: as "members finish" |
| client hangs up while parked | the watch becomes a tombstone: `on_ready` runs, orphaned, as members finish, and closes everything | the hangup is noticed only on resume: `on_ready` runs as usual and the send fails |

A `watch_fd` aggregator would be wrong on epoll. On a hangup the runtime
closes a request-owned fd itself and does not run the continuation, so the
aggregator would go but the N members it holds would stay open for good
(closing an epoll fd does not close its members). The test suite checks
this: with `watch_fd_deadline` in `park`, `check_disconnect` finds all 32
timers of four abandoned fan-outs still open. A caller-owned watch is never
closed by the runtime, and its tombstone guarantees the continuation still
runs when the aggregator is ready. That is the same guarantee a pooled
database connection relies on
([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).

Two rules follow, and `on_ready` keeps both:

- After a timeout, **don't close the aggregator in the timeout branch.** The
  tombstone stays on its number until the run that drains it. Cancel the
  members instead, so that run comes at once.
- **Every member must finish** (or be cancelled), or the tombstone of an
  abandoned request waits for it. Timers always fire, at most 10 s here. An
  upstream that may never answer needs a deadline of its own, or its
  socket shut down on the budget, as the cancel step does.

A tombstone's run is **orphaned**: `event_loop.orphaned()` is true, its
request is over (answered 504, or its client gone) and its output is
discarded. There `on_ready` only drains and closes, and writes no answer.

## Engine-level multi-watch

The runtime arms one watch per parked request, and this example keeps that
rule (see [BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
Several watches armed for one connection is a different design. It is tracked
in [vanilla#141](https://github.com/enghitalo/vanilla/issues/141), where
several HTTP/2 streams of one connection need to park at once. The
aggregator gets fan-out without it.
The cost is one `epoll_create1` and one `close` per request, and an
`epoll_wait` per wake.

## Tests

```sh
v test examples/async_fan_out/src
```

[src/main_test.v](src/main_test.v) has two parts:

- **In process, no server:** the handler and its continuation are driven
  through a stub watch registration.
  - Query parsing and its caps, and the member delays.
  - A whole fan-out answers byte-exact, its `Content-Length` matching its
    body, and every fd it opened is closed afterwards.
  - The timeout branch answers 504. Its tombstone runs then close
    everything at once, without writing a second answer.
  - A full group pool sheds 503, and a refused watch answers 503 and closes
    every fd. An aggregator that fails, or that cannot be watched again
    while members are left, answers 502 and closes every fd.
  - 200 fan-outs allocate nothing.
- **On a live server through [vtest](../../docs/VTEST.md), on epoll and on
  io_uring** (where it is available; the io_uring checks skip otherwise):
  - Eight requests of sixteen members each, on one worker, all answer in
    more than the slowest member's 400 ms and less than the 3400 ms that
    *one* request's members take one after the other.
  - Four clients park and hang up: every timerfd and epoll fd the requests
    opened is closed once the members finish, counted in `/proc/self/fd`
    against a baseline, and the worker serves on.
  - On epoll, a budget: `n=10&ms=10000&budget=1500` answers 504 with
    `"done":1`, and the nine cancelled members are closed at once, not
    when the slowest one would fire.

## See also

- [examples/async_multi_watch](../async_multi_watch/) — several fds in
  sequence, one at a time
- [examples/async_time_limit](../async_time_limit/) — a cooperative budget
  over multi-step work
- [examples/async_db_pg](../async_db_pg/) — a caller-owned (pooled) fd
  parked with `watch_fd_persistent`
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
