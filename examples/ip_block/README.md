# ip_block — deny listed client addresses with 403

A denylist of IP addresses checked on every request against the connection's
**socket peer** (`socket.peer_addr(client_fd)`), never against a header the
client can write. A listed address gets `403 Forbidden`; everyone else gets
the resource.

It is application-level blocking: simple, and enough when the server faces
clients directly. For large lists or CIDR ranges use a prefix tree, and for a
real firewall drop the traffic in the kernel (nftables/iptables) before it
costs an accept and a `getpeername` per request.

## Run

```sh
v -prod run examples/ip_block/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). `main()` blocks
`10.0.0.5` and `192.168.1.100`; load the list from a file, database or
environment in a real app.

From an address that is not on the list (here localhost):

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 7
Connection: keep-alive

allowed
```

A forged `X-Forwarded-For: 10.0.0.5` changes nothing: the decision uses the
socket peer only.

To see the deny path from your own machine, add
`blocklist.block('127.0.0.1')` next to the other two in `main()` and rerun:

```
HTTP/1.1 403 Forbidden
Content-Length: 0
Connection: close
```

and the server logs `[ip-block] denied 127.0.0.1` on stderr.

## How it works

- **The peer, not a header.** `handle` takes `socket.peer_addr(client_fd)`
  (one `getpeername` syscall and one small string per request) and checks it
  against the list. It does not even parse the request: the decision needs
  only the connection. Behind a proxy or CDN the peer is the proxy, so swap in
  the trusted-proxy client IP from [examples/proxy_aware](../proxy_aware/).
- **One shared, read-mostly list.** `Blocklist` is a `map[string]bool`
  behind a `sync.RwMutex`: `is_blocked` takes the read lock, so workers check
  in parallel; `block` and `unblock` take the write lock and can run at any
  time, from any thread
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
  The handler reaches it as a closure capture in `main()`.
- **Const responses.** `forbidden_response` and `ok_response` are `const`
  strings appended with `core.append_str`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **The cheapest block is at accept**, before any request bytes are read;
  that needs an accept hook in the core. This example answers per request.

## Tests

```sh
v test examples/ip_block/src
```

[main_test.v](src/main_test.v) covers the `block`/`unblock`/`is_blocked`
round trip and drives `handle` with fd `-1` (whose peer is `''`): unlisted it
gets the 200, and with `''` blocked it gets the 403. The real peer address is
exercised with curl as above.

## See also

- [examples/proxy_aware](../proxy_aware/) — find the real client behind a trusted proxy
- [examples/rate_limit](../rate_limit/) — throttle instead of deny, on the same identity rule
- [examples/request_limits](../request_limits/) — connection caps and timeouts in the core
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
