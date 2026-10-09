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
- `v -warn-about-allocs …` — a warning per allocation site (array/struct/string
  building, locals the compiler moves to the heap). It cannot tell startup code
  from the request path, so confirm a hot path with a counter: a
  `gc_heap_usage().total_bytes` delta over N requests in a test
  (`test_routing_allocates_nothing` in examples/veb_like).

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
  handler, not here): [`static_assets/static_assets.v:388-396`](../static_assets/static_assets.v)
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

## Comptime, escape and allocation checks (V `5516000`)

Found while making the routers allocation-free, and re-checked in the emitted C
on V 0.5.2 `5516000` (2026-10-09), after the upstream fixes they led to.

- **`method.attrs` inside `$for` is free** since vlang/v#29404. `for attr in
  method.attrs` unrolls into one block per attribute; `method.attrs.len`,
  `.contains('x')` and `[i]` fold to constants, in `$if` too. (Before, it built a
  heap array per method on every pass: the old `examples/veb_like` paid 13
  allocations to reach its last route.) A `$for` that calls `app.$method(...)`
  behind an integer compare compiles to a jump table with the handlers inlined.
- **Route attributes can be parsed at compile time** (vlang/v#29601, #29723):
  `$for attr in method.attributes`, `attr.name.all_after(' ')`,
  `$for seg in path.split('/')` and `$if seg.starts_with(':')` fold and unroll,
  so a router can generate one matcher per route. Against veb_like's trie on
  bench/router's routes (aligned builds), that was 3–5% faster for routes with
  two or three params, but 6–25% slower for static routes, catch-alls and 404s,
  and slower for 405 (no prebuilt `Allow`); it is linear in the number of routes
  and picks the first declared route, not the most specific. veb_like keeps the
  trie.
- **A struct holding a fixed array stays on the stack one call deep**
  (vlang/v#29546). Passed by `mut` or `&` to a callee that reads or writes its
  fields itself, it stays local; if that callee passes it on, even to a method
  (`p.get(name)`), the struct is still `memdup`'d per call. `veb_like.Params` is
  handed to handlers that call `p.get`, so it keeps eight plain fields
  (`v0`…`v7`, indexed through the first one's address). `-warn-about-allocs`
  reports the move ("local moved to the heap: its fixed array storage may
  escape"); vlang/v#29801 asks for summaries that follow such calls. A bare
  fixed-array local passed as `&a[0]` was never moved.
- **An address passed straight into a comptime call escapes.** `&p` given to
  `app.$method(...)` inside the `$for` moves `p` to the heap ("its address
  escapes"), whatever its type; the same call behind an ordinary method keeps it
  on the stack. veb_like matches in one method and calls handlers from another
  (`dispatch`), which is why its `Params` stays local (vlang/v#29801).
- **Forwarding a `mut` parameter in a comptime call works** since
  vlang/v#29404: `app.$method(req, p, mut out)`.
- **Methods are values** since vlang/v#29551: `App.one` and `T.$method` are
  plain `fn (&App, …)` pointers, no closure (`app.one` still allocates one).
  Dispatching through a table of them measured within a few percent of the
  `$for` jump table, so veb_like keeps the `$for`.
- **`@[noalloc]` exists** (vlang/v#29567, `doc/noalloc.md` in V) but, on
  `5516000`, it rejects `&&` and `||`, struct literals whose type has field
  defaults, and string views (`tos`, returning a `string`), so the routers can't
  carry it without contortions (vlang/v#29800). The runtime tests
  (`test_routing_allocates_nothing`) remain the check.

## Appending a static response

Measured on a 102-byte `200 OK … Hello, World!` response appended to a reused
`out` (`-prod -gc none`, Ryzen 7 5800H, best of 7 × 100M appends, V 0.5.2 0137eb5):

| const and append | ns/append |
|---|---|
| `r = '…'.bytes()`, `out << r` | 5.1 |
| `r = '…'`, `unsafe { out.push_many(r.str, r.len) }` | 5.1–5.2 |
| `r = [u8(…), …]!`, `unsafe { out.push_many(&r[0], r.len) }` | 5.2–5.4 |
| `r = '…'`, `core.append_str(mut out, r)` (below) | 2.4–2.8 |

- **The call matters, not the storage.** `<<` and `push_many` go through the generic
  `array__push_many` / `array_push_many_ptr` (`ensure_cap`, a size multiply,
  `memcpy@plt`), which is never inlined. So a `.bytes()` const, a string const and a
  fixed `[N]u8` cost the same, and a fixed array's compile-time length buys nothing.
- **gcc already knows a `const` string's bytes and length.** Inlined, the append is
  `add $0x66` plus six 16-byte `movups`, the same code as for a fixed `[N]u8`. A
  `.bytes()` const can't get there: its data is a heap copy made at startup, so even
  an inlined append calls `memcpy` (4.7–4.9 ns).
- **Don't slice a fixed array to append it.** `out << fixed[..]` builds a new heap
  array on every call (`new_array_from_c_array` + `array_slice`), `-prod` included;
  under `-gc none` that is a per-request leak.

The helper is [`core.append_str`](../core/append_str.v): the inlined fast path
is a capacity check plus `vmemcpy`, and growing `out` or appending to a slice
view goes to a `noinline` `push_many`, so it behaves exactly like `push_many`.
Keeping that fallback out of line is what keeps the fast path at 2.4–2.7 ns
(4.6–4.8 ns for `out << r` in the same run); inlined, the check alone cost
~0.7 ns.

The win is the `const` string's folded copy. With a runtime string there is
nothing to fold, and the inlined check measured slower than `push_many`:
pg_async's `put_cstr_s` (every query's SQL text and statement/portal names)
took the codec bench's `submit` phase from 0.322 s to 0.335–0.343 s (+4%,
aligned builds, min of 7, V 0.5.2 5516000;
[#220](https://github.com/enghitalo/vanilla/issues/220)), so it uses
`push_many`.

Scale: ~2.3 ns per response, against 50–150 ns of in-process work per request
([#239](https://github.com/enghitalo/vanilla/issues/239)) and microseconds once
syscalls count. It is still the default for static responses (see
[BEST_PRACTICES §3a](BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)):
free, and it drops the startup heap copy of every `.bytes()` const. A string →
`[N]u8` literal (a `$fixed_bytes()`) would add nothing.

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

- **Build with `-cc gcc`, not the default tcc** — callgrind names a tcc build's
  functions but gives them no file:line (`???`); gcc emits DWARF, so
  `pg_async__*` (and the unprefixed `main` module functions) come with lines.
- **`-g` lines are `.v` lines** on V ≥ 56509a4
  ([vlang/v#29220](https://github.com/vlang/v/pull/29220)); older V3 builds
  print `src.c:N` from a deleted file — keep the C with a `-cc` wrapper
  ([#168](https://github.com/enghitalo/vanilla/pull/168)).
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

**In a test, assert on heap bytes, not RSS.** RSS moves in pages, and where
transparent huge pages are `always` (GitHub's ubuntu-24.04 runners) in 2 MiB steps
with no allocation at all: khugepaged collapsing a range, or a huge page faulted in.
glibc's `mallinfo2()` (`uordblks + hblkhd`: bytes in use over every arena) is exact
under `-gc none`, where every V allocation is a `malloc`; see
[tests/tls_static_test.v](../tests/tls_static_test.v). Under `-race`
ThreadSanitizer's allocator replaces malloc, and `mallinfo2` does not see it.

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
