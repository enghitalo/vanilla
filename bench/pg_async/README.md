# pg_async benchmarks and leak harness

Local tools for measuring `pg_async` (the native PostgreSQL client). The
numbers they print only mean something as an A/B on one quiet machine: run them
on `main`, run them on your branch, and compare against the spread. Shared CI
runners are too noisy for load numbers (see `bench/load.sh`). The codec phases
are also A/B'd on every push to `main` by `bench.yml` (`bench/ci_bench.sh`).

| tool | answers | how |
|---|---|---|
| `codec_bench.v` | CPU per query in the driver itself: `async_submit` serialization, `async_on_readable` recv + framing, `Result.rows()` + accessors, the decoders | canned async-db-shaped replies fed through a `socketpair(2)`, no server; one phase per run through `bench/measure.sh` (min / median / spread) |
| `e2e.sh` | end-to-end req/s, p50 / p99 latency and **server CPU µs per request**, for `acquire()` (`/db`) and `acquire_pipelined()` (`/dbp`) | `e2e_server/` against a seeded local PostgreSQL, `wrk`, fresh server per run, pinned cores, `-prod -gc none` |
| `leak.sh` | RSS growth in bytes per request (`-gc none` minus Boehm) and the open-fd count before/after, per load shape | steady, exclusive, 50 % errors, clients disconnecting mid-query, backends killed under load |
| `callgrind.sh` | allocations per request in steady state, by call site (must be 0) | `valgrind --tool=callgrind --instr-atstart=no`, instrumented after a hard warm-up, parsed by `callgrind_allocs.py` |

```sh
# a throwaway, seeded PostgreSQL (initdb + pg_ctl; the scripts start one on
# their own when PGHOST is unset)
eval "$(pg_async/testdata/throwaway_pg.sh start)"

v -prod -gc none -d pg_async_bench -o /tmp/pgcodec bench/pg_async/codec_bench.v
bench/measure.sh /tmp/pgcodec submit     # also: frame, rows, decode
bench/pg_async/e2e.sh                    # RUNS, DURATION, WORKERS, POOL, GC=boehm
bench/pg_async/leak.sh                   # or one shape: leak.sh errors
bench/pg_async/callgrind.sh dbp errors

pg_async/testdata/throwaway_pg.sh stop
```

`codec_bench.v` reaches into the connection through
`pg_async/bench_hooks_d_pg_async_bench.v`, which only compiles with
`-d pg_async_bench`; a normal build carries none of it.
