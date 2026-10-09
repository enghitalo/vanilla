### Run the SSE server

```sh
v -prod run examples/sse/src
```

### Serve the front-end

```sh
v -e 'import net.http.file; file.serve(folder: "examples/sse/front-end")'
```

### Send notification

```sh
curl -X POST -v http://localhost:3001/notification
```

### Timeouts and the fd-handoff pattern

`GET /events` returns `.done` after the SSE headers and hands the fd to the
broadcaster, so to the core the subscriber looks like an **idle keep-alive
connection**. This example sets no `Limits`, so nothing reaps it. If you add a
`read_timeout_ms`, also set `idle_timeout_ms: -1`: the default (`0`) inherits
the read timeout, so every subscriber would be closed that long after
subscribing — and the broadcaster, still holding the fd number, could write
events into a new connection that reuses it before that connection's first
request drops the stale subscription.

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
