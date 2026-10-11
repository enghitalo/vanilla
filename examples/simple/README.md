# simple — route on method and path, answer from controllers

The first step after [examples/tiny](../tiny/): parse the request, route on
method and path, and hand each route to a small controller function. Three
routes in the shape of a CRUD API (`GET /`, `GET /user/:id`, `POST /user`),
with the router in [main.v](src/main.v) and the controllers in
[controllers.v](src/controllers.v).

It is written the straightforward way, to read easily: the router compares
`string` views, and each controller **returns** a `[]u8` that the router then
appends to `out`. The next two examples change one thing each:
[simple2](../simple2/) keeps these routes but rewrites them to the project's
byte discipline, and [simple3](../simple3/) keeps this code but hangs the
handler on an `App` struct that owns shared resources.

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
  path as `tos` views into the request buffer (no copy), and branches with
  `==` and `starts_with`.
- **Controllers return the whole response.** `home_controller` and
  `create_user_controller` return `const` responses (`.bytes()`);
  `get_user_controller` builds its reply in a `strings.Builder`. The router
  appends the returned bytes with `out << ...`.
- **This is the readable version, not the fast one.** `/user/:id` allocates
  per request: `path[6..]` copies the id, `[id]` allocates the params array,
  `.str()` formats the length, and the builder plus the return-then-copy into
  `out` add more. [BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)
  explains why that matters at scale; [simple2](../simple2/) removes all of it.
- `get_users_controller` is defined but no route reaches it (the compiler
  notes it as unused).

## Tests

```sh
v test examples/simple/src
```

[main_test.v](src/main_test.v) calls `handle_request` directly on four raw
requests (home, user, create, an unknown `INVALID` method) and compares the
bytes. [server_end_to_end_test.v](src/server_end_to_end_test.v) sends the same
four over real sockets with `vtest.drive` (ephemeral port, all connections
concurrent across the workers) and checks each response byte for byte.

## See also

- [examples/simple2](../simple2/) — the same routes, zero-copy routing and
  controllers that append straight into `out`
- [examples/simple3](../simple3/) — the same code with the handler as a method
  on an `App` struct holding a SQLite pool
- [examples/router](../router/), [examples/veb_like](../veb_like/) — routing
  modules for real route trees
- [BEST_PRACTICES §9 — test without a running server](../../docs/BEST_PRACTICES.md#9-test-without-a-running-server)
