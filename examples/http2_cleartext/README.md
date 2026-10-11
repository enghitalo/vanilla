# http2_cleartext — HTTP/2 and HTTP/1.1 on one port, one handler

HTTP/2 over plain TCP with prior knowledge
([RFC 9113 §3.3](https://www.rfc-editor.org/rfc/rfc9113#section-3.3)): the
client opens with the HTTP/2 connection preface instead of an HTTP/1.1
request. The same port keeps serving HTTP/1.1, and every request, whichever
protocol it arrived on, is answered by the same `handle` function.

It is the second user of the core's takeover seam, after
[websocket_echo](../websocket_echo/). The first 18 bytes of the preface,
`PRI * HTTP/2.0\r\n\r\n`, parse as an HTTP/1.1 request, so they reach
`handle`, which flips the connection to the [http2](../../http2/) module's
`ServerConn` and answers with the server's SETTINGS frame. A bridge then
translates each HTTP/2 request into HTTP/1.1 bytes, calls `handle`, and
re-frames the HTTP/1.1 response as HEADERS + DATA frames. The HTTP/1.1 path
is untouched.

## Run

```sh
v -prod run examples/http2_cleartext/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) and needs Linux: only
the epoll worker can take a connection over. Elsewhere, and in a build
compiled with tcc (the usual compiler without `-prod`), the preface gets
`501 Not Implemented`. The client needs HTTP/2 support (`curl -V` lists
`HTTP2`).

| Route | Answer |
|---|---|
| `GET /` | `hello over one handler` |
| `POST /echo` | the request body |
| `GET /slow` | `slow done`, after a 30 ms timer (an async route) |
| anything else | 404 |

```sh
curl -i --http2-prior-knowledge http://localhost:3000/
```

```
HTTP/2 200
content-type: text/plain
content-length: 23

hello over one handler
```

```sh
curl -i --http2-prior-knowledge -d 'ping' http://localhost:3000/echo
```

```
HTTP/2 200
content-type: application/octet-stream
content-length: 4

ping
```

The async route parks the stream on a timerfd and resumes it when the timer
fires:

```sh
curl -i --http2-prior-knowledge -w 'time_total=%{time_total}\n' http://localhost:3000/slow
```

```
HTTP/2 200
content-type: text/plain
content-length: 10

slow done
time_total=0.030580
```

The same routes over HTTP/1.1 on the same port:

```sh
curl -i http://localhost:3000/slow
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 10
Connection: keep-alive

slow done
```

There is no `Upgrade: h2c` handshake: `curl --http2` (which tries that
upgrade) gets a plain HTTP/1.1 answer. A request with a version other than
`HTTP/1.0`/`HTTP/1.1` that is not the preface (`GET / HTTP/2.0`, say) gets a
GOAWAY frame with `PROTOCOL_ERROR`, then the connection closes.

## How it works

- **Preface, then takeover.** `handle` spots `PRI *`, allocates a
  `BridgeState` holding `http2.new_server_conn()`, and calls
  `core.queue_takeover(http2_takeover_conn, bridge)` before writing anything.
  If that fails it answers `cannot_takeover_response` (501); otherwise it
  appends the server preface with `write_server_preface`. The `SM\r\n\r\n`
  tail of the client preface, already in the read buffer, goes to the
  takeover handler.
- **`http2_takeover_conn`** (a `core.ConnHandler`) runs `ServerConn.consume`,
  which handles SETTINGS, PING and WINDOW_UPDATE itself and returns complete
  requests. Each goes through `serve_http2_request`.
- **The bridge.** `serve_http2_request` writes an HTTP/1.1 request from the
  pseudo-headers and fields, dropping connection-specific ones
  (RFC 9113 §8.2.2), and calls `handle`. `frame_h1_response` parses the reply
  with the `http1_1/client` codec (`frame_response`, `status_code`,
  `head_len`, `body_bounds`), HPACK-encodes the status and lowercased fields
  (`append_response_fields`), and sends the body as a `vbytes` view in DATA
  frames. The request, response and header buffers live in `BridgeState` and
  are cleared and reused for every request on the connection. The HTTP/2
  decoding itself still allocates (header strings), a cost paid only on HTTP/2
  connections.
- **Async over both protocols.** `slow_route` arms a 30 ms timerfd with
  `event_loop.watch_fd` and returns `.suspend`
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
  Over HTTP/1.1 the engine parks the request. Over HTTP/2 the bridge passes a
  capture `EventLoop` whose `capture_register` records the watch instead of
  arming it; `bridge_park` re-arms it on the real loop with `bridge_wake` as
  the continuation, and `bridge_wake` re-frames the finished response for the
  stream that parked. The parked stream's state (its id, the app's
  continuation and payload, the response so far in `park_res`) lives in the
  connection's `BridgeState`, which is the watch payload: parking and resuming
  allocate nothing. Other streams keep being served meanwhile. One parked
  stream per connection: a second one is refused with `RST_STREAM`
  (`REFUSED_STREAM`) so the client retries.
- **Static parts are consts.** The HTTP/1.1 responses are `const`s; the echo
  head is framed with `core.append_str` and `write_int` (a `strconv.write_dec`
  into a stack scratch) ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v -cc gcc test examples/http2_cleartext/src
```

`-cc gcc` matters: under tcc the takeover is unavailable and the end-to-end
test fails on the 501. [main_test.v](src/main_test.v) runs without sockets:
the HTTP/1.1 routes, the GOAWAY for a non-HTTP/1.x version, the 501 when no
worker can take over, and the whole bridge driven as a bare `ConnHandler`
(GET, POST with a body, a peer GOAWAY that keeps the connection serving, a
stream that parks and resumes, a second parker refused with `RST_STREAM`, a
partial frame, and that parking and resuming allocate nothing). [server_end_to_end_test.v](src/server_end_to_end_test.v)
drives a real epoll server through `vtest`: the preface, requests and a PING
on one connection, HTTP/1.1 on another connection to the same port, and
`/slow` over both protocols, with `/` on another stream not waiting behind
the parked one.

CI also runs the [h2spec](https://github.com/summerwind/h2spec) conformance
suite against this server
([conformance_h2spec.yml](../../.github/workflows/conformance_h2spec.yml)).

## See also

- [examples/websocket_echo](../websocket_echo/) — the takeover seam with WebSocket
- [examples/async_timer](../async_timer/) — the timerfd park on its own
- [http2/](../../http2/) — frames, HPACK and the `ServerConn` state machine
