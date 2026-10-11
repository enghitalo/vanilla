# pg_transactions — an atomic PostgreSQL write, retried on conflict

`POST /transfer` moves 1 from account 1 to account 2: two `UPDATE`s sent with
[`pg_async`](../../pg_async/) as ONE batch, so they commit or roll back
together in a single round trip. Under `SERIALIZABLE` (and always on Aurora
DSQL) a transaction that collides with a concurrent one fails with SQLSTATE
`40001` and must run again, whole; the continuation asks `pg_async.TxRetry`
whether to, and resubmits the same batch.

It is the pattern for any multi-statement write from a handler: no blocking
the worker, no `BEGIN` held open across requests, and honest status codes for
each outcome (200, 409, 503, 500).

## Run

You need a PostgreSQL server reachable with SCRAM (pg_async's default auth).
A throwaway one in Docker, seeded with the table the example expects:

```sh
docker run -d --rm --name vanilla-pg -e POSTGRES_USER=vanilla \
  -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=vanilla \
  -p 127.0.0.1:55432:5432 postgres:16
docker exec vanilla-pg psql -U vanilla -d vanilla \
  -c "create table accounts (id int4 primary key, balance int4 not null check (balance >= 0));" \
  -c "insert into accounts values (1, 100), (2, 0);"
# optional: make every transaction SERIALIZABLE, so concurrent transfers conflict
docker exec vanilla-pg psql -U vanilla -d vanilla \
  -c "alter database vanilla set default_transaction_isolation = 'serializable'"
```

Then point the example at it with the `PG*` variables `build_state` reads
(`PGHOST` defaults to `localhost`, `PGPORT` to 5432):

```sh
PGHOST=127.0.0.1 PGPORT=55432 PGUSER=vanilla PGPASSWORD=secret PGDATABASE=vanilla \
  v -prod run examples/pg_transactions/src
```

It listens on `:8099` (hardcoded in [main.v](src/main.v)). Each worker opens
a pool of `pool_size` (4) connections at startup; if that fails,
`build_state` panics and the server exits.

```sh
curl -i -X POST localhost:8099/transfer
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 14
Connection: keep-alive

{"attempts":1}
```

Any other method or path is `404 Not Found` with an empty body. With
account 1 at 0, the CHECK fails the first `UPDATE`, the whole batch with it,
and no money moves:

```
HTTP/1.1 500 Internal Server Error
Content-Length: 0
Connection: keep-alive
```

200 concurrent transfers (`xargs -P 32`) against the `SERIALIZABLE` database
answered, in one run (count, body, status):

```
     55 {"attempts":1} 200
     37 {"attempts":2} 200
     21 {"attempts":3} 200
     15 {"attempts":4} 200
     20 {"attempts":5} 200
     52  409
```

148 transfers committed and the two balances still summed to the start
total; the 52 that conflicted on all 5 attempts got `409 Conflict`.

## How it works

- **One batch, one transaction.** `transfer` is a `const` array of two
  `pg_async.Stmt`, built once. `conn.async_submit_batch(transfer)` ends them
  with a single Sync, so PostgreSQL runs them as one implicit transaction: no
  `BEGIN`/`COMMIT`, one round trip.
- **Park, don't block.** `run_attempt` submits, flushes, then parks on the
  pooled fd with `event_loop.watch_fd_persistent(..., on_reply, idx)` and
  returns `.suspend`; the worker serves other connections until the reply
  arrives
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
  A pooled fd must be watched persistently, so a client that hangs up
  mid-query does not close the database connection.
- **Retry in the continuation.** `on_reply` calls `conn.async_on_readable()`.
  On an error, `policy.retry(attempt, err)` (`TxRetry{max_attempts: 5}`) is
  true only for a serialization failure with attempts left: the batch did
  nothing, so `run_attempt` submits it again on the same connection. Out of
  attempts, `pg_async.is_serialization_failure(err)` picks 409; anything else
  is 500. The connection is `release`d on every path.
- **No backoff yet.** The retry runs at once on the connection the request
  holds (`acquire()`), not after `policy.backoff_ms` on a timerfd: until
  [vanilla#247](https://github.com/enghitalo/vanilla/pull/247) a continuation
  parked on a pooled connection cannot safely step to another fd. The comment
  at the top of [main.v](src/main.v) has the details, and how the code changes
  once #247 lands.
- **Attempt counts in worker state.** `build_state` (the `make_state` hook)
  gives each worker a `TxState`: its `PgPool` and an `attempts` slot per
  pooled connection. The count lives there rather than in `watch_payload`
  (which only carries the connection index), so a continuation that keeps
  running after its client left still stops at `max_attempts`.
- **Shed, don't queue.** No free connection in the pool, or one that broke
  before the batch was queued: `503 Service Unavailable`, a backpressure
  shed, not an error.
- **Framing without interpolation.** Fixed answers are `const` strings
  appended with `core.append_str`; `answer_attempts` writes the attempt count
  and the Content-Length with `strconv.write_dec` into stack arrays and
  appends the digits
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  `starts_with` matches `POST /transfer ` in place with `vmemcmp`.
- **No park deadline.** The park has no `watch_fd_deadline` and the config
  sets no `park_timeout_ms`, so a database that stops answering holds the
  request (§5, "Bound every park").

A transaction that needs one statement's result before sending the next is
`BEGIN … COMMIT` across park/resume instead, also on `acquire()`, never
`acquire_pipelined()` ([pg_async/tx.v](../../pg_async/tx.v)).

## Tests

```sh
v test examples/pg_transactions/src
```

[server_end_to_end_test.v](src/server_end_to_end_test.v) runs the real
handler, continuation and `build_state` against the fake PostgreSQL in
[pg_async/testdata/fake_pg.py](../../pg_async/testdata/fake_pg.py) (needs
`python3`; Linux only), which fails the first N writes with `40001`. It
checks that a transfer conflicting twice commits on its third attempt
(`{"attempts":3}`), that one conflicting every time gives up with 409 after
exactly `max_attempts` queries, that other paths are 404, and that a client
hanging up mid-retry still lets the attempts stop and frees its connection
(every pooled connection then serves a transfer on its first attempt).

## See also

- [examples/async_db_pg](../async_db_pg/) — one `SELECT` per request,
  rendered as JSON, with the same per-worker pool
- [pg_async/tx.v](../../pg_async/tx.v) — `TxRetry`, `is_serialization_failure`
  and the Aurora DSQL limits
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [Wiki: Async Postgres and Pipelining](https://github.com/enghitalo/vanilla/wiki/Async-Postgres-and-Pipelining)
