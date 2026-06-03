# JSON + multipart body — reference design

Shows the *purest* shape of request-body handling on top of vanilla: the
handler is a total function of `(request) -> (response)`. It decodes bytes and
never touches the socket.

## Endpoints

```
POST /users    Content-Type: application/json        -> 201 Created (JSON)
POST /upload   Content-Type: multipart/form-data      -> 200 OK (JSON summary)
```

## Try it

```bash
v -prod run examples/json_api

curl -d '{"name":"Ada","email":"ada@example.com"}' \
     -H 'Content-Type: application/json' localhost:3000/users

curl -F file=@./logo.png localhost:3000/upload
```

## Aspirational prerequisite

This example assumes `req.body` is the **complete** body. Today
[`request.read_request`](../../http_server/http1_1/request/request.c.v) stops at
the first short read and ignores `Content-Length`, so a body split across TCP
segments arrives truncated.

The fix belongs in the **core**, not the handler: frame the body by
`Content-Length` (or `Transfer-Encoding: chunked`) before invoking the handler.
Once that lands, this handler works unchanged — that is the point. A handler
should never read the socket to reassemble a body.

## Notes on purity

- `parse_multipart` materializes the body as a string for readability. The
  zero-copy form scans the raw `Slice` and returns each part's content as a
  sub-slice — same logic, no per-file allocation. Worth doing for large uploads.
- Header lookup is case-sensitive in the current parser, so `Content-Type` must
  match exactly. A case-insensitive name compare in the core (RFC 9110 §5.1)
  would remove that footgun.
