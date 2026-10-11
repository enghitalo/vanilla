# chunked_streaming — `Transfer-Encoding: chunked`, both directions

Chunked encoding is how HTTP/1.1 carries a body of unknown length: a run of
`<hex-size>\r\n<bytes>\r\n` frames closed by a zero-size chunk
([RFC 9112 §7.1](https://www.rfc-editor.org/rfc/rfc9112#section-7.1)). This
example decodes a chunked request body without copying it and frames a chunked
response, so you can see the wire format from both sides.

The core already does the dangerous part: it only dispatches the handler once
the terminating chunk and its trailer section have arrived, and answers a
malformed chunk-size line, extension or trailer with a 400 (an oversized body
with a 413) before the handler runs. What reaches the handler in `req.body` is
the raw, well-formed chunk frames; decoding them is the handler's job.

## Run

```sh
v -prod run examples/chunked_streaming/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Any request without a
chunked body gets three demo pieces, each its own chunk:

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
Connection: keep-alive

first piece
second piece
third piece
```

curl decodes the chunks for you. The raw frames on the wire:

```sh
printf 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | socat -t1 - TCP:localhost:3000
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
Connection: keep-alive

c
first piece

d
second piece

c
third piece

0

```

A chunked request is echoed back chunk for chunk. curl sends `hello` as one
chunk:

```sh
curl -sS -H 'Transfer-Encoding: chunked' --data-binary 'hello' localhost:3000
```

```
hello
```

Chunk extensions and trailer fields are skipped (RFC 9112 §7.1.1, §7.1.2):

```sh
printf 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: abc\r\n\r\n' \
  | socat -t1 - TCP:localhost:3000
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
Connection: keep-alive

5
hello
6
 world
0

```

`Content-Length` together with `Transfer-Encoding` (the request-smuggling
shape, RFC 9112 §6.1) and a non-hex chunk size both get the canned 400 and a
closed connection:

```sh
printf 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n' \
  | socat -t1 - TCP:localhost:3000
```

```
HTTP/1.1 400 Bad Request
Content-Length: 0
Connection: close

```

## How it works

- **Zero-copy decode.** `next_chunk(buf, pos, limit)` parses one frame at an
  offset and returns `(data_start, data_len, next_pos)`: the chunk data is a
  window into the request buffer, never a copy. It skips `;ext` chunk
  extensions and the trailer section after the zero chunk, and rejects bare LF
  and truncated frames. `decode_chunked_into` builds on it for handlers that
  need the body contiguous: one `push_many` per chunk into a caller's buffer
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Echo by views.** `handle` walks the request's frames and hands each data
  window to `write_chunk` as `unsafe { (&req.buffer[data_start]).vbytes(data_len) }`,
  so the payload bytes are appended to `out` once, straight from the request
  buffer.
- **Framing without formatting.** `write_chunk` appends the size line with
  `wx`, which writes lowercase hex digits through a stack scratch (no
  `${n:x}`), then the data and the CRLF. The head and the last chunk are the
  `const` strings `resp_head_chunked` and `last_chunk`, appended with
  `core.append_str`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **`is_chunked`** compares the `Transfer-Encoding` value case-insensitively
  in place, over the `Slice` from `get_header_value_slice`.
- **Opt-in smuggling guard.** `req.validate_http1()` rejects CL+TE together
  and enforces exactly one `Host`. It is opt-in so a parse-free responder
  pays nothing; anything that reads bodies should call it
  ([BEST_PRACTICES §7](../../docs/BEST_PRACTICES.md#7-follow-the-http-standards)).
- **Framing, not streaming.** The handler builds the whole chunked response in
  one buffer before it is sent. For incremental delivery with backpressure, see
  [examples/async_sse](../async_sse/).

## Tests

```sh
v test examples/chunked_streaming/src
```

[main_test.v](src/main_test.v) tests the codec as pure functions: basic and
empty bodies, chunk extensions, upper/lowercase hex sizes, trailer sections,
`next_chunk` returning views, and the malformed shapes (truncated chunk,
non-hex size, missing CRLFs, bare LF) erroring instead of over-reading. Raw
requests through `handle` check the chunked response framing, the echo (with
and without a trailer), and the 400 + `.close` for CL+TE and garbage input.

## See also

- [examples/async_sse](../async_sse/) — true incremental delivery from the event loop
- [examples/request_limits](../request_limits/) — the size limits the core enforces before the handler
- [BEST_PRACTICES §7 — Follow the HTTP standards](../../docs/BEST_PRACTICES.md#7-follow-the-http-standards)
- [BEST_PRACTICES §9 — Test without a running server](../../docs/BEST_PRACTICES.md#9-test-without-a-running-server)
