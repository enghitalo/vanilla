# simple2 — the same routes, written to the byte discipline

[examples/simple](../simple/) routes on `string` views compared with `==`.
simple2 serves the same CRUD-shaped routes (plus `GET /users`) with the
router comparing bytes in place by offsets, and the user id as a zero-copy
`[]u8` view of the request buffer. Both append the response straight into
the server's `out` buffer and allocate nothing on any request, a malformed
head included (both decode with `request_parser.decode_into`).

Read it side by side with simple: same file split, same responses, and every
difference is one of the patterns in
[BEST_PRACTICES §1–3](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc).

## File layout

| File | Role |
|---|---|
| [src/main.v](src/main.v) | `handle_request` (the router), `slice_eq`, `main` |
| [src/controllers.v](src/controllers.v) | controllers that append into `out`, and the `wi` integer helper |

## Run

```sh
v -prod run examples/simple2/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)), on the platform's
default backend (`IOBackend(0)`: epoll on Linux, kqueue on macOS, IOCP on
Windows).

```sh
curl -i localhost:3000/user/123
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 3
Connection: keep-alive

123
```

```sh
curl -i localhost:3000/users
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 0
Connection: keep-alive

```

`GET /` answers the same empty `200 OK` and `POST /user` a `201 Created`,
byte-identical to simple. The rest matches simple too: routes match the
path up to the first `?`, an unknown method or path and `/user/` (no id) get
a 404 with `Connection: keep-alive`, and a head that does not parse gets the
canned 400 and a close. Pipelined requests each get their own answer,
appended in order, and a 404 leaves the connection open for the next one:

```sh
printf 'GET /user/7?x=1 HTTP/1.1\r\nHost: x\r\n\r\nGET /user/ HTTP/1.1\r\nHost: x\r\n\r\nGET /user/22 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' \
  | socat -t1 - TCP:localhost:3000
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 1
Connection: keep-alive

7HTTP/1.1 404 Not Found
Content-Length: 0
Connection: keep-alive

HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

22
```

## What changes relative to simple

| | simple | simple2 |
|---|---|---|
| method / path match | `tos` views compared with `==`, `starts_with` | `slice_eq` compares the request `Slice` against a literal, byte by byte |
| the query | `index_u8` finds the `?`, then a shorter `tos` view | a loop finds the `?`, then a shorter `Slice` (same start) |
| the id | `tos(path.str + 6, ...)`, a `string` view of the path | `unsafe { (&req.buffer[i]).vbytes(n) }`, a `[]u8` view of the request bytes |
| `GET /user/` (no id) | 404: `path.len > 6` requires an id byte | 404: `path.len > prefix.len` requires an id byte |

The controllers are the same in both: `fn (..., mut out []u8)`, appending
`const` strings with `core.append_str` and framing the one dynamic reply
with `core.append_str` plus `wi` for `Content-Length`.

## How it works

- **Decode without an error box.** `request_parser.decode_into` fills a
  stack `HttpRequest` and returns `false` for a malformed head, with no
  `error()` to allocate; that request gets the canned 400
  (`Connection: close`) and `.close`.
- **Route by offsets.** Before any match, the path is cut at its first `?`:
  a loop finds it, and a `Slice` with the same start and the shorter length
  is the path from then on, so the query never reaches a match or the id.
  `slice_eq(buf, slice, lit)` checks the length, then the bytes, against the
  request buffer; the `/user/` prefix is compared the same way. Nothing is
  copied to route
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **A miss is a 404.** A request no route matches gets the `const`
  `http_not_found_response` (`Connection: keep-alive`) and `.done`, so the
  connection stays open, as the header says.
- **The id is a view.** `get_user_controller(id []u8, mut out)` receives a
  `vbytes` window over the request buffer. The response is built before the
  handler returns, so the view never outlives the buffer.
- **Append, don't return.** Static replies are `const` strings appended with
  `core.append_str`; the one dynamic reply frames itself with `core.append_str` and
  `wi`, which formats the integer with `strconv.write_dec` into a 24-byte
  stack scratch and pushes the digits
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
- The id is not decoded or validated: it is echoed as `text/plain` byte for
  byte (`/user/a%20b` echoes `a%20b`).

## Tests

```sh
v test examples/simple2/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly: each route's
exact bytes; the 404 and `.done` for an unknown method, unknown GET and POST
paths, and `/user/` with and without a query; the query cut (`/user/7?x=1`,
`/?x=1`, `/users?page=2`, `POST /user?x=1`); `.close` plus the canned 400 for
a truncated request head; and that no request allocates, the 404s and a
malformed head included (a `gc_heap_usage()` delta over 20k rounds).

## See also

- [examples/simple](../simple/) — the same routes on `string` views
- [examples/simple3](../simple3/) — simple's code with the handler on an
  `App` struct holding a SQLite pool
- [examples/router](../router/) — the same in-place routing as a module, for
  bigger route trees
- [BEST_PRACTICES §3a — static responses as `const` strings](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)
