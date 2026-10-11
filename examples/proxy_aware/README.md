# proxy_aware — find the real client behind a proxy you trust

Behind a CDN, load balancer or nginx, the TCP peer is the proxy, not the user;
the user's address arrives in `X-Forwarded-For`. That header is
client-settable, so believing it blindly lets anyone forge their IP, slip past
an IP allowlist or poison a rate limiter. The rule this example implements:

1. Honor `X-Forwarded-For` **only** when the socket peer is in your list of
   trusted proxy networks.
2. Then take the **right-most** hop that is not one of your proxies. Proxies
   append to the header, so everything to the right was written by your own
   infrastructure; the client can only pre-seed the left.
3. Otherwise ignore the header and use the socket peer.

The handler answers with the address and scheme it settled on, as JSON.

## Run

```sh
v -prod run examples/proxy_aware/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). The trusted networks
are the `trusted_proxies` const: `10.0.0.0/8`, `172.16.0.0/12` and
`127.0.0.1/32`. Since `127.0.0.1` is on the list, curl from localhost plays
the part of your own proxy.

No header: the peer is the client.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 41

{"client_ip":"127.0.0.1","scheme":"http"}
```

From the trusted peer, the forwarded address is believed:

```sh
curl -i localhost:3000/ -H 'X-Forwarded-For: 203.0.113.7'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 43

{"client_ip":"203.0.113.7","scheme":"http"}
```

A client-forged left hop and a trusted proxy on the right: the right-most
untrusted hop wins.

```sh
curl -s localhost:3000/ -H 'X-Forwarded-For: 1.2.3.4, 203.0.113.7, 10.0.0.2' \
  -H 'X-Forwarded-Proto: https'
```

```
{"client_ip":"203.0.113.7","scheme":"https"}
```

If every hop is trusted (`X-Forwarded-For: 10.1.2.3, 172.20.0.9`), the
left-most is the closest thing to a client: `{"client_ip":"10.1.2.3",...}`.

From a peer that is **not** trusted the header is ignored. On Linux all of
`127.0.0.0/8` is local, so binding curl to `127.0.0.2` makes an untrusted
peer:

```sh
curl -i --interface 127.0.0.2 localhost:3000/ -H 'X-Forwarded-For: 203.0.113.7'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 41

{"client_ip":"127.0.0.2","scheme":"http"}
```

## How it works

- **The peer comes from the socket.** `handle` calls
  `socket.peer_ipv4(client_fd)`, the peer's IPv4 address as a `u32` (one
  `getpeername` syscall, no allocation), and passes it to `real_client_ip`. That function takes the peer as a parameter, so the
  tests drive every branch with injected peers.
- **CIDRs parsed once.** `parse_cidrs` turns `trusted_proxies` into
  pre-masked `Cidr` pairs at module init; per request, `ip_in_cidrs` is a
  mask-and-compare on the `u32`. Real masking gets ranges
  right: `10.1.2.3` is inside `10.0.0.0/8`, and `172.16.0.0/12` spans up to
  `172.31.255.255`. A hop that is not an IPv4 address never matches a trusted
  network.
- **Header scanned from the right, in place.** `real_client_ip` walks the
  `X-Forwarded-For` bytes backwards by offsets, splits on commas, trims spaces
  and tabs, skips empty hops, and `parse_ipv4` turns each hop, read through a
  `tos` view of the request buffer, into a `u32`
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
  It is IPv4 only: a right-most untrusted hop that is not IPv4 (an IPv6
  client, `unknown`) cannot be reported, and every hop left of it is
  client-written, so the answer is the proxy itself. A peer with no IPv4
  address (a `getpeername` failure, a Unix-socket listener) is untrusted and
  reported as `unknown`.
- **Framed once, straight into `out`.** Content-Length is `body_overhead`
  plus the lengths of the two dynamic fields (`ipv4_len` for the address),
  written by `wi`; then the `body_pre`/`body_mid`/`body_tail` consts and the
  two values are appended, the address printed by `write_ipv4` (four `wi`
  calls), with no allocation
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- **`X-Forwarded-Proto` is echoed as sent**, from any peer, to show the read
  (default `http`). It is client-settable like `X-Forwarded-For`: in
  production gate it on the same peer trust, and never reflect either value
  into a response without encoding it.
- [examples/rate_limit](../rate_limit/) copies this trust rule verbatim to
  key its buckets; there `trusted_proxies` starts empty.

## Tests

```sh
v test examples/proxy_aware/src
```

[main_test.v](src/main_test.v) covers `parse_ipv4` (valid and malformed),
CIDR membership at range edges, and `real_client_ip` with injected peers:
right-most untrusted hop, all hops trusted, empty hops, whitespace-only
header, a trusted peer without the header, a non-IPv4 client hop, an
untrusted peer and the unknown peer, and `write_ipv4` against `ipv4_len`.
Through `handle` (fd `-1`, so the peer is unknown, and a real loopback
connection) it checks the exact response bytes, the default scheme, that a
malformed request gets no response, and that serving allocates nothing.

## See also

- [examples/rate_limit](../rate_limit/) — the same rule picks the rate-limit key
- [examples/ip_block](../ip_block/) — block by peer; swap in this client IP behind a proxy
- [examples/request_limits](../request_limits/) — size and time limits enforced by the core
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
