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

The compose file names its container `postgres` and keeps the data in the
`database_postgres_data` volume. At startup the example opens 5 connections
and creates the `users` table if it is missing; then it listens on `:3000`.
When you are done:

```sh
docker compose -f examples/database/docker-compose.yml down -v
```

The routes, on a fresh table:

```sh
curl -i -X POST localhost:3000/user      # inserts a row named new_user
curl -i localhost:3000/user              # every row
curl -i localhost:3000/user/1            # one row, by id
curl -i 'localhost:3000/user/1;DELETE/**/FROM/**/users'
```

`POST /user`:

```
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 0
Connection: close
```

After two inserts, `GET /user`:

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 108
Connection: close

pg.Row{
    vals: [Option('1'), Option('new_user')]
}
pg.Row{
    vals: [Option('2'), Option('new_user')]
}
```

`GET /user/1` answers the first row alone (`Content-Length: 53`); an id with
no row answers 200 with an empty body. The injection attempt never reaches
the database:

```
HTTP/1.1 400 Bad Request
Content-Length: 0
Connection: close
```

`GET /` is a 200 with an empty body. Any other method or path is answered
with that same 400 (there is no 404 here).

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
- **Injection defense in two layers.** `handle_request` takes the id after
  `/user/` as a `tos` view into the request buffer (query string included).
  `is_user_id` accepts only 1-10 ASCII digits that fit in an int4, so
  anything else is a 400 before the pool is touched.
  `get_user_controller` then copies the digits into a NUL-terminated stack
  array (libpq reads parameters as C strings) and binds them as `$1` with
  `exec_param`; the id is never spliced into SQL text.
- **Responses appended into `out`.** The controllers take `mut out []u8`:
  fixed responses are `const` strings appended with `core.append_str`, and
  `append_rows_response` writes the head, then each row straight into `out`,
  then splices the `Content-Length` digits in front of the body (one memmove
  over it), with no `strings.Builder` and no return-then-copy
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc),
  [§3](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)).
  The body is still V's debug rendering of `pg.Row` (`row.str()`, one string
  per row), and with the query result it is what these routes allocate; the
  routes that never reach the database allocate nothing.
- **`Connection: close` is only a header.** Every response says it, but the
  handler returns `.done`, so the server keeps the connection open: a second
  pipelined request on it is still answered. curl closes after the first
  response because of the header.

## Tests

```sh
v test examples/database/src
```

[main_test.v](src/main_test.v) needs no PostgreSQL (but does need libpq to
compile): it calls `handle_request` with a closed, empty pool, so a request
that reaches the database gets the controller's 500. Injection payloads
(`1/**/OR/**/1=1`, `1;DELETE...`, `abc`, `-1`, `1?x=1`, an int4 overflow,
11 digits) all get 400, valid ids get 500 (they passed validation),
`is_user_id` is checked directly, `append_rows_response` frames rows exactly,
and the routes that stop before the database allocate nothing.

## See also

- [examples/async_db_pg](../async_db_pg/) — the same idea without blocking:
  `pg_async`, a per-worker pool and `watch_fd_persistent`
- [examples/pg_transactions](../pg_transactions/) — a multi-statement write as
  one batch, retried on conflict
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [BEST_PRACTICES §8 — security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
