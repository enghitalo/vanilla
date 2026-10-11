# simple — route on method and path, answer from controllers

The first step after [examples/tiny](../tiny/): parse the request, route on
method and path, and hand each route to a small controller function. Three
routes in the shape of a CRUD API (`GET /`, `GET /user/:id`, `POST /user`),
with the router in [main.v](src/main.v) and the controllers in
[controllers.v](src/controllers.v).

It is written the straightforward way, to read easily: the router compares
`string` views of the request with `==`, and each controller appends its
response straight into `out`. No route allocates. The next two examples
change one thing each: [simple2](../simple2/) routes by byte offsets instead
of building string views, and [simple3](../simple3/) keeps this code but
hangs the handler on an `App` struct that owns shared resources.

## File layout

| File | Role |
|---|---|
| [src/main.v](src/main.v) | `handle_request` (the router) and `main` (server config) |
| [src/controllers.v](src/controllers.v) | one function per route, each appending the full response into `out` |
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
method or path (`/users`, `/nope`, `PUT /user`) gets a 404, and the
connection stays open for the next request, as the header says:

```sh
curl -i localhost:3000/nope
```

```
HTTP/1.1 404 Not Found
Content-Length: 0
Connection: keep-alive

```

Routes match the path up to the first `?`, so the query never reaches the
id, and `/?x=1` is the home route:

```sh
curl -i 'localhost:3000/user/7?x=1'
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 1
Connection: keep-alive

7
```

`/user/` has no id, so it gets the same 404, with or without a query. A
request whose head does not parse gets the library's canned 400 instead
(`Connection: close`), and the server then closes the connection.

## How it works

- **One handler is the router.** `handle_request` decodes the request with
  `request_parser.decode_into`, which fills a stack `HttpRequest` and
  returns `false` for a malformed head instead of boxing an `error()` (that
  request gets `response.tiny_bad_request_response` and `.close`). It takes
  the method and path as `tos` views of the handler's `req_buffer` (no
  copy), cuts the path view at the first `?` (`index_u8`, then a shorter
  `tos`), and branches with `==` and `starts_with`; `/user/<id>` needs at
  least one id byte. The views come from `req_buffer`, not `req.buffer`: a
  view of `req.buffer` handed to a function that returns it (or returns
  `!T`/`?T`) makes V copy the whole request struct to the heap on every
  request
  ([V_PERF_TOOLBOX](../../docs/V_PERF_TOOLBOX.md#comptime-escape-and-allocation-checks-v-5516000)).
- **No match is a 404 that keeps the connection.** The fall-through appends
  the `const` `http_not_found_response` (`Connection: keep-alive`) with
  `core.append_str` and returns `.done`, so the header and the connection
  agree. The malformed-head 400 says `Connection: close` and returns
  `.close`.
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

[main_test.v](src/main_test.v) calls `handle_request` directly and checks
the response bytes and the returned `Step`: the three routes, the 404 with
`.done` for unknown methods and paths, the query cut (`/user/7?x=1`,
`/?x=1`, `POST /user?x=1`), the 404 for `/user/` with and without a query,
and the 400 with `.close` for a malformed head. It also checks that no
request allocates, the 404s and the malformed head included (a
`gc_heap_usage()` delta over 20k rounds).
[server_end_to_end_test.v](src/server_end_to_end_test.v) sends requests over
real sockets with `vtest.drive` (ephemeral port, all connections concurrent
across the workers), checks each response byte for byte, and checks that a
404 leaves the connection open for a second request and that the server
closes the connection after a malformed head's 400.

## See also

- [examples/simple2](../simple2/) — the same routes, routed by byte offsets
- [examples/simple3](../simple3/) — the same code with the handler as a method
  on an `App` struct holding a SQLite pool
- [examples/router](../router/), [examples/veb_like](../veb_like/) — routing
  modules for real route trees
- [BEST_PRACTICES §9 — test without a running server](../../docs/BEST_PRACTICES.md#9-test-without-a-running-server)
