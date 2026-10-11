# async_db_pg — PostgreSQL queries without blocking the worker

`GET /db` runs `select id, name from pg_async_demo order by id` through
[`pg_async`](../../pg_async/), vanilla's native (no libpq) PostgreSQL wire
client, and answers the rows as JSON. The handler submits the query, parks on
the database socket and returns; the worker serves other connections until
the reply arrives, then a continuation renders it. Each worker owns its own
connection pool, so nothing is shared between threads.

This is the template for any handler that waits on a database: the HttpArena
async-db endpoints and [bench/pg_async/e2e_server](../../bench/pg_async/e2e_server/main.v)
follow the same shape.

## Run

You need a PostgreSQL server reachable with SCRAM (pg_async's default auth)
and the demo table. A throwaway one in Docker:

```sh
docker run -d --rm --name vanilla-pg -e POSTGRES_USER=vanilla \
  -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=vanilla \
  -p 127.0.0.1:55432:5432 postgres:16
docker exec vanilla-pg psql -U vanilla -d vanilla \
  -c "create table pg_async_demo (id int4 primary key, name text);" \
  -c "insert into pg_async_demo values (1,'alpha'),(2,'beta'),(3,'gamma');"
```

([pg_async/testdata/throwaway_pg.sh](../../pg_async/testdata/throwaway_pg.sh)
builds the same seeded table from local PostgreSQL binaries, without Docker.)
Then start the example with the `PG*` variables `build_pool` reads (`PGHOST`
defaults to `localhost`, `PGPORT` to 5432):

```sh
PGHOST=127.0.0.1 PGPORT=55432 PGUSER=vanilla PGPASSWORD=secret PGDATABASE=vanilla \
  v -prod run examples/async_db_pg/src
```

It listens on `:8099` (hardcoded in [main.v](src/main.v)). Each worker dials
`pool_size` (4) connections at startup; if that fails, `build_pool` panics
and the server exits.

```sh
curl -i localhost:8099/db
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 72
Connection: keep-alive

[{"id":1,"name":"alpha"},{"id":2,"name":"beta"},{"id":3,"name":"gamma"}]
```

The query string is ignored (`/db?x=1` gives the same rows). Every other path
(`/health`, `/dbx`, …) answers without touching the database:

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

When every pooled connection of the worker is busy, `/db` answers
`503 Service Unavailable`; a query error answers `500`.

## How it works

- **Per-worker pool.** `build_pool` is the `make_state` hook: it builds a
  `pg_async.PgPool` from the `PG*` variables and returns it, with a reusable
  `body` scratch, as this worker's `DbState`. `start_maintenance`
  (`on_worker_start`) runs the pool's maintenance timer, which finds
  connections the server closed while idle and re-dials them before a request
  meets them.
- **Park on the socket.** The handler `acquire`s a connection, calls
  `conn.async_submit(...)` and `async_flush()`, then
  `event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, on_db_ready, idx)`
  and returns `.suspend`
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
  The connection index rides in `watch_payload`.
- **Persistent, never plain `watch_fd`.** If a client disconnects mid-query, a
  plain watch would close the pooled socket and drop the continuation, so the
  slot would never be released
  ([vanilla#190](https://github.com/enghitalo/vanilla/issues/190)). The
  persistent watch keeps the socket and still runs `on_db_ready` when the
  reply arrives (its response is discarded), which drains it and releases the
  slot.
- **The continuation.** `on_db_ready` calls `conn.async_on_readable()`;
  not ready yet re-arms the same watch, unless the fd reported an error
  (re-arming a dead level-triggered fd would spin the worker). Once ready it
  walks `poll.result.rows()`, reads each row with the typed accessors
  `row.int4(0)` and `row.text(1)`, and releases the connection on every path.
- **Rendering.** The JSON goes into the per-worker `st.body` scratch (length
  reset to 0, capacity kept), then into `out` behind a `Content-Length`
  computed from it. `wb` appends a byte slice, `wi` formats an integer with
  `strconv.write_dec` into a stack array: no `${}`, no `strings.Builder`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  `json_escape_into` escapes `"`, `\` and control characters, so a row value
  cannot break the document.
- **Routing in place.** `route_is` compares the parsed path with `/db` byte by
  byte, stopping at `?`, without copying the request.
- **Honest shedding.** No free connection, or a connection whose pipeline is
  full: `503`, a backpressure shed. A failed or partial flush, or a query
  error: `500`.

The park has no deadline (`watch_fd_deadline` or `Limits.park_timeout_ms`):
a database that stops answering holds the request (§5, "Bound every park").

## Tests

```sh
v test examples/async_db_pg/src
```

[main_test.v](src/main_test.v) checks `route_is` (`/db` and `/db?x=1` match;
`/dbx`, `/x/db` and a query holding ` /db` do not) and that every other path
is answered without the pool, with a malformed request getting the canned
400. [server_end_to_end_test.v](src/server_end_to_end_test.v) needs no
database: it runs the real handler, continuation and `build_pool` against a
fake PostgreSQL written in the test (Linux only). It parks one `/db` per pool
slot with the replies held, disconnects every client, checks no pooled
connection was closed, then releases the replies and checks `pool_size + 1`
further `/db` all get 200 with correctly escaped JSON: no slot leaked.

## See also

- [examples/pg_transactions](../pg_transactions/) — a multi-statement write
  as one batch, retried on serialization failures
- [bench/pg_async](../../bench/pg_async/) — end-to-end and leak benchmarks of
  the same handler shape, pipelined pools included
- [pg_async/PIPELINING_DESIGN.md](../../pg_async/PIPELINING_DESIGN.md)
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [Wiki: Async Postgres and Pipelining](https://github.com/enghitalo/vanilla/wiki/Async-Postgres-and-Pipelining)
