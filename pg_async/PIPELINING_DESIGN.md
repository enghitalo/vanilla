# pg_async cross-request pipelining — design

## Problem
On the 128-core arena box, async-db/fortunes/crud regress vs sync because:
- `DATABASE_MAX_CONN=256` / `nr_cpus()=128` = **2 PG conns per worker** (per-worker pools, no sharing).
- pg_async is **one in-flight query per connection** (`conn_async.v`: `async_submit` resets `send_buf`+`q_frames`, sets `q_active`; `async_on_readable` returns one `QueryPoll`).
- the reactor is **one continuation per fd** (`async_linux.c.v`: `WatchEntry{client_fd,cont,udata}` — a single entry per `watches[fd]`).
So per-worker DB concurrency ceiling = 2. Sync wins because `db.pg.ConnectionPool` is one SHARED 256-conn pool (any of 128 threads → up to 256 concurrent).

## Goal
Let each of the (few) per-worker conns carry **N in-flight queries** (Postgres extended-protocol pipelining: N× Parse/Bind/Execute/Sync sent back-to-back, replies read in submission order). Per-worker concurrency 2 → 2×N. Target: async-db ~14k → 50-150k local (4-10×); NOT swerver's 370k (those are CPU-bound on RAM-resident data).

## Driver layer (increment 1 — self-contained, testable)
`PgConn` gains a FIFO of in-flight queries (cap N, e.g. 8):
- `async_submit` APPENDS the query's Parse/Bind/Describe/Execute/Sync to `send_buf` (no reset) and pushes a `PendingQuery{ frames, error, sqlstate, rows_affected, complete }` onto the ring. Reject (caller sheds) when the ring is full.
- `async_flush` unchanged (drains `send_buf`).
- `async_on_readable` drains the socket to EAGAIN, frames messages into the FRONT incomplete `PendingQuery`, and on its `ReadyForQuery` marks it complete + returns its `Result` and POPS it. Postgres guarantees replies arrive in submit order; each query keeps its own `Sync` so an ErrorResponse only skips that one query. Repeated calls return the buffered responses in FIFO order.

## Reactor layer (increment 2 — THE key decision, touches core runtime)
A PG conn fd now has MULTIPLE parked client requests (one per in-flight query). One readable edge can complete several. Two options:

**Option A — per-conn pump + fan-out primitive (recommended end-state).**
The conn fd is watched ONCE by a "drain" continuation; the conn owns the FIFO of `{client_fd, kind, id, page}` stashes. On readable: pump the conn, and for EACH completed response dispatch to the owning client — render into `st.conns[client_fd].write_buf` + `flush_batch` + clear `awaiting_fd`. Needs a NEW runtime primitive: a drain-continuation type that gets `st`/`epoll_fd` and a `complete_client(client_fd, bytes)` call (the current `WakeFn(mut out, mut ac)` only sees one client's buffer). Lower memory (reactor stays 1 entry/fd), the conn naturally owns the queue.

**Option B — per-fd continuation queue (lower risk, more memory).**
`watches[fd]` becomes a small fixed ring of `{client_fd,cont,udata}` (cap N). Each request keeps `ac.watch(conn_fd, on_db_ready, stash)` (appends). `async_on_ready` loops: run front cont; `.done` → pop + run next front; `.suspend` → re-arm + stop. Keeps the per-request `WakeFn` contract (each cont renders its own client). Cost: the flat `watches []WatchEntry` (sized to all fds) grows N× — ~196KB/worker at N=8; or use a side table keyed only by the few pg fds.

RECOMMENDATION: B first (incremental, keeps the WakeFn contract, no new primitive — fastest to a working+measurable result), with a side-table for pg fds to avoid bloating the whole watches array. Migrate to A later if the per-request overhead matters.

### Increment 2 — concrete realization (Option B, auto-promotion) — IMPLEMENTED
Chosen shape after reading the reactor (`backend_epoll/async_linux.c.v`):
- `WatchEntry` gains `queue []ParkSlot` (`ParkSlot{client_fd, cont, udata}`). For a
  single watch (timerfd / SSE / one query) the queue stays EMPTY and the existing
  `client_fd/cont/udata` fields drive the existing code path **byte-identically** —
  zero regression for every non-pipelined consumer, zero extra allocation.
- **Auto-promotion**: `reactor_watch` only builds a queue when a SECOND, different
  client parks on an already-active fd. It moves the existing head into `queue[0]`,
  appends the newcomer, and from then on the fd is "multi". When the queue drains
  empty the fd reverts to single. So only the few pipelined pg fds ever allocate a
  queue (~2/worker), never the thousands of client/timer fds — the doc's N×
  bloat worry is avoided without a separate map.
- **FIFO-alignment invariant (correctness keystone)**: each request does
  `async_submit` (push query onto `conn.inflight`) then `ac.watch(pg_fd)` (append
  client onto `queue`) as ONE operation, so `queue[k] ↔ inflight[k]`. The drain
  runs `queue[0]`'s cont, which calls `async_on_readable()` → returns `inflight[0]`
  → renders into `queue[0]`'s client. Order is the correlation; no id.
- **Drain loop** (`async_on_ready`, multi branch): run the FRONT cont against its
  client's `write_buf`; `.done` → `async_serve(client)` (flush + drain its pipelined
  HTTP) → pop front → continue; `.suspend` → front query not ready (so nothing
  behind it is either) → flush any streamed bytes, keep front, STOP. Empty queue →
  revert fd to single/inactive.
- **Re-arm idempotency**: when the front cont re-arms the SAME pg_fd on `.suspend`,
  `reactor_watch` finds its `client_fd` already in the queue and updates in place
  (no duplicate append). A NEW client appends at the tail.
- **Why async_serve, not just flush_batch, on `.done`**: client sockets are
  edge-triggered; an HTTP request pipelined behind the DB call already fired its
  edge while parked, so we MUST read it on resume or it hangs.
- macOS/kqueue (`async_darwin.c.v`) keeps one-watch-per-fd; pipelining-on-multi is
  Linux-epoll-only for now (the arena is Linux).

## Framework layer (increment 3)
`park()` stops shedding when a conn is merely busy: pick the conn with the shortest queue (or round-robin) and enqueue; shed only when ALL conns are at the N cap. Add a per-conn 1-entry prepared-statement cache (async-db/fortunes use one fixed SQL → drop the per-request Parse) once pipelining lands.

## Validation
1. Driver: pipeline N queries on one conn against a live PG (seed a local table), assert N results in submission order + an ErrorResponse mid-pipeline only fails that query. (pg_async integration tests are PGHOST-gated.)
2. Reactor: the existing `async_pipe` e2e + a new pipelining e2e example.
3. Framework: arena `validate.sh` (X-Cache, correctness) + the async-db/fortunes/crud benchmark.

## Risks
- FIFO response↔request matching relies on strict order + per-query Sync; a garbled frame must not desync the ring.
- The reactor change touches the shared runtime (SSE/streaming consumers) — must stay allocation-free on the hot path (the flat table was deliberately zero-alloc).
- SHARED async pool is a DEAD END: a PG fd lives in ONE worker's epoll; cross-worker acquire fires readiness on the wrong loop. Per-worker + pipelining is the correct shape (matches swerver).
- Re-baseline first; measure on the arena mix, not the local hot-cache box.

## Pipelining invariants (design rationale)
The cross-request pipeline rests on a few hard invariants — get any wrong and the
connection desyncs or corrupts:
1. **FIXED, never-realloc'd per-conn send buffer.** An in-flight pipelined send
   holds the buffer's raw address — if it reallocs mid-send, corruption. Use a
   fixed-capacity []u8 (e.g. 64-512KB), never grow it; reject (shed) if full.
2. **Compact the send buffer per cycle.** Append-only marches to overflow. Each
   flush cycle: snapshot end, send [off,end), then memmove the tail (bytes appended
   DURING the send) to the front + reset offsets.
3. **FIFO routing = the correlation.** Postgres replies in submit order, so NO
   per-query id: route each reply to the FRONT of the in-flight queue, pop at
   ReadyForQuery. (This is increment-1's design.)
4. **Per-query error isolation.** An ErrorResponse fails only its waiter; the
   stream resyncs at the next ReadyForQuery so pipelined siblings still complete.
5. **Prepared-statement cache** (SQL→stmt name, evict on ParseComplete failure) —
   async-db/fortunes use one fixed SQL, so this drops the per-request Parse.
6. **Round-robin a SMALL pool** where each conn multiplexes; evict+reopen broken.
   (Evict+reopen is in: a conn lost to EOF / a socket error / a FATAL is
   skipped by `acquire*()` and re-dialed non-blocking once its in-flight
   queries have drained with their errors — `redial.v`, vanilla#191. That
   drain is why the FIFO contract also binds a request whose flush failed: it
   still parks and consumes its error, or its slot never comes back. A pool
   that follows a `transport.Resolver` (`PgPool.follow`, vanilla#351)
   re-dials from the address table that Resolver keeps fresh, so no re-dial
   resolves the host on the worker.)
7. **A park that times out keeps its queue position.** With a park deadline
   (`Limits.park_timeout_ms`, `watch_fd_persistent_deadline`, vanilla#200)
   any slot can time out, not only the head: its continuation runs once with
   `event_loop.timed_out()` and answers 504 without touching the connection,
   and its slot becomes a tombstone where it is, exactly as when its client
   disconnects. Its reply is still due and still `inflight[k]`, so the
   tombstone consumes it in order when it arrives. `PgConn.cancel()` makes
   that reply come at once (57014) instead of when the query ends.

These are also the read-bound case for the whole approach: the win is mostly CPU
reduction (fewer syscalls/parses per query), and because Postgres replies in order
a handful of pipelined conns saturate the link — so the per-worker 2-conn pool is
fixable by pipelining, not by more connections.

## Transactions on a pipelined pool (vanilla#199)
Every `async_submit` carries its own Sync, so each query is its own implicit
transaction. A pipelined connection is shared, so a transaction that spans
queries must not be: everything pipelined behind a BEGIN runs inside it, a
ROLLBACK undoes it, and after a failed statement every one of them fails with
25P02 until someone rolls back.
- **Status byte.** The ReadyForQuery that completes a query carries the
  session's transaction status: `I` idle, `T` in a block, `E` in a failed
  block. `async_on_readable` stores it (one byte of a frame already in hand);
  `tx_status()` / `in_transaction()` read it. It describes the session as of
  the last completed query, not the queries still in flight.
- **Who may share.** `acquire()` is the exclusive borrow: held until
  `release()`, and `acquire_pipelined()` never shares it — that is the borrow
  for BEGIN … COMMIT across park/resume. `acquire_pipelined()` also skips a
  connection whose status is not `I`, and `acquire()` skips one nobody holds
  (a BEGIN that went through `acquire_pipelined()`, which the docs forbid).
  Nobody will release such a connection, so `maintain()` rolls it back as
  `release()` would, and the slot comes back; a pipelined sender that keeps a
  transaction open across a maintenance tick loses it.
- **Safe release.** `release()` of a connection not in `I` queues a ROLLBACK
  and keeps the slot out of the idle set (`rollback_deadline` set). Nobody is
  parked on the connection any more, so the pool reads the reply itself: the
  next `acquire()` / `acquire_pipelined()` / `maintain()` that passes the slot
  advances it one non-blocking step (`finish_rollback`), exactly as they
  advance a re-dial; `maintain()` ticks at `maintenance_busy_ms` while one is
  in flight. The slot is idle again only once the ROLLBACK's ReadyForQuery
  reports `I`. A lost connection, an error, or no answer within
  `rollback_timeout` (5 s) breaks the connection instead, and the re-dial
  replaces the session. The reactor needs nothing new: the ROLLBACK's reply
  arriving on a pooled fd with no watch is the leftover-fd case (detached,
  not closed), and the next `watch_fd_persistent` re-adds the fd. A release
  of an idle session stays one flag write.
- **Batches.** `async_submit_batch` writes N × Parse/Bind/Describe/Execute and
  ONE Sync: one implicit transaction (atomic, one round trip), and ONE entry
  of the in-flight FIFO, so the reactor's `queue[k] ↔ inflight[k]` alignment
  is unchanged — the request parks once and gets one Result.
  `Result.statement(i)` splits it at each CommandComplete /
  EmptyQueryResponse (views, no allocation); a failure is the PgError of the
  failing statement with its index in `PgError.statement` (the batch's length
  when the commit at the Sync failed). A batch that can never fit the fixed
  send buffer (`ConnConfig.send_buf_cap`), or an empty one, is an error on
  every connection; a momentarily full connection returns false, a shed (#51;
  `submit_batch` returns the typed `Shed` / `FrameTooLarge`, shed.v). A
  batch without BEGIN is as pipeline-safe as one query; one that opens an
  explicit transaction leaves the session in `T` (or `E`) after its Sync and
  belongs on `acquire()`.
- **Retries.** A serialization failure (40001: SERIALIZABLE, and every OCC
  conflict on Aurora DSQL, often at COMMIT) means running the whole
  transaction again. `TxRetry` holds no state: `retry(attempt, err)`,
  `backoff_ms(attempt)` (full jitter, from the monotonic clock) and
  `park_backoff(attempt, ...)`, which parks the request on a one-shot
  timerfd armed for that wait.
- **The wait between attempts is spent without the connection.** The
  continuation that reads the 40001 releases the connection, parks on the
  timer, and acquires a connection again when it fires
  (`examples/pg_transactions`); the attempt number travels in the watch
  payload. A continuation parked on a pooled fd may step to another fd
  whether its request is a pipelined head or holds the connection alone,
  and a tombstone's re-arm takes the new continuation and payload
  (vanilla#247). A client that disconnected ends its retries at that step:
  the runtime closes the timer once the draining run returns and never
  resumes the request, so the release before the step is what returns the
  connection. The example closes the timer in the next continuation (the
  attempt's reply), after the runtime detached it; the continuation that
  steps away from it may close it as well: before it detaches a
  stepped-away fd, the runtime checks that the number is still an app's open
  fd and not a connection accepted on it (vanilla#337).
  (Before #247 a step after a DB reply lost the FIFO alignment, so the
  example re-ran each attempt at once on the held connection.)

## Backpressure contract (vanilla#51)
A pipelined query is refused for one of three reasons, and each needs a
different answer, so the refusal is typed (`shed.v`):
- **`Shed`** — momentarily full; nothing was sent. `.reason` is
  `no_connection` (every connection held by `acquire()`, in a transaction,
  rolling back or broken), `pipeline_full` (every candidate at
  `max_inflight`) or `send_buffer_full` (a pipeline slot, but no send buffer
  with room for the frame). The caller answers 503 with `Retry-After`. The
  three `Shed` values are constants, so a shed allocates nothing: under
  overload the shed path is the hot path, and under `-gc none` a boxed error
  per shed would leak.
- **`FrameTooLarge`** — the frame is larger than the connection's send
  buffer (`PgConn.max_frame_len()`: `ConnConfig.send_buf_cap`, 64 KiB by
  default): it can never be sent there. `submit` checks it before anything
  else, so the answer does not depend on what is in flight;
  `acquire_pipelined_for` answers it only when the frame fits no
  connection's buffer. It is checked from the frame's computed size, so an
  oversized frame is never serialized, and it allocates nothing (each
  connection boxes its own when it is made): when the size comes from the
  request, a client drives this path.
- The constants are built by a function call (`shed_error`): V 2f94b87
  emits a const `IError(Struct{...})` of plain fields as a zero C
  initializer, which panics on `msg()`.
- **`ConnBroken`** — the connection is lost. `acquire_pipelined_for` never
  returns one, so only a caller that took a connection some other way sees it.

`acquire_pipelined_for(frame_len)` returns the shortest pipeline among the
connections whose send buffer has room for `frame_len` bytes now
(`max_frame_len() - (send_len - send_off)`), skipping exactly what
`acquire_pipelined()` skips. `query_frame_len` / `batch_frame_len` give the
size without serializing. `submit` / `submit_batch` are `async_submit` /
`async_submit_batch` with the reason as a typed error. A worker is single
threaded, so nothing changes between `acquire_pipelined_for` and the submit
on the connection it returned: that submit succeeds, and a shed from
`acquire_pipelined_for` is final for the request. The existing calls keep
their `none` / `false`.

**No `acquire_pipelined_except(idx)`.** It was proposed for retrying on
another connection after a refused submit. With `acquire_pipelined_for` that
refusal does not happen (the connection was chosen because the frame fits),
and `except(idx)` would not be enough anyway: with three or more connections
the second choice can lack room too, which needs an exclusion set — what
`acquire_pipelined_for` already computes in one pass.

**`max_inflight` is configurable** (`ConnConfig.max_inflight`, 1..256,
default 8). Each slot keeps a reply accumulator for the life of the
connection: 16 KiB, grown to the largest reply it held (`pop_front` writes
the grown buffer back), so the cost is at least `max_inflight × 16 KiB` per
connection. The limit is 256, not more: the in-flight FIFO pops with
`delete(0)`, which moves the queries behind the front, so a pop costs about
2.4 µs more at depth 1024 than at 8 (a review microbenchmark, `-prod`).
Measured (1 worker, 2 connections, PostgreSQL 18 in Docker on loopback,
`wrk -t4 -d8s`, Ryzen 7 5800H), with `bench/pg_async/e2e_server` and
`PG_MAX_INFLIGHT`, its pipelined handler switched to
`acquire_pipelined_for` + `submit` (the committed one still uses
`acquire_pipelined` + `async_submit`; for these 3-row queries both shed at
the same points, since no send buffer fills):

| path | wrk conns | max_inflight | 200/s | shed % | p50 | p99 | RSS peak |
|---|---|---|---|---|---|---|---|
| `/dbp` (cheap query) | 64 | 4 | 5,414 | 85.4 | 1.4 ms | 4.3 ms | 3.7 MiB |
| | 64 | 8 | 5,119 | 73.0 | 2.8 ms | 12.7 ms | 3.8 MiB |
| | 64 | 16 | 5,211 | 42.4 | 6.9 ms | 21.2 ms | 3.8 MiB |
| | 64 | 32 | 8,323 | 0 | 6.6 ms | 21.4 ms | 4.0 MiB |
| | 64 | 64 | 8,562 | 0 | 6.5 ms | 19.2 ms | 4.3 MiB |
| | 256 | 4 | 866 | 95.6 | 10.4 ms | 35.1 ms | 5.3 MiB |
| | 256 | 8 | 1,713 | 91.7 | 11.0 ms | 28.2 ms | 5.4 MiB |
| | 256 | 32 | 6,670 | 65.2 | 11.8 ms | 38.0 ms | 5.6 MiB |
| | 256 | 64 | 7,894 | 34.2 | 19.9 ms | 58.4 ms | 5.9 MiB |
| `/dbslow` (5 ms query) | 64 | 4 | 361 | 98.9 | 1.4 ms | 23.0 ms | 3.7 MiB |
| | 64 | 8 | 357 | 98.6 | 1.7 ms | 46.0 ms | 3.8 MiB |
| | 64 | 32 | 353 | 6.1 | 179.5 ms | 186.1 ms | 4.0 MiB |
| | 64 | 64 | 358 | 0 | 176.9 ms | 189.2 ms | 4.3 MiB |
| | 256 | 64 | 356 | 99.3 | 2.6 ms | 347.2 ms | 5.9 MiB |

- A connection runs its pipeline one query after another, so a deeper
  pipeline only helps when the query is cheap and the round trip dominates.
  For a 5 ms query, 2 connections finish ~360 queries/s whatever the depth:
  a deeper pipeline turns sheds into queueing (p50 from 1.7 ms to 180 ms at
  32), with no more queries done.
- With a cheap query, depth raises throughput until connections × depth
  covers the offered concurrency (64 → 0 sheds at 32). Below that, 503s are
  not free: `wrk` resends at once (it ignores `Retry-After`), and at 256
  connections the worker spends most of its time answering 503s (866/s
  served at depth 4).
- RSS barely moves with depth: +0.5 MiB at idle from 4 to 64 on 2
  connections, against 1.9 MiB of accumulators allocated. They are touched
  only as far as the replies reach (3 rows here); replies that fill them make
  the whole `max_inflight × 16 KiB` per connection resident, and larger
  replies grow them for good. The HTTP connections, not the depth, move peak
  RSS.

So the default stays 8: raise it for cheap, round-trip-bound queries, and
bound the latency it adds with a park deadline (`Limits.park_timeout_ms`).

**`send_buf_cap` is configurable** (`ConnConfig.send_buf_cap`, 16 KiB..16 MiB,
default 64 KiB, #355): each connection's send buffer, and so the largest
frame the pipelined path sends (`PgConn.max_frame_len()`; the public
`max_frame_len` const is the default). The buffer is still fixed, so
invariant 1 holds at any size: allocated once at connect, kept across
re-dials, never grown. It costs `connections × workers × send_buf_cap`, on
top of the reply accumulators, and the serialization scratch
(`submit_scratch`) doubles up to the largest frame sent and stays there: up
to the power of two at or above `send_buf_cap` per connection, since every
submit path sizes its frame before it serializes it. `acquire_pipelined_for`
measures the frame against each connection's own buffer: it skips a
connection the frame does not fit, sheds while one it fits has no room, and
says `FrameTooLarge` (naming the largest buffer) only when it fits none.
`append_send` copies with `memcpy` and slides the unsent bytes to the front
(`memmove`) only when the frame has no room behind them: the buffer still
never marches forward (invariant 2), and a small query queued while a large
frame is being sent copies only itself, not that frame's unsent tail. Over
TLS the size changes nothing: a flush hands Mbed TLS the unsent bytes, which
it takes one record (16 KiB) per call.

**A bounded wait queue (proposal, not implemented).** Instead of shedding, a
request would wait, in a per-pool FIFO bounded in length and in time, for a
pipeline slot.
- For: a burst shorter than a query's time is absorbed instead of answered
  503; a waiter, unlike a pipelined query, has sent nothing, so it can be
  dropped on its deadline or on a client disconnect without a CancelRequest.
- Against: it needs the reactor to resume a waiting continuation when a slot
  frees, which pg_async cannot do alone (a timer or a self-pipe in the
  runtime: a `core` change); each waiter holds its request's memory;
  saturation that is not transient only turns into latency, as the
  `/dbslow` rows show for a deeper pipeline, which is already a bounded queue
  (in the socket instead of in the pool); and with `Retry-After` honoured by
  clients, a short burst mostly passes.
- Recommendation: not now. Revisit with a workload that sheds at low average
  utilization (bursts), measured as above.

## Local validation harness
`bench/pg_async/` pipeline-tests pg_async locally against a seeded PG
(`pg_async/testdata/throwaway_pg.sh`): `e2e.sh` (req/s, latency, server CPU per
request for the `acquire()` and `acquire_pipelined()` shapes), `leak.sh` (RSS
slope per request under `-gc none` vs Boehm, fd counts, for steady, error-heavy,
disconnect and churn loads), `callgrind.sh` (allocations per request) and
`codec_bench.v` (the driver's CPU per query, no server). Deterministic failure
paths run in CI against `pg_async/testdata/fake_pg.py`, a scriptable fake
server; `tests/pg_async_e2e_test.v` checks the FIFO alignment end to end
through the epoll reactor.

## Parser-correctness regression to bank
header+body-arrive-in-ONE-recv + chunked-terminator-read-on-a-SECOND-recv can cause
a buffer-offset underflow → permanent park (hang) on an open socket. Add a vanilla
parser test for both cases.
