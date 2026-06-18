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

These are also the read-bound case for the whole approach: the win is mostly CPU
reduction (fewer syscalls/parses per query), and because Postgres replies in order
a handful of pipelined conns saturate the link — so the per-worker 2-conn pool is
fixable by pipelining, not by more connections.

## Local validation harness
A wrk lua script mirroring HttpArena's async-db/crud mixes lets us pipeline-test
pg_async locally against a seeded PG (solves "can't pipeline-test locally").

## Parser-correctness regression to bank
header+body-arrive-in-ONE-recv + chunked-terminator-read-on-a-SECOND-recv can cause
a buffer-offset underflow → permanent park (hang) on an open socket. Add a vanilla
parser test for both cases.
