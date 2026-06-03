# V performance toolbox (for vanilla's hot paths)

Notes verified against the installed V source (`vlib/builtin/`) and emitted C
(`v -prod -o out.c`). The guiding rule: **settle codegen/perf questions by
reading the generated C, not by guessing.**

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
