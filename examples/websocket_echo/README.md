# websocket_echo — HTTP/1.1 upgrade, then RFC 6455 frames on the same connection

One engine, two protocols on one connection. The HTTP handler answers
`GET /ws` with `101 Switching Protocols` and hands the connection over to a
second handler, `ws_echo_conn`, which from then on gets every readable burst
as raw WebSocket frames instead of HTTP requests. It echoes text and binary
messages, answers pings with pongs and completes the close handshake.

The hand-off is the core's takeover seam (`core.queue_takeover`), and the
frame codec is the [websocket](../../websocket/) module: pure functions over
bytes, no I/O. Both handlers stay pure, so both are unit-tested with raw bytes.

## Run

```sh
v -prod run examples/websocket_echo/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) and needs Linux: only
the epoll worker can take a connection over. On other backends, and in a
build compiled with tcc (V's default C compiler for non-`-prod` builds on
many systems), `/ws` answers `501 Not Implemented` instead of a 101 that
nothing would serve.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 47
Connection: keep-alive

WebSocket echo: connect a ws:// client to /ws
```

`GET /ws` without the upgrade headers is a 400 and a closed connection; any
other path or method is a 404. The handshake with plain curl (it stops at the
101, and `--max-time` ends it, exit code 28):

```sh
curl -i --max-time 1 -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  localhost:3000/ws
```

```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=

```

That accept value is the one RFC 6455 §1.3 gives for this sample key.

A curl built with WebSocket support (`curl -V` lists `ws`) can talk to it:
`-T .` sends each stdin line as a message and prints what comes back. curl
keeps the connection open, so `--max-time` ends it here:

```sh
printf 'hello over websocket\n' | curl -s --no-buffer --max-time 2 -T . ws://localhost:3000/ws
```

```
hello over websocket
```

The same exchange as raw bytes with socat: the handshake, the masked "Hello"
text frame from RFC 6455 §5.7, then a masked close frame with code 1000:

```sh
{ printf 'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'
  sleep 0.2; printf '\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58'
  sleep 0.2; printf '\x88\x82\x37\xfa\x21\x3d\x34\x12'
  sleep 0.3; } | socat -t1 - TCP:localhost:3000 | od -A d -c
```

```
0000000   H   T   T   P   /   1   .   1       1   0   1       S   w   i
…
0000112   G   z   z   h   Z   R   b   K   +   x   O   o   =  \r  \n  \r
0000128  \n 201 005   H   e   l   l   o 210 002 003 350
0000140
```

After the 101: `201 005 Hello` is the unmasked echo (`0x81`, length 5), and
`210 002 003 350` is the server's close frame (`0x88`, code 1000). The
server then closes the connection.

## How it works

- **Upgrade, then hand over.** `handle` checks `GET /ws`, the
  `Upgrade: websocket` value and a `Sec-WebSocket-Key` (each a `Slice`
  compared in place by `slice_eq`). It calls
  `core.queue_takeover(ws_echo_conn, unsafe { nil })` before writing the 101:
  if it returns false (not the epoll worker, or a tcc build) it sends
  `cannot_upgrade_response` (501) and closes. The demo does not check
  `Sec-WebSocket-Version`, and the `Upgrade` comparison is case-sensitive.
- **The 101 without formatting.** `switching_prefix` and `head_end` are
  `const` strings appended with `core.append_str`;
  `websocket.append_accept_key` writes the base64 accept value straight into
  the buffer from a `tos` view of the client key
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- **`ws_echo_conn` is a `core.ConnHandler`.** It walks complete frames with
  `websocket.frame_head`, unmasks each in place (`unmask_in_place`), and
  returns how many bytes it consumed. A partial frame (`websocket.incomplete`)
  is left unconsumed and the engine calls again when more bytes arrive.
- **Echo by view.** The payload is a `vbytes` window into the read buffer,
  appended after `write_frame_header`; pings get `write_pong` with the same
  payload, pongs are ignored, and a close gets `write_close(close_normal)` and
  `.close`.
- **Protocol errors close the connection.** A malformed or unmasked client
  frame (RFC 6455 §5.1) gets close 1002; a fragmented message (`fin` clear)
  gets 1003, because the demo echoes whole messages only.
- **Frames behind the upgrade request.** A client may send its first frame in
  the same segment as the handshake; the engine feeds those bytes to the
  takeover handler, not the HTTP parser (checked by the end-to-end test).

## Tests

```sh
v -cc gcc test examples/websocket_echo/src
```

`-cc gcc` matters: under tcc `queue_takeover` always returns false, so the
end-to-end test gets a 501 and fails. [main_test.v](src/main_test.v) calls
`handle` for the routes, the 400s for an incomplete handshake and the 501
when no worker can take over, and `ws_echo_conn` with raw frames: the RFC
"Hello" echo, two frames plus a partial tail in one burst, ping/pong, the
close handshake, an unmasked frame (1002), a partial frame and a fragmented
message (1003).
[server_end_to_end_test.v](src/server_end_to_end_test.v) drives a real epoll
server through `vtest`: handshake, echo, ping, close and EOF; a frame
pipelined in the same write as the upgrade request; and an unmasked frame
ending the connection.

## See also

- [examples/websocket_chat](../websocket_chat/) — server push to many clients over the same seam
- [examples/http2_cleartext](../http2_cleartext/) — another protocol on the takeover seam
- [websocket/websocket.v](../../websocket/websocket.v) — the frame codec
- [BEST_PRACTICES §2 — zero-copy views](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)
