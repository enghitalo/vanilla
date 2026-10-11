# async_watch_hangup — give up on a watched fd that hung up

A background watch on a pipe, a signalfd, an inotify fd or an upstream socket
can outlive its source: the writer exits, the peer closes. The fd then stays
"ready" forever, and a level-triggered watch re-armed on it wakes the worker on
every loop iteration, burning a core. vanilla tells the continuation about it
with `ready_fd_error == true` (epoll `EPOLLERR|EPOLLHUP`, kqueue
`EV_ERROR|EV_EOF`); the continuation must release the fd instead of watching
it again. This example shows that path.

## Run

```sh
v -prod run examples/async_watch_hangup
```

It listens on `:8098` (fixed in [main.v](main.v)) with the epoll backend, the
only one that runs `on_worker_start`, so it is Linux-only. At startup every
worker logs its hangup once:

```
[worker] background source fd 8 hung up — releasing (no spin)
```

There is one such line per worker (16 on a 16-CPU machine). The server then
serves normally:

```sh
curl -i localhost:8098/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

and sits idle: two seconds later `ps -o pcpu,cputime -p <pid>` showed
`0.0 00:00:00`.

## How it works

- **A source whose producer is gone.** `on_start` (the `on_worker_start`
  hook) opens a pipe, closes the write end at once, and arms a clientless
  watch on the read end:
  `event_loop.watch_fd(read_fd, .readable, on_source_event, nil)`. On the
  next poll epoll reports `EPOLLHUP` for it. The handler is a plain const
  reply and needs no `make_state`.
- **Release on error.** `on_source_event` checks `ready_fd_error` first. When
  it is set, it logs and returns `.close`: for a background watch the runtime
  then detaches **and closes** the fd, so the continuation must not close it
  itself. It does not re-arm.
- **Re-arm on data.** Without an error it would read the ready data (here it
  reads nothing) and re-watch the same `ready_fd`, returning `.suspend`, the
  same pattern [async_date_timerfd](../async_date_timerfd/) uses to keep a
  periodic timer alive. A timerfd never hangs up, so that example can skip the
  check; a pipe, socket, signalfd or inotify watch cannot.
- The rule holds for request watches too: a continuation woken with
  `ready_fd_error` finishes the request (`.done` or `.close`) rather than
  watching the dead fd again.

## Tests

```sh
v test examples/async_watch_hangup
```

[main_test.v](main_test.v) calls `on_source_event` with a stub registration
hook: on a hangup it returns `.close`, watches nothing and writes nothing; on
plain readiness it re-watches the same fd and returns `.suspend`. Then the
real thing on a live server through [vtest](../../docs/VTEST.md): each worker's
watch hangs up at startup, a request is still served, and over a quiet
keep-alive connection that only the 400 ms idle deadline ends, the process
uses less than half that time in CPU. A worker spinning on the dead fd would
burn a whole core for the wait.

## See also

- [examples/async_date_timerfd](../async_date_timerfd/) — a background watch
  kept alive by re-arming
- [examples/async_pipe](../async_pipe/) — a pipe watch a request parks on
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
