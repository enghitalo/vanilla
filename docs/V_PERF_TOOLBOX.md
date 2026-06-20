# V performance toolbox (for vanilla's hot paths)

Notes verified against the installed V source (`vlib/builtin/`) and emitted C
(`v -prod -o out.c`). The guiding rule: **settle codegen/perf questions by
reading the generated C, not by guessing.**

## The two build modes: default GC vs `-gc none`

vanilla can run either way, and the rules flip between them:

- **Default (`-prod`, Boehm GC).** Allocations are reclaimed, but the GC's
  stop-the-world serializes all workers, so per-request allocation is **GC
  pressure** that caps how many cores do useful work. The "Allocation facts"
  below (noscan, scan-on-grow) are this mode.
- **`-prod -gc none` (the arena/production build).** No GC, **nothing is ever
  freed**. A per-request allocation is therefore a permanent **leak** — RSS grows
  linearly with requests served. Allocations are plain libc `malloc`/`calloc`
  (so tools like callgrind/heaptrack see them, unlike Boehm's `GC_malloc`). This
  is the build to optimize for; the hot paths must be **literally allocation-free**.

Why `-gc none` at all: on a thread-per-core server the shared GC doesn't scale —
a microbenchmark showed default-GC aggregate allocation throughput flat from 1→16
threads (16 cores ≈ 1 core; [vlang/v#27488](https://github.com/vlang/v/issues/27488)).

> **Measuring a leak under `-gc none`:** a rising RSS line is *not* proof — a
> Boehm build of the same server also grows (glibc arena, connection buffers,
> thread stacks). Build both, drive identical load, and report
> **`gc_none_growth − boehm_growth`**. That difference is the genuinely
> collectable per-request allocation; everything else is the unavoidable floor.

## Inspecting what V actually emits

- `v -prod -o out.c ./examples/<name>` — write the C without compiling; `grep` it.
- `v -show-c-output …` — full C-compiler output on error.
- `v -showcc …` — the exact C compiler command.

This is how we found (a) the `epoll_data` union GC-codegen bug and (b) that
`[]u8{cap:N}` is already noscan/uninit (so a big-cap regression was GC pressure,
not zeroing).

## Attributes (functions / structs)

| Attribute | Effect | Use for |
|---|---|---|
| `@[inline]` | force inline | tiny hot helpers (`find_byte`, `ascii_ci_eq`) |
| `@[direct_array_access]` | skip bounds checks in the fn | verified-safe index loops (parser) |
| `@[manualfree]` | opt out of autofree | deterministic `defer { x.free() }` |
| `@[heap]` | struct always heap-allocated | long-lived shared structs |
| `@[packed]` | no padding | wire/ABI structs (e.g. a framed header) |
| `@[markused]` | keep an unused symbol in the build | reference impls (ws codec) |

`@[direct_array_access]` removes a real cost but also a real safety net — only on
loops you've proven in-bounds.

## Array flags  `unsafe { arr.flags.set(.x | .y) }`

From `vlib/builtin/array.v`:

- `.noslices` — on `<<`, free the old data block immediately (only if no slices reference it).
- `.noshrink` — `.delete` won't realloc+free; with `.noslices` it moves in place.
- `.nogrow` — never grow past `cap`. `.nogrow` + `.noshrink` ⇒ a truly fixed heap array.
- `.nofree` — `.data` is never freed.
- `.noscan_data` — data sits in a no-scan (atomic) GC block; stays atomic across clone/resize.

Already used here for the per-worker epoll fd arrays
(`.noslices | .noshrink | .nogrow`).

## Allocation facts (the ones that bit us)

- `[]u8{len: 0, cap: N}` → `__new_array_with_default_noscan` → `GC_MALLOC_ATOMIC(N)`:
  **uninitialized (not zeroed), not scanned.** V auto-picks noscan for
  pointer-free element types.
- A big per-request `cap` costs via **GC allocation pressure** (bytes/sec churn →
  more collections), not zeroing. Keep per-request buffers small; better, reuse
  one per worker (zero per-request allocation).
- `grow_cap` re-allocates via the **scan** variant — growing a `[]u8` past `cap`
  loses the atomic property.
- A fixed-size stack array `[N]u8{}` **does** zero N bytes per call — don't make
  big ones on the hot path.
- `recv` into spare capacity to avoid a scratch buffer + second copy:
  `recv(fd, &u8(buf.data) + buf.len, buf.cap - buf.len)` then `unsafe { buf.len += n }`.
- **Allocation cost is hidden at low core counts and explodes under GC at scale.**
  On the 64-core arena, eliminating per-request allocation in the handler was a
  multiple-x swing (json **+322%**, pipelined **+1365%**) where the *same* change
  measured within noise at 16 cores — Boehm's stop-the-world serializes every
  worker, so churn caps how many cores do useful work. Treat any per-request
  `[]u8` / `string` / `.bytes()` / `all_before()` / builder as a scaling tax:
  precompute `const` keys, parse ints in place, and append into a reused buffer.
  Corollary: confirm perf changes on a high-core run, not just a laptop.

## Pure C escape hatch

Allowed when it doesn't introduce a security problem. Good for: precise
allocation (`C.malloc` = unzeroed, unmanaged, manual free), tight byte/bit ops,
syscall wrappers, and sidestepping V codegen quirks. Example in the tree:
[`http_server/epoll/epoll_shim.h`](../http_server/epoll/epoll_shim.h) keeps the
`union epoll_data` access in C so V's GC never mislabels the union.

## Beyond `[]u8`

Arrays aren't the only structure. Consider: `map`, fixed `[N]T` (stack), channels,
and custom layouts — ring buffers, arenas, `@[packed]` structs over raw C memory
— when array alloc/grow semantics don't fit. The request read path's target is a
**per-worker arena / reusable buffer** so the hot path allocates nothing.

## Profiling allocations (under `-gc none`)

Two harnesses, one rule. (Both spin a throwaway, seeded Postgres and clean up;
recipes are reproducible.)

**callgrind — allocations per request, by call site.** The scalpel: it answers
*which function allocates and how many times per request*. The recipe that makes
it usable:

- **Build with `-cc gcc`, not the default tcc** — callgrind can't resolve V app
  symbols from tcc's debug info (everything shows as a hex address); gcc emits
  DWARF, so `main__*` / `pg_async__*` are named.
- **`--instr-atstart=no`, then `callgrind_control -i on` *after* a hard warmup** —
  so pool bring-up + SCRAM + buffers reaching high-water run uninstrumented and
  only steady-state per-request work is counted.
- **Don't dump with a live `callgrind_control -d`** — it hangs when every worker
  is parked in `epoll_wait`. **`SIGTERM`** the valgrind process: the signal
  interrupts the syscall and callgrind flushes its dump on `fini`.
- **Parse the raw dump for allocator call counts** — build the id→name map, sum
  `calls=` to each V allocator entry (`vcalloc`, `malloc_uninit`, `memdup`, …)
  by immediate caller, divide by measured requests. (The self-cost table doesn't
  show call counts, and allocators are cheap-but-frequent, so they never surface
  there.)
- **Drive the load shape that exposes the bug:** per-request allocs show under
  any load; **pipeline-queue** allocs need *concurrent* load with `clients > pool
  conns`; **per-connection** allocs need *connection churn* (many short-lived
  connections — what real load generators do, reconnecting tens of thousands of
  times per run).

**RSS slope — the leak in bytes/request.** Build `-gc none` **and** Boehm, run
each under load for a fixed window sampling `VmRSS`, report bytes/request + the
trajectory (linear climb = real leak; jump-then-flat = one-time setup). Subtract
the Boehm floor. A **hard RSS cap** kills a runaway so it's safe unattended.

**heaptrack caveat:** it sees `-gc none` allocations, but attributes from process
start, so one-time bring-up (SCRAM/PBKDF2, lazy init) blurs the per-request
signal. callgrind with post-warmup instrumentation is the disambiguator.

## V allocation gotchas (filed upstream)

- **Empty/zero-length array literals allocate.** `[]T{}` (and a default-init `[]T`
  struct field) call `alloc_array_data(0)` → `vcalloc(header)` even at `len == 0,
  cap == 0`. Under `-gc none` each is a permanent leak. Append elements or use a
  module `const` instead. ([vlang/v#27487](https://github.com/vlang/v/issues/27487))
- **`array.slice()` (`a[start..end]`) marks the source buffer on every call.**
  It does an unconditional `mark_buffer_has_slices()` (a malloc data-header pointer
  round-trip + flag write) plus bounds checks and the result-struct build — ~11% of
  the plaintext request hot path's `-prod` instructions when slicing the read buffer
  per request, yet pure waste for a transient read-only view (`has_slices` is only
  consulted by `delete`/shrink, which a manually-managed reused buffer never does).
  Fix: a non-owning window built by hand — copy the array header, repoint
  `data`/`len`/`cap`, `unsafe { flags.clear(.managed) }` so it is never freed and a
  sub-slice of it also skips marking (compiles to a struct copy + 3 stores, zero
  alloc). See `backend_epoll`'s `buf_view`. ([vlang/v#27507](https://github.com/vlang/v/issues/27507))
- **Allocation does not scale across cores** under the default GC (the reason for
  `-gc none`). ([vlang/v#27488](https://github.com/vlang/v/issues/27488))
- **`error()` boxes a `MessageError`** — even when the caller discards it with
  `or {}`. So a `!int` "not found" allocates per call; prefer a `-1`-returning
  variant (`find_byte_idx`, not `find_byte`) on hot paths.
  ([vlang/v#27508](https://github.com/vlang/v/issues/27508))
- **`int.str()` / `${}` allocate** — format integers into a reused buffer with an
  itoa helper (`wi`/`emit_int`), never `.str()` on the response hot path.
  (`strings.Builder.write_decimal` exists for the Builder target; no `[]u8`-buffer
  formatter does — [vlang/v#27509](https://github.com/vlang/v/issues/27509))
- **`runtime.nr_cpus()` ignores CPU affinity** — it is `sysconf(_SC_NPROCESSORS_ONLN)`
  = every online *host* core, blind to `taskset`/cpuset and cgroup CPU pinning. A
  server pinned to N cores (a profiling run, or a container capped at N CPUs on a
  bigger host) that sizes its worker pool from `nr_cpus()` spawns host-many workers
  and oversubscribes them N-ways. The worker count instead comes from
  `core.worker_count()`: a `VANILLA_WORKERS` env override → else the
  `sched_getaffinity` mask bit-count (`core/affinity_linux.c.v`) → else `nr_cpus()`.
- **`&Struct{}` as an `if`-*expression* branch** has miscompiled to invalid C in
  some build modes — use the statement form
  (`mut x := &T(unsafe{nil}); if … { x = … } else { x = &T{…} }`).
  ([vlang/v#27329](https://github.com/vlang/v/issues/27329))
