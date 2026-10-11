# ip_block — deny listed client addresses with 403

A denylist of IP addresses checked on every request against the connection's
**socket peer** (`socket.peer_ipv4(client_fd)`), never against a header the
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

Nothing is logged per denial: a blocked client could otherwise force a stderr
write on every request it sends. Count denials, or log once per connection,
if you need them.

## How it works

- **The peer, not a header.** `handle` takes `socket.peer_ipv4(client_fd)`,
  the peer's IPv4 address as a `u32` (one `getpeername` syscall, no
  allocation), and checks it against the list. A peer with no IPv4 address
  (a Unix-socket listener; there use `socket.peer_cred`) is on no list: it is
  allowed. It does not even parse the request: the decision needs only the
  connection. Behind a proxy or CDN the peer is the proxy, so swap in the
  trusted-proxy client IP from [examples/proxy_aware](../proxy_aware/).
- **One shared, read-mostly list.** `Blocklist` is a `map[u32]bool` behind a
  `sync.RwMutex`. `block` and `unblock` take dotted-quad text, parse it once
  (`parse_ipv4`) and refuse what is not IPv4. `is_blocked` takes the read
  lock, so workers check in parallel; `block` and `unblock` take the write
  lock and can run at any time, from any thread
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
round trip and the refusal of text that is not IPv4, allows a peer with no
IPv4 address (fd `-1`), and drives `handle` over a real loopback connection:
a listed `127.0.0.1` gets the 403, an unlisted one the 200, and neither
allocates.

## See also

- [examples/proxy_aware](../proxy_aware/) — find the real client behind a trusted proxy
- [examples/rate_limit](../rate_limit/) — throttle instead of deny, on the same identity rule
- [examples/request_limits](../request_limits/) — connection caps and timeouts in the core
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
