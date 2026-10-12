# async_sse — Server-Sent Events from a timer, over server push

`/events` streams five `data:` events, one per second, then `data: bye`. The
stream is a subscribed connection: a `wake_after` timer drives it, and each
time it fires the wake fn appends one event, which goes out at once, and
re-arms. Between ticks the worker serves everyone else; an open stream costs a
timer in the worker's heap, not a thread or an fd, and nothing is allocated
for it.

The stream is finite, so the client must see where it ends: each event is one
HTTP chunk (`Transfer-Encoding: chunked`) and a zero-size chunk ends the body
(RFC 9112 §7.1). Then the server closes the connection, as the head's
`Connection: close` says: a taken-over connection does not go back to
HTTP/1.1.

## Run

```sh
v -prod run examples/async_sse
```

It listens on `:8092` (fixed in [main.v](main.v)) with the epoll backend,
Linux only. Build it with gcc or clang (`-prod`): connection takeover is inert
in a tcc build, the default without `-prod`, and there `/events` answers
`501 Not Implemented`. Any other path gets `404 Not Found`.

```sh
time curl -i -N localhost:8092/events
```

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Transfer-Encoding: chunked
Connection: close

data: tick 1 of 5

data: tick 2 of 5

data: tick 3 of 5

data: tick 4 of 5

data: tick 5 of 5

data: bye

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

## How it works

- **Head, takeover, subscription, timer.** `handle` hands the connection to
  `drain_conn` with `core.queue_takeover` (the client has nothing more to say:
  what it sends is dropped), calls `event_loop.subscribe(sse_tick, nil)` and
  `event_loop.wake_after(tick_ms)`, and appends the `sse_headers` const. The
  head goes out with the response, so the client sees `200
  text/event-stream` before any tick. If the takeover or the subscription is
  not available it answers 501.
- **The count is the subscription's state.** The stream's only state is the
  number of events sent, and it rides in the subscription's state itself, as
  an integer (0 at first): no struct per stream, nothing to free.
- **Tick, append, re-arm.** On `.timeout`, `sse_tick` appends one chunk: the
  hex size (`wx`), then `data: tick N of M\n\n` built from consts and `wi`
  digits, then CRLF. The size is computed up front from the literal parts'
  lengths plus `strconv.dec_digits` of the two counters. It stores the new
  count by subscribing again (that replaces the state, same handle) and
  re-arms the timer. What it appended is flushed as soon as it returns.
- **End the body, close.** On the last tick it appends `bye_and_end` (the
  `bye` chunk and the zero-size chunk in one const) and returns `.close`: the
  bytes go out, then the connection closes.
- **Shutdown.** The stream is not parked, so `srv.shutdown(grace)` does not
  wait for it: its wake fn gets `.shutdown` and ends the body at once with
  `bye_and_end`. No push mailbox is needed for that.
- **Disconnects.** If the client goes away mid-stream, the connection closes
  and its timer goes with it; `.closed` has nothing to release.
- No `${}` anywhere on the path: the event text is consts plus `wi`/`wx`
  appends into `out`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v -cc gcc test examples/async_sse
```

[main_test.v](main_test.v) checks `wx` (chunk sizes up to `7fffffff`) and
drives `sse_tick` directly through stand-in backend hooks: five ticks produce
five byte-exact chunks, the `bye` chunk and the terminator, each tick but the
last storing its count and re-arming; a two-digit counter sizes its chunk
correctly; `.shutdown` ends the body; `handle` takes the connection over,
subscribes and arms the first tick, or answers 501 without push; and a whole
stream (`handle` plus five ticks, 2000 times) allocates nothing. On a live
server through [vtest](../../docs/VTEST.md) the stream ends where its framing
says and the connection closes, `shutdown(5000)` ends a running stream at once
(`tick 1`, then `bye`) instead of waiting for it, other paths get a 404 and a
malformed request gets the 400 and a closed connection.

## See also

- [examples/sse](../sse/) — an open-ended SSE broadcast to many subscribers,
  with events posted from any worker and heartbeats
- [examples/websocket_chat](../websocket_chat/) — server push over WebSocket
- [examples/async_incremental_read](../async_incremental_read/) — chunk-per-suspend
  streaming fed by a pipe (flush-on-suspend)
- [examples/async_timer](../async_timer/) — a one-shot timerfd park
- [examples/chunked_streaming](../chunked_streaming/) — chunked responses
- [core/conn_handle.v](../../core/conn_handle.v) — `subscribe`, `wake_after`
