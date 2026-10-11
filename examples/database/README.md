# database — PostgreSQL through V's blocking `db.pg`

A small users API on PostgreSQL with V's standard `db.pg` module (libpq) and a
hand-rolled connection pool. It is the simplest way to put a database behind
vanilla, and it shows the cost of that simplicity: every query blocks the
worker thread that runs it. For the non-blocking way, where the worker parks
on the database socket and serves other connections meanwhile, see
[examples/async_db_pg](../async_db_pg/).

It also carries the SQL-injection regression for `/user/<id>`
([#193](https://github.com/enghitalo/vanilla/issues/193)): the id is validated
before the database is touched, then bound as a query parameter.

## File layout

| File                                 | Responsibility                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| [main.v](src/main.v)                 | `handle_request` (routing), the pool and `users` table setup, the server.      |
| [database.v](src/database.v)         | `ConnectionPool`: a `chan pg.DB` of open connections, `acquire` / `release`.  |
| [controllers.v](src/controllers.v)   | One function per route, each appending the whole response into `out`.         |

## Run

Prerequisites: the libpq development headers (`libpq-dev` on Debian/Ubuntu,
`postgresql-libs` on Arch, `brew install libpq` on macOS), which `db.pg`
compiles against, and a PostgreSQL server. The connection settings are
hardcoded in [main.v](src/main.v) (`localhost:5435`, user `username`,
password `password`, database `example`) and match the bundled
[docker-compose.yml](docker-compose.yml):

```sh
docker compose -f examples/database/docker-compose.yml up -d
v -prod run examples/database/src
```

Compose names the project after the file's directory, `database`: the
container is `database-postgres-1`, on the `database_default` network, and the
data is kept in the `database_postgres_data` volume. At startup the example
opens 5 connections and creates the `users` table if it is missing; then it
listens on `:3000`. When you are done (this removes the container, the network
and the volume):

```sh
docker compose -f examples/database/docker-compose.yml down -v
```

The routes, on a fresh table:

```sh
curl -i -X POST localhost:3000/user      # inserts a row named new_user
curl -i localhost:3000/user              # every row, ordered by id
curl -i localhost:3000/user/1            # one row, by id
curl -i localhost:3000/user/99           # an id with no row
curl -i 'localhost:3000/user/1;DELETE/**/FROM/**/users'
```

`POST /user`:

```
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 0
Connection: keep-alive
```

After two inserts, `GET /user`:

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 55
Connection: keep-alive

[{"id":1,"name":"new_user"},{"id":2,"name":"new_user"}]
```

`GET /user/1`:

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 26
Connection: keep-alive

{"id":1,"name":"new_user"}
```

The query string is not part of the route: `GET /user/1?x=1` gets that same
answer, and `GET /user?x=1` the list. `GET /user/99`, an id with no row:

```
HTTP/1.1 404 Not Found
Content-Length: 0
Connection: keep-alive
```

Any other method or path (`GET /nope`, `DELETE /user`) gets that same 404.
The injection attempt never reaches the database:

```
HTTP/1.1 400 Bad Request
Content-Length: 0
Connection: keep-alive
```

`GET /` is a 200 with an empty body. Every one of these responses keeps the
connection: curl reuses it from one request to the next, and pipelined
requests are answered in order. A request head that does not parse gets the
canned `400 Bad Request` with `Connection: close` instead, and the server
closes the connection after it.

## How it works

- **A shared, blocking pool.** `ConnectionPool` holds open `pg.DB`
  connections in a buffered channel. The handler closure captures the pool,
  so all workers share it; `acquire` receives from the channel (blocking
  when all 5 are taken) and the controllers `defer` the `release`. Channel
  operations are thread-safe, so no further lock is needed
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **Blocking queries.** `db.exec` and `db.exec_param` wait on the database on
  the worker thread; while they do, that worker serves nobody else. This is
  what [BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
  replaces with `pg_async` and `.suspend`.
- **Injection defense in two layers.** `handle_request` routes on the path
  up to its first `?` (`route_len`), so the query string never reaches a
  controller, and takes the id after `/user/` as a `tos` view into the
  request buffer. `is_user_id` accepts only 1-10 ASCII digits that fit in an
  int4, so anything else is a 400 before the pool is touched.
  `get_user_controller` then copies the digits into a NUL-terminated stack
  array (libpq reads parameters as C strings) and binds them as `$1` with
  `exec_param`; the id is never spliced into SQL text.
- **JSON appended into `out`.** The controllers take `mut out []u8`: their
  fixed responses are `const` strings appended with `core.append_str`, and
  `append_users_response` writes the head (`json_head`, `json_tail`), then
  the body straight into `out`, then splices the `Content-Length` digits in
  between (one memmove over the tail and body), with no `strings.Builder`, no
  `.str()` and no return-then-copy
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc),
  [§3](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)).
  The queries select `id, name` (`ORDER BY id` for the list), and each row
  becomes `{"id":…,"name":…}`: the id is libpq's text for the int4, its
  digits, already a JSON number; the name goes through `json_escape_into`,
  which escapes `"`, `\` and control characters as
  [examples/async_db_pg](../async_db_pg/) does; SQL NULL is `null`. What
  these routes allocate comes from db.pg (the result rows, as V strings,
  among other things); the rendering and the routes that never reach the
  database allocate nothing.
- **Every response keeps the connection.** Each one says
  `Connection: keep-alive`, and `handle_request` returns `.done`, so the
  header says what the server does (a server that sends `close` must close,
  [RFC 9112 §9.6](https://www.rfc-editor.org/rfc/rfc9112#section-9.6)). The
  one exception is a request head that `decode_http_request` rejects: it gets
  `response.tiny_bad_request_response` (`Connection: close`, appended with
  `<<`) and `.close`, which closes the connection.

## Tests

```sh
v test examples/database/src
```

[main_test.v](src/main_test.v) needs no PostgreSQL (but does need libpq to
compile): it calls `handle_request` with a closed, empty pool, so a request
that reaches the database gets the controller's 500. Injection payloads
(`1/**/OR/**/1=1`, `1;DELETE...`, `abc`, `-1`, an int4 overflow, 11 digits,
with or without a query string) all get the 400, and valid ids get 500 (they
passed validation; `/user/1?x=1` is one, its query cut off). Every request
that parses, route by route, is answered `.done` with
`Connection: keep-alive` (unknown routes with the 404), and a malformed head
gets the canned 400 and `.close`. `is_user_id` is checked directly (it
rejects `1?x=1` too). `append_users_response` renders the exact JSON, array
and object, with escaped names and `null`, framed with its Content-Length,
and a JSON parser reads the escaped name back. The routes that stop before
the database allocate nothing, and neither does the rendering.

## See also

- [examples/async_db_pg](../async_db_pg/) — the same idea without blocking:
  `pg_async`, a per-worker pool and `watch_fd_persistent`
- [examples/pg_transactions](../pg_transactions/) — a multi-statement write as
  one batch, retried on conflict
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [BEST_PRACTICES §8 — security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
