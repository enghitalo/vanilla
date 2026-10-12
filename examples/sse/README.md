### Run the SSE server

```sh
v -prod run examples/sse/src
```

It listens on port 3000: `GET /events` subscribes, `POST /broadcast` sends its
body to every subscriber as one `data:` event, and every subscriber gets a
`: keepalive` comment every 15 s.

Streams need the Linux epoll worker, built with gcc or clang (`-prod`):
connection takeover is inert in a tcc build, the default without `-prod`, and
the other backends (kqueue on macOS, IOCP on Windows) have no takeover. There
`GET /events` answers `501 Not Implemented`; `POST /broadcast` still answers
200, with nobody to send to.

### Serve the front-end

```sh
v -e 'import net.http.file; file.serve(folder: "examples/sse/front-end")'
```

### Send a notification

```sh
curl -X POST -d 'hello' http://localhost:3000/broadcast
```

```sh
curl -N http://localhost:3000/events
```

```
data: hello

: keepalive

```

A body of up to 240 bytes is one event: that is what a mailbox slot carries
(below). A larger one gets `413 Content Too Large`. Each line of the body
becomes a `data:` line of the event, so a body cannot end its event early or
add a field of its own.

### How it works

A subscriber stays the server's connection, on server push
([#230](https://github.com/enghitalo/vanilla/issues/230)):

- **Subscribe.** `GET /events` appends the SSE head, hands the connection to
  `drain_conn` with `core.queue_takeover` (what the client sends from now on
  is not HTTP, and is dropped: a request pipelined behind the subscribe does
  not subscribe again), and calls `event_loop.subscribe(sse_wake, id)`. The
  returned `core.ConnHandle` goes into the `Hub`, with the subscriber's id.
  Then `event_loop.wake_after(15_000)` arms the first heartbeat.
- **Broadcast.** `POST /broadcast`, on whichever worker serves it, calls
  `post_bytes` on every handle in the hub. The post goes through the owning
  worker's mailbox (`push_mailbox_slots: 4096`), and `sse_wake` runs there with
  `.posted`: it appends the `data:` event to the connection's write buffer,
  which the worker sends with the same backpressure as any response. No thread
  writes to a socket it does not own, and an event never lands inside another
  write. A post never blocks: a subscriber whose worker's mailbox is full
  misses the event.
- **Heartbeat.** On `.timeout`, `sse_wake` appends `: keepalive` and re-arms
  the timer: one timer per subscriber in its worker's timer heap, no thread.
- **Departure.** However the connection ends (the client leaves, an error, a
  subscriber that stops reading and passes the push watermark, shutdown),
  `sse_wake` runs once more with `.closed`, and the subscriber leaves the hub.
  A handle carries its connection's generation: a post that races the
  departure is dropped on the worker (`Server.push_stats().stale`), never
  delivered to the new connection that reuses the fd number
  ([#232](https://github.com/enghitalo/vanilla/issues/232)).
- **Shutdown.** `srv.shutdown(grace)` does not wait for the streams: they are
  not parked requests. Each gets `.shutdown`, and `sse_wake` ends it; an
  `EventSource` reconnects later.

The hub (subscribers by handle) is the only shared state. Every worker reaches
it through its `make_state` value, and its lock is taken once per subscribe,
departure and broadcast, never per event delivered or per heartbeat. A
subscriber's state is its id, carried as the subscription's state itself: a
subscriber costs its hub entry, and nothing is allocated per event or per
heartbeat.

The streams count toward `max_connections`, and no `Limits` timeout reaps
them: a taken-over connection is never idle-reaped, so `read_timeout_ms` and
`idle_timeout_ms` can be set for the other routes without touching the
streams.

### Tests

```sh
v -cc gcc test examples/sse/src
```

[main_test.v](src/main_test.v) checks the routes, the 413 and 400s, the 501
without push, the subscribe path through stand-in backend hooks, the events
`sse_wake` frames (line splitting included), and that serving and delivering
allocate nothing. [server_end_to_end_test.v](src/server_end_to_end_test.v)
runs the server: a broadcast reaching 8 subscribers on two workers, a
pipelined subscribe registering once, heartbeats, a departed subscriber whose
fd number a new connection takes (a post to its old handle, and a broadcast,
reach nobody), and shutdown ending every stream at once. The streams need
gcc or clang; under tcc only the 501 is checked.
