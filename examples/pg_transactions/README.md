# pg_transactions — an atomic PostgreSQL write, retried on conflict

`POST /transfer` moves 1 from account 1 to account 2: two `UPDATE`s sent with
[`pg_async`](../../pg_async/) as ONE batch, so they commit or roll back
together in a single round trip. Under `SERIALIZABLE` (and always on Aurora
DSQL) a transaction that collides with a concurrent one fails with SQLSTATE
`40001` and must run again, whole; the continuation asks `pg_async.TxRetry`
whether to, waits a random, growing time on a timerfd without holding a
connection, and resubmits the same batch.

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

2000 transfers from 32 concurrent clients, each on a connection of its own,
against the `SERIALIZABLE` database (PostgreSQL 16, 4 workers with
`VANILLA_WORKERS=4`, so 16 pooled connections) answered, in one run (count,
status, body):

```
    911 200 {"attempts":1}
    286 200 {"attempts":2}
    197 200 {"attempts":3}
    167 200 {"attempts":4}
    121 200 {"attempts":5}
    307 409
     11 503
```

1682 transfers committed, and account 2 then held exactly 1682: none was
lost or applied twice. The 307 that conflicted on all 5 attempts got
`409 Conflict`; the 11 that found every connection busy got `503`. Running
each attempt again at once, with no wait, the same load got 41–45% `409`s
instead of 10–16%: transfers that collided collided again.

## How it works

- **One batch, one transaction.** `transfer` is a `const` array of two
  `pg_async.Stmt`, built once. `conn.async_submit_batch(transfer)` ends them
  with a single Sync, so PostgreSQL runs them as one implicit transaction: no
  `BEGIN`/`COMMIT`, one round trip.
- **Park, don't block.** `run_attempt` submits, flushes, then parks on the
  pooled fd with `event_loop.watch_fd_persistent(..., on_reply, parked(idx, attempt))` and
  returns `.suspend`; the worker serves other connections until the reply
  arrives
  ([BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)).
  A pooled fd must be watched persistently, so a client that hangs up
  mid-query does not close the database connection.
- **Retry in the continuation.** `on_reply` calls `conn.async_on_readable()`
  and `release`s the connection on every path. On an error,
  `policy.retry(attempt, err)` is true only for a serialization failure with
  attempts left: the batch did nothing, so it runs again, whole. Out of
  attempts, `pg_async.is_serialization_failure(err)` picks 409; anything else
  is 500.
- **Back off on a timerfd, without the connection.** Before the next attempt
  the request waits `policy.backoff_ms(attempt)`: random, up to 10 ms after
  the first conflict and doubling to at most 500 ms
  (`TxRetry{max_attempts: 5, base_backoff_ms: 10, max_backoff_ms: 500}`), so
  transfers that collided do not collide again in lockstep.
  `policy.park_backoff` arms a one-shot timerfd and parks the request on it.
  The connection was released first, so other requests use it meanwhile;
  `on_backoff` acquires one again when the timer fires (503 if none is free)
  and runs the attempt. Where no timerfd exists (not Linux), the attempt
  runs at once.
- **The attempt number travels with the request.** It is in `watch_payload`
  (packed with the connection index while the request is parked on its
  connection), not in the connection's state: the request may get another
  connection after a wait.
- **Who closes the timer.** `on_reply` closes the timer of the wait its
  attempt came from (`TxState.timers`), not `on_backoff`: the runtime takes
  the timer out of the event loop only once `on_backoff` has returned, and a
  number closed before then could already be a connection another thread
  just accepted, which would be taken out instead and never served.
- **A client that leaves ends the transfer.** While it waits on the timer,
  the runtime closes the timer and drops the request. While its batch is in
  flight, the runtime still runs `on_reply` for the reply, to keep the
  connection in step; a conflict there releases the connection and steps to
  a timer, which the runtime closes without resuming the request. Either
  way no attempt follows and the connection is back in the pool.
- **Shed, don't queue.** No free connection in the pool, or one that broke
  before the batch was queued: `503 Service Unavailable`, a backpressure
  shed, not an error.
- **Framing without interpolation.** Fixed answers are `const` strings
  appended with `core.append_str`; `answer_attempts` writes the attempt count
  and the Content-Length with `strconv.write_dec` into stack arrays and
  appends the digits
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  `starts_with` matches `POST /transfer ` in place with `vmemcmp`.
- **No park deadline.** The park on the connection has no
  `watch_fd_deadline` and the config sets no `park_timeout_ms`, so a
  database that stops answering holds the request (§5, "Bound every park").
  The timer is its own deadline.

A transaction that needs one statement's result before sending the next is
`BEGIN … COMMIT` across park/resume instead, also on `acquire()`, never
`acquire_pipelined()` ([pg_async/tx.v](../../pg_async/tx.v)).

## Tests

```sh
v test examples/pg_transactions/src
```

[server_end_to_end_test.v](src/server_end_to_end_test.v) runs the real
handler, continuations and `make_state` against the fake PostgreSQL in
[pg_async/testdata/fake_pg.py](../../pg_async/testdata/fake_pg.py) (needs
`python3`; Linux only), which fails the first N writes with `40001`. The
server runs in the test process, so the tests count its timerfds in
`/proc/self/fd`. They check that:

- a transfer conflicting twice commits on its third attempt
  (`{"attempts":3}`);
- one conflicting every time waits on a timer between attempts (one at a
  time) and gives up with 409 after exactly `max_attempts` queries;
- other paths are 404;
- while a transfer waits, its connection serves other transfers (all
  `pool_size` connections commit one at once), and when its client hangs up
  during the wait the timer is closed and no attempt follows;
- a client hanging up while an attempt is in flight, before or after a
  wait, stops the retries, leaves no timer open and frees its connection.

Each transfer test also checks that no timer is left open.

## See also

- [examples/async_db_pg](../async_db_pg/) — one `SELECT` per request,
  rendered as JSON, with the same per-worker pool
- [pg_async/tx.v](../../pg_async/tx.v) — `TxRetry`, `is_serialization_failure`
  and the Aurora DSQL limits
- [BEST_PRACTICES §5 — side effects through the async runtime](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
- [Wiki: Async Postgres and Pipelining](https://github.com/enghitalo/vanilla/wiki/Async-Postgres-and-Pipelining)
