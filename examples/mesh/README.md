# mesh — service-to-service over a unix socket

The first consumer of the `http1_1.client` codec (issue #122 Client story):
an **edge** server on TCP whose `/mesh` route calls a **backend** server
listening on a unix domain socket, in the same process.

The outbound call is the readiness path the #122 client study measured as
the portable floor, composed from existing pieces — nothing new under
`transport/`:

1. `transport.dial_unix`, pooled per worker (`make_state`): a FIXED pool of
   4 keep-alive connections — a dial costs ~4× a request, so dialing
   per request would dominate; when the whole pool is in flight the route
   answers 503 (the pg_async idiom, sized small on purpose).
2. `client.write_get` serializes into a reused scratch (zero-alloc).
3. `send` → `event_loop.watch_fd_persistent(fd, .readable, ...)` →
   `.suspend` — the worker keeps serving while the backend answers. The
   persistent watch is what a pooled fd needs: a client that disconnects
   mid-call leaves the connection open, and the continuation still drains
   the reply and frees the slot (a plain `watch_fd` closes the fd and leaks
   the slot).
4. The continuation receives into the slot's buffer and `client.Framer`
   frames it, resuming where the last recv stopped (re-arming while
   incomplete). The decoded body is a view into that buffer (a chunked body is
   de-chunked in place), and the edge reply wraps it without `${}`/`+`.
5. The connection goes back to the pool only when the framer's `keep_alive`
   says so: a backend answering `Connection: close`, HTTP/1.0, or a body
   delimited by closing the connection (relayed once the close arrives) is
   re-dialed on the next call.

UDS is the mesh transport on purpose: ≈2.3–2.7× the throughput of TCP
loopback at ~half the CPU per request (the study), with filesystem
permissions as access control.

```sh
v run examples/mesh/src
curl http://localhost:8095/mesh
# {"via":"edge","backend":{"svc":"backend","msg":"hello from the mesh"}}
```
