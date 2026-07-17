# V performance toolbox (for vanilla's hot paths)

Notes verified against the installed V source (`vlib/builtin/`) and emitted C
(`v -prod -o out.c`). The guiding rule: **settle codegen/perf questions by
reading the generated C, not by guessing.**

## The two build modes: default GC vs `-gc none`

vanilla can run either way, and the rules flip between them:

- **Default (`-prod`, Boehm GC).** Allocations are reclaimed, but the GC's
  stop-the-world **collection** pauses all workers, so heavy per-request allocation
  is still **GC pressure** that caps how many cores do useful work. (Allocation
  *throughput* itself now scales — see the note below.) The "Allocation facts"
  below (noscan, scan-on-grow) are this mode.
- **`-prod -gc none` (the arena/production build).** No GC, **nothing is ever
  freed**. A per-request allocation is therefore a permanent **leak** — RSS grows
  linearly with requests served. Allocations are plain libc `malloc`/`calloc`
  (so tools like callgrind/heaptrack see them, unlike Boehm's `GC_malloc`). This
  is the build to optimize for; the hot paths must be **literally allocation-free**.

Why `-gc none` at all: historically the shared GC didn't scale — aggregate
allocation throughput was flat 1→16 threads (16 cores ≈ 1 core;
[vlang/v#27488](https://github.com/vlang/v/issues/27488)). **That is now fixed**
by thread-local allocation (`GC_malloc` no longer takes a global lock), so on the
pinned V the default GC scales. `-gc none` is therefore no longer about the alloc
lock; its remaining value is dodging Boehm's stop-the-world *collection* entirely
on alloc-heavy paths, plus plain-libc `malloc` that profilers can see — and it is
only safe where the hot path is **literally allocation-free** (otherwise it leaks).

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
- **`s[a..b]` / `string.substr` allocates a fresh heap string** every call
  (`malloc_noscan(len+1)` + `memcpy`). Under `-gc none` a result used-and-discarded
  on the hot path **leaks** (nothing frees it); under the default GC it is
  per-request churn. For a **non-retained lookup key** (e.g. a map key) use a
  zero-copy view: `unsafe { tos(ptr, len) }` — map lookup only hashes the key bytes
  and never retains the key, so a view is safe. Empirical (isolated, same
  `map[string]int` + 20M lookups, `-gc none`, only the key construction differs):
  `route[8..]` → **+625 MiB** (monotonic, never plateaus) vs `tos(route.str+8,
  route.len-8)` → **+28 KiB** flat — a ~22,000x gap for the same work. The vanilla
  LIBRARY is already the reference (the substr leak lived in an HttpArena benchmark
  handler, not here): [`static_assets/static_assets.v:273-281`](../static_assets/static_assets.v)
  builds the key as `key := tos(&buf[rs], rel_len)`, a view straight into the
  request buffer, "never retained, so routing costs no allocation."
- **Zero-copy views, the pair to reach for:** `unsafe { (&buf[start]).vbytes(len) }`
  builds a `[]u8` over existing memory — header-only, "the data is reused, NOT
  copied" (builtin), and none of `a[start..end]`'s per-call slice-marking.
  `unsafe { tos(ptr, len) }` is the `string` twin. Both are safe wherever the
  callee only *reads* the input (hash/hmac/KDF inputs, base64 decode, map
  lookups, comparisons) and the view does not outlive the buffer. Guard
  `len > 0` before `&buf[start]`. Used across
  [examples/auth](../examples/auth/src/main.v) for password/API-key/bearer
  windows into the request buffer.
- `strings.Builder` **is** `[]u8` (`pub type Builder = []u8`): pass a builder
  mid-assembly to any `[]u8`-taking API (hash it, sign it) and keep appending;
  `return sb` satisfies a `[]u8` return. Saves the `.str()` copy when the
  result is consumed as bytes.
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
[`epoll/epoll_shim.h`](../epoll/epoll_shim.h) keeps the
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

**io_uring caveat:** valgrind/callgrind does **not** emulate io_uring — an
io_uring server boots under callgrind but never serves (the ring delivers no
completions, so `accept`/`recv` never fire and the client hangs). Profile the
**epoll** backend under callgrind; the request-parsing / handler / response code is
shared, so its per-request instruction counts carry over. For the io_uring-specific
glue, read the source or use a tool that supports the ring. (perf works too but
needs `perf_event_paranoid ≤ 2` / sudo.)

## V allocation gotchas (filed upstream — all fixed)

Every gotcha below was filed upstream and is **fixed as of the pinned V master
build** (`badd3466…`). Each entry notes what changed and what vanilla still does.

- **Empty/zero-length array literals allocated.** `[]T{}` (and a default-init `[]T`
  field) used to call `alloc_array_data(0)` even at `len == 0, cap == 0` — a
  permanent leak under `-gc none`. **Fixed:** `__new_array` now allocates only when
  `cap > 0`, so a zero-len/zero-cap literal is alloc-free. (Appending or a module
  `const` is no longer required to avoid the leak.)
  ([vlang/v#27487](https://github.com/vlang/v/issues/27487))
- **`array.slice()` (`a[start..end]`) marks the source buffer on every call.**
  Unconditional `mark_buffer_has_slices()` (a malloc data-header round-trip + flag
  write) + bounds checks + result-struct build — ~11% of the plaintext hot path's
  `-prod` instructions when slicing the read buffer per request, yet pure waste for
  a transient read-only view. **Still marks by default** on the pin (V added a
  `.noslices` flag, but only for the `<<`-free-in-place case; `slice()` itself is
  unchanged), so vanilla keeps the hand-built non-marking window — copy the header,
  repoint `data`/`len`/`cap`, `unsafe { flags.clear(.managed) }` (struct copy + 3
  stores, zero alloc). `buf_view` now lives in **both** the epoll (`backend_epoll`)
  and io_uring backends. ([vlang/v#27507](https://github.com/vlang/v/issues/27507))
- **Allocation did not scale across cores** under the default GC — the original
  reason for `-gc none`. **Fixed** by thread-local allocation: `GC_malloc` no longer
  serializes on a process-global lock, so the default Boehm GC now scales with
  workers. Use `-gc none` only where the hot path is already alloc-free (the GC-lock
  penalty it avoided is gone). ([vlang/v#27488](https://github.com/vlang/v/issues/27488),
  [#27486](https://github.com/vlang/v/issues/27486))
- **`error()` boxed a `MessageError`** — even when discarded with `or {}`, so a
  `!int` "not found" allocated per call. **Fixed:** builtin now exports
  `error_sentinel`, a cached allocation-free `IError`; `return error_sentinel` from a
  hot `!T` path is alloc-free (like `none` for `?T`). A `-1`/sentinel-returning twin
  (`find_byte_idx` vs `find_byte`; `frame_request_length_lim_idx`) is still used where
  the **`Ok`-side** Result construction also matters — `error_sentinel` only removes
  the error-side box. ([vlang/v#27508](https://github.com/vlang/v/issues/27508))
- **`int.str()` / `${}` allocate.** **Fixed:** the stdlib now has a `[]u8`-buffer
  formatter — `strconv.write_dec(n i64, mut buf []u8)` and `write_dec_u(n u64, …)`
  write decimal digits into a caller buffer with no allocation. Use these (or
  `strings.Builder.write_decimal` for the Builder target) instead of `.str()` on the
  response hot path. ([vlang/v#27509](https://github.com/vlang/v/issues/27509))
- **`runtime.nr_cpus()` ignores CPU affinity** *(unchanged upstream — handled
  vanilla-side)*: it is `sysconf(_SC_NPROCESSORS_ONLN)` = every online *host* core,
  blind to `taskset`/cpuset/cgroup pinning. `core.worker_count()` sizes the pool from
  a `VANILLA_WORKERS` env override → else `nr_cpus()`. **Set `VANILLA_WORKERS`** when
  pinned to N cores or in a CPU-capped container, or the pool over-subscribes. (An
  earlier `sched_getaffinity`-based auto-count was reverted — it under-sized the DB
  profiles, which need the full host count.)
- **`&Struct{}` as an `if`-*expression* branch** miscompiled to invalid C in some
  build modes. **Fixed** in cgen — the statement-form workaround
  (`mut x := &T(unsafe{nil}); if … { x = … } else { x = &T{…} }`) is no longer
  required. ([vlang/v#27329](https://github.com/vlang/v/issues/27329))
