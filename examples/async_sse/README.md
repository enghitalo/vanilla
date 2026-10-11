# async_sse — Server-Sent Events from a timer, flushed on `.suspend`

`/events` streams five `data:` events, one per second, then `data: bye`. One
periodic `timerfd` drives the stream: each time it fires, the continuation
appends one event and re-arms. Bytes a continuation appends before returning
`.suspend` are flushed right away, not held until `.done`, so the client gets
each event the moment it is produced. Between ticks the worker serves
everyone else; an open stream costs a timerfd and a small struct, not a
thread.

The stream is finite, so the client must see where it ends: each event is one
HTTP chunk (`Transfer-Encoding: chunked`) and a zero-size chunk ends the body
(RFC 9112 §7.1). The connection then stays open for the next request.

## Run

```sh
v -prod run examples/async_sse
```

It listens on `:8092` (fixed in [main.v](main.v)) with the epoll backend;
timerfd makes it Linux-only. Any other path gets `404 Not Found`.

```sh
time curl -i -N localhost:8092/events
```

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Transfer-Encoding: chunked
Connection: keep-alive

data: tick 1 of 5

data: tick 2 of 5

data: tick 3 of 5

data: tick 4 of 5

data: tick 5 of 5

data: bye


real	0m5.006s
```

The events arrive one second apart (timestamps added by the shell, in
seconds; blank lines omitted):

```
05.543 data: tick 1 of 5
06.543 data: tick 2 of 5
07.543 data: tick 3 of 5
08.543 data: tick 4 of 5
09.544 data: tick 5 of 5
09.548 data: bye
```

`curl --raw` shows the chunk framing (`0x13` = 19 bytes per tick event):

```
13
data: tick 1 of 5


…
b
data: bye


0

```

With a single worker (`VANILLA_WORKERS=1`), 200 concurrent streams
(`seq 200 | xargs -P200 -I{} curl -sN localhost:8092/events -o /dev/null`)
all finished in `real 0m5.182s`: the timers overlap.

## How it works

- **Headers first, then park.** `handle` creates a `CLOCK_MONOTONIC`
  timerfd armed periodic at 1 s (`arm_periodic`), allocates one `Stream`
  (`tfd`, `sent`, `max: 5`) for the whole stream, appends the `sse_headers`
  const and calls
  `event_loop.watch_fd(tfd, .readable, sse_tick, voidptr(st))` before
  returning `.suspend`. The headers are flushed with that first suspend, so
  the client sees `200 text/event-stream` before any tick.
- **Append, flush, suspend.** `sse_tick` drains the timerfd and appends one
  chunk: the hex size (`wx`), then `data: tick N of M\n\n` built from consts
  and `wi` digits, then CRLF. The size is computed up front from the literal
  parts' lengths plus `strconv.dec_digits` of the two counters. It re-watches
  the same fd and returns `.suspend`, which flushes the chunk.
- **End the body, keep the connection.** On the last tick it appends
  `bye_and_end` (the `bye` chunk and the zero-size chunk in one const),
  closes the timerfd (the request owns it) and returns `.done`. Without the
  chunked framing the body would be close-delimited, and on a keep-alive
  connection the client would wait forever.
- **Disconnects.** If the client goes away mid-stream, the runtime closes the
  request-owned timerfd; the `Stream` is left to the GC.
- No `${}` anywhere on the path: the event text is consts plus `wi`/`wx`
  appends into `out`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v test examples/async_sse
```

[main_test.v](main_test.v) checks `wx` (chunk sizes up to `7fffffff`) and
drives `sse_tick` directly with a pipe standing in for the timerfd: five
ticks produce five byte-exact chunks, the `bye` chunk and the terminator,
re-arming on every tick but the last; two- and three-digit counters size
their chunk correctly. On a live server through [vtest](../../docs/VTEST.md)
the stream ends where its framing says, the same connection then answers a
404, and a malformed request gets the 400 and a closed connection.

## See also

- [examples/sse](../sse/) — an open-ended SSE broadcast to many subscribers,
  with heartbeats
- [examples/async_incremental_read](../async_incremental_read/) — the same
  chunk-per-suspend streaming, fed by a pipe
- [examples/async_timer](../async_timer/) — a one-shot timerfd park
- [examples/chunked_streaming](../chunked_streaming/) — chunked responses
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
