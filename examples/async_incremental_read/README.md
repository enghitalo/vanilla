# async_incremental_read — stream a slow fd as it produces

`/stream` starts a child process that prints five lines 200 ms apart, watches
its pipe, and forwards whatever bytes are there as one HTTP chunk each time
the pipe becomes readable. The worker never blocks while the producer sleeps.
This is the shape of a reverse proxy or `tail -f`: read what is available,
send it, wait for more.

epoll only watches pollable fds (pipes, sockets), not regular files: a file
always reads as ready, so streaming one needs no watch at all. A pipe is the
case where the bytes really arrive over time.

## Run

```sh
v -prod run examples/async_incremental_read
```

It listens on `:8093` (fixed in [main.v](main.v)) with the epoll backend, so
it is Linux-only; the producer is a `sh` loop started with `popen`. Any other
path gets `404 Not Found`.

```sh
time curl -i -N localhost:8093/stream
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
Connection: keep-alive

line 1
line 2
line 3
line 4
line 5

real	0m1.016s
```

The lines arrive as the producer writes them (timestamps added by the shell,
in seconds):

```
55.624 line 1
55.825 line 2
56.027 line 3
56.229 line 4
56.430 line 5
```

`curl -s --raw localhost:8093/stream | od -c` shows one chunk per read, then
the zero-size chunk:

```
0000000   7  \r  \n   l   i   n   e       1  \n  \r  \n   7  \r  \n   l
…
0000060   7  \r  \n   l   i   n   e       5  \n  \r  \n   0  \r  \n  \r
0000100  \n
```

## How it works

- **Start the producer, send the head, park.** `handle` runs `popen` on the
  shell loop, sets the pipe's fd `O_NONBLOCK` (so `read` returns `EAGAIN`
  instead of blocking), appends the `chunk_headers` const and calls
  `event_loop.watch_fd(fd, .readable, on_chunk, fp)`, passing the `FILE*` as
  the `watch_payload` so the continuation can `pclose` it. It returns
  `.suspend`, which flushes the head. If `popen` fails it answers 404.
- **One chunk per readiness.** `on_chunk` reads up to 4096 bytes into a stack
  buffer. With data, it appends the size in hex (`wx`), CRLF, the bytes
  (`push_many`) and CRLF, re-watches the same fd and returns `.suspend`: the
  chunk goes out now, and the worker waits for the next line.
- **End of stream.** A read of 0 is EOF: it appends `last_chunk`
  (`0\r\n\r\n`, RFC 9112 §7.1), `pclose`s the stream (which also closes the
  fd and reaps the child) and returns `.done`; the connection stays open for
  the next request. `EAGAIN` re-arms the watch; any other read error
  `pclose`s and returns `.close`.
- Chunk framing is built by appending into `out`; the head, 404 and
  terminator are consts
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/async_incremental_read
```

[main_test.v](main_test.v) checks `wx` against known chunk sizes, then drives
a live server through [vtest](../../docs/VTEST.md): the stream decodes
strictly (every hex size matches its data) to the five lines, ends with the
zero-size chunk, and the same keep-alive connection then answers a 404.
`/streams` and `/x?stream` get the 404, and a malformed request gets the 400
and a closed connection.

## See also

- [examples/async_sse](../async_sse/) — the same chunk-per-suspend streaming,
  driven by a timer
- [examples/async_pipe](../async_pipe/) — the minimal park/resume on a pipe
- [examples/chunked_streaming](../chunked_streaming/) — chunked responses
- [examples/https_upstream](../https_upstream/) — watching an upstream socket
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
