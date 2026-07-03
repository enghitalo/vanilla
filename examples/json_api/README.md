# JSON + multipart body — reference design

Shows the *purest* shape of request-body handling on top of vanilla: the
handler is a total function of `(request) -> (response)`. It decodes bytes and
never touches the socket.

## Endpoints

```
POST /users    Content-Type: application/json        -> 201 Created (JSON)
POST /upload   Content-Type: multipart/form-data      -> 200 OK (JSON summary)
```

Anything else answers `404 Not Found` with a JSON error body.

## Try it

```bash
v -prod run examples/json_api

curl -d '{"name":"Ada","email":"ada@example.com"}' \
     -H 'Content-Type: application/json' localhost:3000/users

curl -F file=@./logo.png localhost:3000/upload
```

## Body framing lives in the core

This example assumes `req.body` is the **complete** body — and the core
delivers that today.
[`request.read_request`](../../http_server/http1_1/request/request.c.v) loops
`recv()` and asks the pure framer (`request_parser.frame_request_length`)
whether a whole message is present yet, honoring `Content-Length` and
`Transfer-Encoding: chunked`. A handler never reads the socket to reassemble a
body — that is the point.

Residual core limitation: a request fragmented across epoll readiness bursts
(`EAGAIN` mid-message) is rejected with an error — it is never delivered
truncated. Framing correctness is regression-tested in the core by a
split-fuzz test over every prefix of a framed request
([`request_parser_test.v`](../../http_server/http1_1/request_parser/request_parser_test.v)).

## Notes on purity & byte discipline

- `parse_multipart` scans the raw body bytes by offsets; every `Part` field is
  a zero-copy view into the request buffer (`tos` / `vbytes`). The views must
  not outlive the request — here the response is built synchronously, so
  nothing retains them.
- Header lookup is case-insensitive (RFC 9110 §5.1): `Content-Type`,
  `content-type` and `CONTENT-TYPE` all match — the core folds ASCII case in
  place. The `boundary=` parameter name is matched case-insensitively too
  (RFC 2045).
- Static responses (the 404 and the 400 family) are consts built once at init;
  dynamic responses are framed straight into `out` with zero-alloc append
  helpers — no `${}`, no `+` anywhere.
- One deliberate copy remains: `json.decode` is cJSON-backed and measures its
  input with `strlen`, so it needs a real NUL-terminated string — a view into
  the request buffer would over-read past the body.
