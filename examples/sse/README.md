### Run the SSE server

```sh
v -prod run examples/sse/src
```

It listens on port 3000: `GET /events` subscribes, `POST /broadcast` sends its
body to every subscriber as one `data:` event, and every subscriber gets a
`: keepalive` comment every 15 s.

### Serve the front-end

```sh
v -e 'import net.http.file; file.serve(folder: "examples/sse/front-end")'
```

### Send a notification

```sh
curl -X POST -d 'hello' http://localhost:3000/broadcast
```

### Subscribers are keyed by the registry's own descriptor

The broadcaster writes to subscribers from other threads, so it keeps a
registry of them. It must not key that registry by the core's fd number. The
core owns that fd and closes it when the client goes away, without telling the
app, and the kernel gives the number to the next accepted connection. An
fd-keyed registry then sends every later event and heartbeat to that
connection, which never subscribed. One disconnect followed by one new
connection is enough, with no timeout involved
([#232](https://github.com/enghitalo/vanilla/issues/232)).

So `Clients.add` registers a `dup()` of the connection instead, and
`GET /events` returns `.close`: the core sends the SSE head and closes its own
fd, and the registry's descriptor is the connection's only one. The dup keeps
the socket open, so its number cannot be reused while it is in the registry,
and only the registry closes it, under its lock. Since the core never reads
the connection again, a client that pipelines more requests behind
`GET /events` subscribes once, instead of taking a descriptor per request.

A subscriber is dropped when a send does not take the whole event: the client
is gone (`EPIPE`, on the second send after it left), or it stopped reading
(`EAGAIN` or a partial write). The registry then shuts the socket down, so the
stream ends at once: an `EventSource` discards an event cut short, and
reconnects.

The costs: a departed subscriber's socket lingers until that failed send, up
to about 30 s with the heartbeat. A subscriber is the registry's, not the
core's, so it does not count toward `max_connections`, and `srv.shutdown()`
does not end it. On Windows a `SOCKET` has no `dup()`, so there the core keeps
the connection (`.done`) and the registry keys its handle. Any request on a
handle drops it from the registry, but a reused handle that has not sent one
yet can still receive a departed subscriber's events.

Two things need core support
([#230](https://github.com/enghitalo/vanilla/issues/230)): a close
notification, to learn of a departure at once instead of from a failed send,
and a single writer per socket. For example, a broadcast that runs between
`Clients.add` and the core's flush of the SSE head reaches the client before
the head.

### Timeouts

On POSIX the core lets go of a subscriber right after the SSE head, so no
`Limits` timeout applies to a stream. On Windows `GET /events` returns `.done`,
so to the core the subscriber looks like an **idle keep-alive connection**.
This example sets no `Limits`, so nothing reaps it. If you add a
`read_timeout_ms`, also set `idle_timeout_ms: -1`: the default (`0`) inherits
the read timeout, so the core would close every subscriber that long after it
subscribed.

```v
limits: server.Limits{
	read_timeout_ms: 10_000 // bounds silent connects and slow requests
	idle_timeout_ms: -1     // never reap idle connections: subscribers look idle
}
```

The cost is that idle keep-alive connections on the other routes are not
reaped either. The async variant ([`examples/async_sse`](../async_sse/main.v):
`.suspend` + `watch_fd`) keeps each stream parked inside the core, and a parked
request is never idle-reaped, so it needs no opt-out.
