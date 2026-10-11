# websocket_chat — one room, many workers, server push

Every client that connects to `/chat?name=<you>` joins one room, and a text
message from any of them reaches all of them, whichever worker thread each
connection lives on. It builds on [websocket_echo](../websocket_echo/)'s
upgrade-and-takeover, and adds server push: a connection can be woken by
other workers and by timers, not only by its own client.

One connection, three kinds of wake-up, and none of them parks it:

- **client frames** reach `chat_conn`, the takeover handler;
- **messages from other members**, posted by whichever worker handled the
  sender's frame, reach `chat_wake` on the receiver's own worker;
- **a keepalive timer** pings every interval and closes a peer that did not
  answer the previous ping.

## Run

```sh
v -prod run examples/websocket_chat/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) and needs Linux: push
and takeover run on the epoll worker only, and a build compiled with tcc (the
usual compiler without `-prod`) cannot take connections over, so `/chat`
answers `501 Not Implemented`. `CHAT_PING_MS` sets the keepalive interval in
milliseconds (default `25000`).

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 45
Connection: keep-alive

WebSocket chat: connect to /chat?name=<you>
```

`/chat` without the upgrade headers is a 400 and a closed connection.

**From a browser.** Open <http://localhost:3000/>, then paste into the
developer console:

```js
const ana = new WebSocket('ws://localhost:3000/chat?name=ana')
const bo = new WebSocket('ws://localhost:3000/chat?name=bo')
ana.onmessage = e => console.log('ana <-', e.data)
bo.onmessage = e => console.log('bo <-', e.data)
```

and once both are open, `ana.send('hi bo')`:

```
ana <- joined, worker 4
bo <- joined, worker 5
ana <- ana: hi bo
bo <- ana: hi bo
```

The first frame says which worker serves the connection; the sender gets the
room's copy of its own message too.

**From a terminal**, with [websocat](https://github.com/vi/websocat) (not
verified here): `websocat 'ws://localhost:3000/chat?name=ana'` in one
terminal, the same with `name=bo` in another, then type in either. `curl -T .
ws://…` does not work for this demo: curl sends binary frames, and the chat
only accepts text (it closes with 1003).

**Raw bytes** with socat: the handshake, then the masked text frame `hi`:

```sh
{ printf 'GET /chat?name=cy HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'
  sleep 0.3; printf '\x81\x82\x37\xfa\x21\x3d\x5f\x93'
  sleep 2.5; } | socat -t1 - TCP:localhost:3000 | od -A d -c
```

With the server started as `CHAT_PING_MS=1000 v -prod run examples/websocket_chat/src`,
after the 101 headers:

```
0000128  \n 201 020   j   o   i   n   e   d   ,       w   o   r   k   e
0000144   r       6 201 006   c   y   :       h   i 211  \0 210 002 003
0000160 351
```

The welcome frame (`joined, worker 6`), the room's copy `cy: hi`, a ping
(`211 \0`, sent after one second) and, since socat never answers it, a close
frame with code 1001 (`210 002 003 351`) one interval later.

## How it works

- **Upgrade, takeover, subscribe.** `handle` validates the handshake, calls
  `core.queue_takeover(chat_conn, st)` so frames go to `chat_conn`, then
  `event_loop.subscribe(chat_wake, st)`, which returns the connection's
  `core.ConnHandle`. If either fails it answers 501. It joins the room, arms
  the first `event_loop.wake_after(ping_ms)`, and appends the 101 plus a
  welcome frame in the same buffer.
- **Per-connection state.** A heap `Chat` (id, handle, name copied from the
  query by `query_name`, the `pinging` flag) is both the takeover state and
  the subscription state. It is freed when `chat_wake` runs with `.closed`,
  which happens once however the connection ends.
- **Per-worker state, shared room.** `make_state` gives each worker a `Worker`
  holding a pointer to the one `Room`, the ping interval, a worker id and a
  `post` scratch buffer ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
  The room is the only shared mutable state, behind a `sync.Mutex`, taken
  once per join, leave and sent message, never per delivery or per ping.
- **Broadcast by post.** `chat_conn` builds `name: text` in the worker's
  `post` buffer (cut to `max_post`, 240 bytes, to fit a mailbox slot) and
  `Room.broadcast` calls `post_bytes` on every member's handle. Each receiver's
  `chat_wake` sees `.posted` and frames `event_loop.post_data()` as a text
  frame. A full mailbox drops the message for that member; a real app would
  keep a backlog and post a tag. A handle carries its connection's
  generation, so a post to a member who just left is dropped, never delivered
  to a new connection that reuses the fd.
- **Keepalive.** On `.timeout`, `chat_wake` sends a ping and re-arms the timer;
  if the previous ping is still unanswered it sends close 1001 instead. A
  `pong` in `chat_conn` clears `pinging`. On `.shutdown` it sends 1001 too.
- **Frames as in websocket_echo.** Unmasked or malformed frames get 1002;
  fragmented, binary and other opcodes get 1003; client pings get pongs.

## Tests

```sh
v -cc gcc test examples/websocket_chat/src
```

[main_test.v](src/main_test.v) checks the routes and upgrade 400s, `query_name`
and the frames `chat_wake` produces (a post, a ping, the 1001 after an
unanswered ping, shutdown). [server_end_to_end_test.v](src/server_end_to_end_test.v)
starts real servers with raw WebSocket clients: two members on different
workers chatting both ways, a member that leaves dropped from the room while
later joiners get later messages, and the keepalive closing a silent peer
while a peer that answers pings stays. The end-to-end tests skip under tcc,
so plain `v test` passes without exercising them.

## See also

- [examples/websocket_echo](../websocket_echo/) — the upgrade and frame handling on its own
- [examples/sse](../sse/), [examples/async_sse](../async_sse/) — one-way server push over HTTP
- [websocket/websocket.v](../../websocket/websocket.v) — the frame codec
- [core/conn_handle.v](../../core/conn_handle.v) — `ConnHandle`, `subscribe`, `post_bytes`, `wake_after`
