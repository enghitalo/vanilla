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
3. `send` → `event_loop.watch_fd(fd, .readable, ...)` → `.suspend` — the
   worker keeps serving while the backend answers.
4. The continuation accumulates, `client.frame_response` frames (re-arming
   while incomplete), and the edge reply wraps the backend body without
   `${}`/`+`.

UDS is the mesh transport on purpose: ≈2.3–2.7× the throughput of TCP
loopback at ~half the CPU per request (the study), with filesystem
permissions as access control.

```sh
v run examples/mesh/src
curl http://localhost:8095/mesh
# {"via":"edge","backend":{"svc":"backend","msg":"hello from the mesh"}}
```
