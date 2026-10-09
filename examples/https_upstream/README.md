# https_upstream — call a third-party HTTPS API from a handler

A handler that calls an HTTP API (a payment gateway, a video provider, a
notification service) spends tens to hundreds of milliseconds waiting on the
network. Done with a blocking client, that stalls every connection on the
worker. `http1_1.upstream` (#229) does it the way `pg_async` does PostgreSQL:
a per-worker pool of keep-alive connections, parked on the worker's reactor.

This example is an edge server that relays `<METHOD> /up/<path>` to
`<METHOD> /<path>` on one upstream origin and answers with its status and body:

```sh
UPSTREAM_HOST=api.github.com v -d vanilla_tls run examples/https_upstream/src
curl -i http://localhost:8096/up/zen
```

(`UPSTREAM_PORT`, `UPSTREAM_HTTPS=0` for plain HTTP, `UPSTREAM_CA` for a
private CA; the system bundle otherwise.)

## The shape

```v
// make_state: one pool per origin per worker (no locks: the worker owns it).
// The TLS config is built once, before new_server, and shared read-only.
pay := upstream.Pool.new(upstream.Origin{ host: 'api.example.com' }, tls_cfg)!

// on_worker_start: deadlines, idle and lifetime expiry, the liveness probe.
pay.start_maintenance(mut el)!

// The handler: acquire (none = shed with 503), build, send, suspend.
mut x := st.pay.acquire() or { out << resp_503; return .done }
x.request('POST', '/v1/charges')
x.header('Idempotency-Key', key)
x.retryable(true) // safe to send twice: the key makes it so
mut b := x.body()
b << ... // the JSON, appended in place
if x.send(mut el, on_charge, unsafe { nil }) == .pending {
    return .suspend
}
x.release()
out << resp_502
return .done

// The continuation: advance until .ready or .failed, answer, release.
mut x := st.pay.exchange_of(ready_fd) or { ... }
match x.advance(ready_fd_error, mut el, on_charge, payload) {
    .pending { return .suspend }
    .failed { /* x.failure(): .timeout → 504, the rest → 502 */ }
    .ready { /* x.status(), x.header_value('content-type'), x.body_view() */ }
}
x.release()
return .done
```

## What the pool does for you

- **Dialing:** each origin's addresses (IPv4 and IPv6) are tried in turn with
  `transport.dial_addr` (non-blocking, close-on-exec, `TCP_NODELAY`, keepalive,
  `TCP_USER_TIMEOUT`); the one that answers is tried first next time.
- **TLS:** TLS 1.3, verify-full + SNI with `tls.Verify.full`; each slot keeps
  its own Mbed TLS session and re-arms it on a re-dial (no allocation). A body
  delimited by the connection close is complete only after `close_notify`; a
  bare FIN is `.truncated`.
- **Framing:** `client.Framer` frames as bytes arrive (each recv costs only
  the new bytes): Content-Length, chunked with trailers, `100 Continue` then
  the final response, HEAD, 204/304, close-delimited bodies. Chunked bodies
  are de-chunked in place: the body is one view.
- **Reuse:** a connection goes back to the pool only when HTTP allows it (no
  `Connection: close`, not HTTP/1.0 without keep-alive, not close-delimited,
  nothing left over) and it is younger than `max_lifetime_ms`. A kept
  connection is probed before reuse, so one the upstream closed while idle
  costs a re-dial, not a 502.
- **Retry:** an idempotent request (or one marked `retryable`) whose kept
  connection died before any response byte is sent once more on a fresh
  connection, within the original deadline. A plain POST is never sent twice.
- **Early answers:** an upstream that answers (a 413) before reading the whole
  request body stops the upload; the answer is relayed, the connection dropped.
- **Deadlines:** `connect_timeout_ms` (TCP + TLS) and `response_timeout_ms`,
  enforced by the maintenance timer until parked requests get their own
  deadline in the runtime (#200): it shuts the socket down, the parked watch
  wakes, and `advance()` reports `.timeout` (504). The late reply can never
  reach another exchange: the connection is closed.
- **Limits:** `max_conns` per worker (then `acquire()` sheds: 503),
  `max_request_bytes`, `max_response_bytes` (`.too_large`).
- **DNS:** resolved once at startup (a typo fails fast); a `Resolver` thread
  re-resolves every interval (and at once when every address fails) and hands
  the answer to each worker over a pipe — no `getaddrinfo`, no lock and no
  shared mutable state on a worker.
- **No allocation per exchange** once the slot buffers reached their
  high-water mark (checked under `-gc none`).

## Platform

The Linux epoll plaintext worker: it parks requests and runs
`on_worker_start`. Terminate TLS in front of vanilla (a load balancer), or use
the epoll plain worker behind it, as with `pg_async`.

## Tests

`src/upstream_e2e_test.v` drives the edge against `fake_upstream/`, a
scriptable fake API in V that the test builds and runs as its own process
(with `-d vanilla_tls` it serves TLS 1.3 through vanilla's own `tls` server
side, with a throwaway test CA from `pg_async/testdata/gen_test_ca.sh`, which
needs openssl):

```sh
v test examples/https_upstream/src                         # plain HTTP
v -d vanilla_tls test examples/https_upstream/src          # + HTTPS
v -gc none -d vanilla_tls test examples/https_upstream/src # + the allocation check
```
