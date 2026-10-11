# rate_limit — a token bucket per client, keyed on who really connected

Each client gets a bucket that holds up to 20 tokens and refills at 10 per
second; every request spends one, and an empty bucket answers
`429 Too Many Requests` with `Retry-After`. A token bucket allows short bursts
while bounding the sustained rate, which is what an API usually wants.

The algorithm is the easy part. The hard part is **identity**: the key must
not be something the client chooses. `X-Forwarded-For` is a request header,
so a limiter keyed on it never limits (a new value per request is a new
bucket). Here the key is the socket peer address, and `X-Forwarded-For` is
consulted only when that peer is a proxy you list in `trusted_proxies`.

## Run

```sh
v -prod run examples/rate_limit/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)); every path is the same
limited resource. The limits (`rate: 10.0`, `capacity: 20.0`) are set in
`main()`.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
RateLimit-Remaining: 19
Content-Length: 11

{"ok":true}
```

Spend the burst:

```sh
for i in $(seq 25); do curl -s -o /dev/null -w '%{http_code} ' localhost:3000/; done; echo
```

```
200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 429 429 429 429 429
```

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 429 Too Many Requests
Retry-After: 1
RateLimit-Limit: 10
RateLimit-Remaining: 0
Content-Length: 0
```

Forging `X-Forwarded-For` does not buy a fresh bucket, because the peer
(`127.0.0.1`) is not a trusted proxy:

```sh
for i in $(seq 5); do curl -s -o /dev/null -w '%{http_code} ' -H "X-Forwarded-For: 10.0.0.$i" localhost:3000/; done; echo
```

```
429 429 429 429 429
```

After one second about ten tokens are back:

```sh
sleep 1; for i in $(seq 12); do curl -s -o /dev/null -w '%{http_code} ' localhost:3000/; done; echo
```

```
200 200 200 200 200 200 200 200 200 200 200 429
```

## How it works

- **Token bucket with lazy refill.** `Limiter.allow(client, now)` tops the
  bucket up by `elapsed * rate` (capped at `capacity`), then spends a token.
  The clock is a parameter: `handle` passes the monotonic
  `time.sys_mono_now()`, the tests pass a fake one.
- **The key is the socket peer.** `client_key` takes
  `socket.peer_addr(client_fd)`. If the peer is not inside `trusted_cidrs`,
  the header is ignored. If it is (your load balancer), the key is the
  **right-most** `X-Forwarded-For` hop that is not one of your proxies:
  proxies append, so only the left side is client-written. The hops are
  scanned from the right in place and returned as a `tos` view; the map
  clones the key on insert, so the view is never retained. An empty peer
  (Windows, or a `getpeername` failure) becomes one shared `'unknown'` bucket.
  This is the same rule as [examples/proxy_aware](../proxy_aware/).
- **`trusted_proxies` is empty by default**, so nothing is trusted until you
  list your own proxies as CIDRs (e.g. `'127.0.0.1/32'` for nginx on the same
  host). `parse_cidrs` turns them into masks once at init.
- **Bounded state.** A bucket that has refilled to capacity is identical to a
  new one, so `sweep` drops those at most once per refill period. On top of
  that `max_buckets` (100,000) caps the table and fails **closed**: a new
  client gets `429` while the table is full.
- **One limiter for all workers.** The handler is a closure over a single
  `&Limiter`, so its map is guarded by a `sync.Mutex`
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **Responses.** The 429 is a `const`; the 200 is `response_200_prefix`, the
  remaining count written by `wi` (`strconv.write_dec` into a stack scratch),
  and `response_200_tail`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  `socket.peer_addr` is the deliberate exception to zero allocation: one
  syscall and one small string per request.

## Tests

```sh
v test examples/rate_limit/src
```

[main_test.v](src/main_test.v) drives `allow` with an injected clock (burst
then deny, exact refill, per-client isolation), checks that the sweep only
drops full buckets and never changes a decision, that the table cap fails
closed, and the identity rules (empty default trust list, `X-Forwarded-For`
ignored from untrusted peers, right-most untrusted hop behind a trusted proxy,
edge cases); `handle` is fed raw requests for the exact 200 framing and the
const 429. [server_end_to_end_test.v](src/server_end_to_end_test.v) (Linux)
sends ten requests with a different forged header each over a real socket:
three pass, seven get 429, and only one bucket (`127.0.0.1`) exists.

## See also

- [examples/proxy_aware](../proxy_aware/) — the trusted-proxy rule this limiter keys on
- [examples/ip_block](../ip_block/) — deny listed addresses outright
- [examples/request_limits](../request_limits/) — bound the size and time of each request
- [examples/auth](../auth/) — logins are the classic route to rate-limit
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
