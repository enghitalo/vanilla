# request_limits — size caps and deadlines, enforced by the core

A server with no limits falls over: one huge body, one header flood, or ten
thousand connections that never finish a request is enough. A handler cannot
fix that after the fact, because by the time it runs the bytes are already
buffered. So vanilla enforces the limits in its read loop, and this example
only configures them through `ServerConfig.limits`; its handler is a plain
`200 OK`.

| `server.Limits` field | Value here | What happens |
|---|---|---|
| `max_body_bytes` | 10 MiB | `413 Payload Too Large`, decided from `Content-Length` before any body byte is read |
| `max_header_bytes` | 16 KiB | `431 Request Header Fields Too Large` |
| `max_connections` | 100,000 | connections past the cap are closed at accept |
| `read_timeout_ms` | 5 s | the whole request must arrive in time: `408` if part of it came, a silent close if nothing did |
| `write_timeout_ms` | 10 s | a response the peer will not drain is dropped |
| `idle_timeout_ms` | 30 s | an idle keep-alive connection is closed silently |

## Run

```sh
v -prod run examples/request_limits/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)).

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive
```

**Oversized body.** The declared length alone is enough; curl, which waits
for `100 Continue` on a large upload, sends none of its 11 MB:

```sh
head -c 11000000 /dev/zero > big.bin
curl -i -X POST localhost:3000/upload --data-binary @big.bin -w '\n[curl: %{http_code}, sent %{size_upload} bytes]\n'
```

```
HTTP/1.1 413 Payload Too Large
Content-Length: 0
Connection: close


[curl: 413, sent 0 bytes]
```

**Header flood.** One 20 KB header:

```sh
curl -i localhost:3000/ -H "X-Big: $(head -c 20000 /dev/zero | tr '\0' a)"
```

```
HTTP/1.1 431 Request Header Fields Too Large
Content-Length: 0
Connection: close
```

**Slowloris.** Send half a request and stall. The read deadline does not
move on progress, so the server answers 408 and closes 5 s after accept
(socat then exits after its own 0.5 s grace):

```sh
(printf 'GET / HTTP/1.1\r\nHost: x\r\n'; sleep 10) | (time socat - TCP:localhost:3000)
```

```
HTTP/1.1 408 Request Timeout
Content-Length: 0
Connection: close


real	0m5.529s
```

**Silent connection.** Connect and send nothing: the same deadline, armed at
accept, closes it with no response.

```sh
sleep 10 | (time socat - TCP:localhost:3000)
```

```
real	0m5.530s
```

**Idle keep-alive.** After a response, a peer that goes quiet is closed 30 s
later, silently:

```sh
(printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'; sleep 40) | (time socat - TCP:localhost:3000)
```

```
HTTP/1.1 200 OK
Content-Length: 0
Connection: keep-alive


real	0m30.653s
```

Deadlines are checked by a per-worker sweep every
`Limits.sweep_interval_ms()` (a quarter of the shortest timeout, clamped to
25-250 ms; 250 ms here), so a connection closes at most one interval after
its deadline.

## How it works

- **Limits live in the core.** `max_body_bytes` is checked against the
  declared `Content-Length` (and bounds a chunked body too), so the server
  never buffers an over-limit body. `max_header_bytes` stops reading a header
  block at the limit.
- **Always pair `max_connections` with a timeout.** The cap counts open
  connections, at accept, with no per-request cost. A connection that never
  sends a byte, or a keep-alive peer that vanished without a FIN, keeps its
  slot until a deadline reaps it; without `read_timeout_ms` /
  `idle_timeout_ms`, enough of them lock every new client out.
- **The read deadline is not refreshed by progress**: a peer dribbling one
  byte at a time is still reaped. The first request's clock starts at accept;
  later ones at their first byte. Size it for your largest upload.
- **`idle_timeout_ms`**: `0` inherits `read_timeout_ms`, `-1` disables it
  (for a handler that hands its fd to another thread to stream, see
  [examples/video_stream](../video_stream/)).
- **Free when off.** Every field defaults to `0` (unlimited); with no timeout
  set there are no clock reads and no sweep. The kqueue (macOS) backend does
  not yet enforce `max_connections` or the timeouts.
- The handler appends a `'...'.bytes()` literal with `out <<`; a `const`
  string with `core.append_str` is the allocation-free form
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/request_limits/src
```

[main_test.v](src/main_test.v) checks that the handler is a trivial 200,
then drives each limit end to end against a real server through `vtest`:
slowloris reaped by the read deadline (never a 200), a silent connection
closed without a 408, idle keep-alive reaped (inherited and explicit
`idle_timeout_ms`), `max_connections` slots freed by reaping so the next
client is served, a header flood ended with 431, and a 413 from the declared
length before any body byte is sent.

## See also

- [examples/rate_limit](../rate_limit/) — bound how often a client may ask
- [examples/ip_block](../ip_block/), [examples/proxy_aware](../proxy_aware/) — decide who may ask at all
- [examples/async_time_limit](../async_time_limit/) — a time budget for multi-step async work
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
- [docs/VTEST.md](../../docs/VTEST.md) — the harness the tests use
