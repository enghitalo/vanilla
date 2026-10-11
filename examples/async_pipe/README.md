# async_pipe — portable park and resume on a pipe

The smallest **portable** consumer of `event_loop.watch_fd`: `/async` parks
the request on the read end of a pipe and answers `async-ok` from the
continuation. It uses only `pipe`, `read`, `write` and `close`, so the same
code runs on Linux epoll and macOS kqueue with no platform branches. The
timerfd examples ([async_timer](../async_timer/),
[async_multi_watch](../async_multi_watch/)) are Linux-only.

The handler makes the pipe readable itself, standing in for "the async work
finished". A real consumer watches an fd that becomes ready later: a database
socket, an upstream, a timer.

## Run

```sh
v -prod run examples/async_pipe/src
```

It listens on `:8094` (fixed in [main.v](src/main.v);
[async_multi_watch](../async_multi_watch/) uses the same port, so run one at a
time). It sets no backend, so it gets the platform default: epoll on Linux,
kqueue on macOS.

```sh
curl -i localhost:8094/async
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 8
Connection: keep-alive

async-ok
```

The query string is ignored (`/async?x=1` parks too); every other path
answers synchronously:

```sh
curl -i localhost:8094/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

A request the parser rejects gets the canned 400 and the connection closes:

```sh
printf 'GET\r\n\r\n' | socat -t1 - TCP:localhost:8094
```

```
HTTP/1.1 400 Bad Request
Content-Length: 0
Connection: close

```

## How it works

- **Park.** For `/async`, `handle` opens a pipe into a `[2]i32` (C ints: V's
  `int` is 64-bit), writes one byte and closes the write end, then calls
  `event_loop.watch_fd(read_end, .readable, pipe_done, nil)` and returns
  `.suspend`. If `pipe` fails it answers `ok` synchronously instead.
- **Resume.** The worker runs `pipe_done` once the read end is readable. It
  drains the byte, closes the fd (the request owns a plain `watch_fd` fd; if
  the client disconnects first, the runtime closes it), appends the
  `resp_async` const and returns `.done`.
- **`.readable`, not `EPOLLIN`.** `core.WatchInterest` is portable: each
  backend maps `.readable` / `.writable` to its own flag (epoll
  `EPOLLIN`/`EPOLLOUT`, kqueue `EVFILT_READ`/`EVFILT_WRITE`). The TLS and
  Windows IOCP workers have no watch reactor, so there a `.suspend` drops the
  connection; the test is built everywhere but Windows.
- **Routing in place.** `route_is` compares the path bytes up to the first
  `?` without copying the request; the replies are consts appended with
  `core.append_str`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/async_pipe/src
```

[server_end_to_end_test.v](src/server_end_to_end_test.v) drives a live server
through [vtest](../../docs/VTEST.md). The body `async-ok` comes only from
`pipe_done`, so it proves the suspend/resume round trip; the test also checks
routing on one keep-alive connection (`/async?x=1` parks, `/asynchronous`
and `/x?async` do not), the 400-and-close path, and that nothing is left
parked or open afterwards.

## See also

- [examples/async_timer](../async_timer/) — park on a timerfd for a requested
  delay
- [examples/async_multi_watch](../async_multi_watch/) — a chain of watches in
  one request
- [examples/async_watch_hangup](../async_watch_hangup/) — what a pipe whose
  writer is gone looks like to a watch
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
