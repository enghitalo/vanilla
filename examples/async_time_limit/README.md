# async_time_limit — a time budget over multi-step async work

`/job?steps=N` does N units of work, each one a 50 ms timer tick, under a
300 ms budget. Every time the request resumes, its continuation checks the
clock before doing more, and answers `504 Gateway Timeout` as soon as the
budget is spent. A job that is too big is cut off instead of running away.

This is the cooperative half of per-request time limits: one monotonic clock
read per resume, no extra watch. It acts only when a step resumes. A step
whose fd may never become ready (a hung upstream) needs the runtime's own
deadline as well (see the last bullet below).

## Run

```sh
v -prod run examples/async_time_limit
```

It listens on `:8095` (fixed in [main.v](main.v)) with the epoll backend;
timerfd makes it Linux-only. `N` comes from the leading digits of the `steps`
query parameter; missing, empty or zero means 10. Any other path gets
`404 Not Found`.

```sh
time curl -i 'localhost:8095/job?steps=4'
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 32
Connection: keep-alive

completed within budget (~200ms)
real	0m0.206s
```

Ten steps would take about 500 ms, so the job is cut off at the first tick
past the budget:

```sh
time curl -i 'localhost:8095/job?steps=10'
```

```
HTTP/1.1 504 Gateway Timeout
Content-Type: text/plain
Content-Length: 44
Connection: keep-alive

deadline exceeded after 350ms (budget 300ms)
real	0m0.356s
```

## How it works

- **Per-request state in the payload.** `handle` creates a `CLOCK_MONOTONIC`
  timerfd and arms it periodic at 50 ms (`arm_periodic`). The job's state is
  two numbers, `start` (`time.ticks()`, in ms) and the steps `left`, and
  `pack_job` packs them into the 64-bit `watch_payload` itself (start in the
  high 48 bits, steps in the low 16, so `steps` is capped at `max_steps`,
  65535, far past what the budget allows): nothing is allocated per request.
  `handle` calls
  `event_loop.watch_fd(tfd, .readable, tick, pack_job(time.ticks(), steps))`
  and returns `.suspend`; every resume gets the payload back, and the
  timerfd as `ready_fd`. The budget itself is the `budget_ms` const.
- **Check, then work.** `tick` drains the timerfd's expiration count, then
  unpacks the payload (`unpack_job`) and compares `time.ticks() - start` with
  `budget_ms`. Over budget: close the timerfd, answer 504, `.done`.
  Otherwise it counts one step; on the last one it closes the timerfd and
  answers 200; else it re-watches the same fd with one step less packed in
  and returns `.suspend`. The request owns the timerfd: on a client
  disconnect mid-job the runtime closes it.
- **Dynamic bodies, appended in parts.** Both replies carry the elapsed time.
  `tick` computes the `Content-Length` up front from the literal parts'
  lengths plus `strconv.dec_digits` of each number, then appends the const
  head, the length and the body pieces straight into `out`, integers through
  the local `wi` (`strconv.write_dec` into a stack scratch). No `${}`, no
  intermediate string
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- **Parsing in place.** `route_is` and `parse_steps` read the path and the
  `steps` value (`req.get_query_slice`) as offsets into the request buffer.
- **When the fd itself may hang.** The budget is only checked when `tick`
  runs. To bound a wait on an fd that might never be ready, park with
  `event_loop.watch_fd_deadline(fd, .readable, cont, payload, ms_left)` or set
  `Limits.park_timeout_ms`: the continuation then runs once with
  `event_loop.timed_out()` true, and answers 504. Deadlines are enforced by
  the epoll plain worker
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).

## Tests

```sh
v test examples/async_time_limit
```

[main_test.v](main_test.v) unit-tests `parse_steps` (defaults, trailing junk,
other parameters, the cap) and the payload round trip, checks that a whole
job allocates nothing, and drives `tick` directly, with a pipe standing in for the
timerfd and a start time far in the past: the 504's `Content-Length` matches
its body for elapsed values from 3 to 11 digits, and the 200 is framed the
same way. On a live server through [vtest](../../docs/VTEST.md), a 2-step job
(200), a 10-step job (504, elapsed over the budget) and a 404 share one
keep-alive connection, so a wrong length would misframe what follows; a
malformed request gets the 400 and a closed connection.

## See also

- [examples/async_timer](../async_timer/) — the single-step park on a
  timerfd
- [examples/async_multi_watch](../async_multi_watch/) — a chain of different
  fds in one request
- [examples/async_sse](../async_sse/) — a periodic timerfd that streams
  instead of answering once
- [BEST_PRACTICES §5 — bound every park](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
