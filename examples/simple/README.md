# simple — route on method and path, answer from controllers

The first step after [examples/tiny](../tiny/): parse the request, route on
method and path, and hand each route to a small controller function. Three
routes in the shape of a CRUD API (`GET /`, `GET /user/:id`, `POST /user`),
with the router in [main.v](src/main.v) and the controllers in
[controllers.v](src/controllers.v).

It is written the straightforward way, to read easily: the router compares
`string` views of the request with `==`, and each controller appends its
response straight into `out`. It still allocates nothing per request. The
next two examples change one thing each: [simple2](../simple2/) routes by
byte offsets instead of building string views, and [simple3](../simple3/)
keeps this code but hangs the handler on an `App` struct that owns shared
resources.

## File layout

| File | Role |
|---|---|
| [src/main.v](src/main.v) | `handle_request` (the router) and `main` (server config) |
| [src/controllers.v](src/controllers.v) | one function per route, each returning the full response |
| `dockerfile`, `docker-compose.yml` | container recipe (not exercised by the tests; the compose file's `PORT` variable is not read, the port is fixed in code) |

## Run

```sh
v -prod run examples/simple/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)).

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
curl -i -X POST localhost:3000/user
```

```
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 0
Connection: keep-alive

```

`curl -i localhost:3000/` answers `200 OK` with an empty body. Any other
method or path (`/users`, `/nope`) gets the library's canned 400:

```
HTTP/1.1 400 Bad Request
Content-Length: 0
Connection: close

```

The id is everything after `/user/`, query included: `/user/7?x=1` echoes
`7?x=1`, and `/user/` echoes an empty body.

## How it works

- **One handler is the router.** `handle_request` decodes the request with
  `request_parser.decode_http_request` (a malformed one gets
  `response.tiny_bad_request_response` and `.close`), takes the method and
  path as `tos` views of the handler's `req_buffer` (no copy), and branches
  with `==` and `starts_with`. The views come from `req_buffer`, not
  `req.buffer`: a view of `req.buffer` that reaches a callee makes V copy the
  whole request struct to the heap on every request.
- **Controllers append the whole response.** Each takes `mut out []u8`:
  `home_controller` and `create_user_controller` append `const` strings with
  `core.append_str`, and `get_user_controller` gets the id as a view of the
  path (`tos(path.str + 6, ...)`, not `path[6..]`, which copies) and frames
  its reply with `core.append_str` plus the local `wi` for `Content-Length`.
  Nothing is returned to be copied into `out` again
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)).
- `get_users_controller` is defined but no route reaches it (the compiler
  notes it as unused).

## Tests

```sh
v test examples/simple/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly on four raw
requests (home, user, create, an unknown `INVALID` method), compares the
bytes, and checks that no route allocates (a `gc_heap_usage()` delta over 20k
rounds). [server_end_to_end_test.v](src/server_end_to_end_test.v) sends the same
four over real sockets with `vtest.drive` (ephemeral port, all connections
concurrent across the workers) and checks each response byte for byte.

## See also

- [examples/simple2](../simple2/) — the same routes, routed by byte offsets
- [examples/simple3](../simple3/) — the same code with the handler as a method
  on an `App` struct holding a SQLite pool
- [examples/router](../router/), [examples/veb_like](../veb_like/) — routing
  modules for real route trees
- [BEST_PRACTICES §9 — test without a running server](../../docs/BEST_PRACTICES.md#9-test-without-a-running-server)
