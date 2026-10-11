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
it is Linux-only; the producer is a `sh` loop started with `posix_spawn`
([producer.c](producer.c)). Any other path gets `404 Not Found`, and
`/stream` gets `503 Service Unavailable` when its producer cannot be started.

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

- **Start the producer, send the head, park.** `handle` calls
  `spawn_producer` ([producer.c](producer.c)): `posix_spawn` runs
  `/bin/sh -c` on the loop with its stdout on a new pipe, and only the pipe's
  read end comes back. Both ends are close-on-exec, so no child keeps a copy
  past exec (the producer's stdout is a `dup2` of the write end), and only
  the read end is `O_NONBLOCK` (`read` returns `EAGAIN` instead of blocking;
  the producer's stdout stays blocking). `handle` appends the
  `chunk_headers` const, calls
  `event_loop.watch_fd(fd, .readable, on_chunk, unsafe { nil })` and returns
  `.suspend`, which flushes the head. If the pipe or the spawn fails (no fd
  or no process left), it answers 503. A spawn per request is not free:
  glibc allocates the file actions' list and maps a stack for the child.
- **One chunk per readiness.** `on_chunk` reserves room in `out` and reads up
  to 4096 bytes straight into its spare capacity, leaving space for the
  chunk-size line in front. With data, it appends the size in hex (`wx`) and
  CRLF, slides the bytes down behind them, appends CRLF, re-watches the same
  fd and returns `.suspend`: the chunk goes out now, and the worker waits for
  the next line. No scratch buffer is zeroed and copied on every wake.
- **End of stream.** A read of 0 is EOF, the producer has exited: it
  appends `last_chunk` (`0\r\n\r\n`, RFC 9112 §7.1), closes the read end and
  returns `.done`; the connection stays open for the next request. `EAGAIN`
  re-arms the watch; any other read error closes the fd and returns
  `.close`.
- **Nothing left behind
  ([#292](https://github.com/enghitalo/vanilla/issues/292)).** The pipe is
  request-owned: when a client disconnects mid-stream, the runtime closes it
  and never runs `on_chunk` again, and the producer dies of `SIGPIPE` on its
  next write. `spawn_producer` gives the child `SIGPIPE` (which `new_server`
  ignores process-wide) and `SIGCHLD` back at their default actions. Nobody
  waits for a producer: `main` first calls `ignore_sigchld`, which sets
  `SIGCHLD` to `SIG_IGN`, and the kernel reaps the children of a process
  that ignores it, so none becomes a zombie. The setting is process-wide (no
  code in the process can collect a child's exit status), fine here, where
  the producers are the only children. With `popen`, every dropped stream
  left a zombie `sh` and its `FILE`, which only `pclose` releases.
- Chunk framing is built by appending into `out`; the head, 404, 503 and
  terminator are consts
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## Tests

```sh
v test examples/async_incremental_read
```

[main_test.v](main_test.v) checks `wx` against known chunk sizes. With the
fd limit lowered so that no pipe can open, `handle` answers `/stream` with
the 503 and watches nothing; `spawn_producer` with a shell that does not
exist returns -1 and leaves no fd open; and a probe started through
`spawn_producer` prints its own `SigIgn` mask, which shows `SIGPIPE` and
`SIGCHLD` at their defaults while the test process ignores both. It drives
`on_chunk` directly over a pipe: byte-exact chunks behind bytes already in
`out`, a 5000-byte write split into a 4 KiB chunk and the rest, and a wake
that finds nothing (`EAGAIN`) appending nothing and re-arming. It then drives
a live server through [vtest](../../docs/VTEST.md): the stream decodes
strictly (every hex size matches its data) to the five lines, ends with the
zero-size chunk, and the same keep-alive connection then answers a 404.
`/streams` and `/x?stream` get the 404, and a malformed request gets the 400
and a closed connection. Last, a client that closes after the first line
leaves no zombie child behind: the test process ignores `SIGCHLD` from
`testsuite_begin`, as `main` does.

## See also

- [examples/async_sse](../async_sse/) — the same chunk-per-suspend streaming,
  driven by a timer
- [examples/async_pipe](../async_pipe/) — the minimal park/resume on a pipe
- [examples/chunked_streaming](../chunked_streaming/) — chunked responses
- [examples/https_upstream](../https_upstream/) — watching an upstream socket
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
