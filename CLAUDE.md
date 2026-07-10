# CLAUDE.md

Guidance for any AI assistant working in this repository. **Read this first.**

## Required reading before writing or changing code

Read these two documents and follow them — they are not optional:

1. **[docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md)** — how to write handlers,
   build responses, allocate, handle concurrency, security, testing, and
   benchmarking in this project.
2. **[docs/V_PERF_TOOLBOX.md](docs/V_PERF_TOOLBOX.md)** — V performance
   attributes, array flags, the C escape hatch, and data-structure choices.

Also see [CONTRIBUTING.md](CONTRIBUTING.md) for raw-request testing and
benchmarking commands.

## What this project is

**vanilla** — a minimalist, high-performance HTTP server written in V.
Multi-threaded, non-blocking I/O, lock-free, copy-free, `SO_REUSEPORT`, multiple
backends (epoll / io_uring / kqueue / iocp). Targets
[RFC 9112](https://datatracker.ietf.org/doc/rfc9112/) and the IANA field
registry.

## The three rules (from CONTRIBUTING.md)

1. **Don't slow down performance.**
2. **Always keep abstraction to a minimum.**
3. **Don't complicate it.**

## Non-negotiables (the short version — details in BEST_PRACTICES.md)

- Handlers are **pure functions** of the request (`core.Handler`): append the
  raw response into the server-owned buffer and return a `core.Step`
  (`.done`/`.suspend`/`.close`). No socket I/O, no hidden globals, no shared
  mutable state on the hot path (per-worker state goes through
  `make_state`/`ctx.state`).
- Stay **zero-copy** — whenever a view suffices, use a view: `Slice` offsets
  into the request buffer, `unsafe { (&buf[start]).vbytes(len) }` for `[]u8`
  windows, `unsafe { tos(ptr, len) }` for read-only string params. Defer
  `.to_string()` / `.clone()` until the bytes must outlive the buffer; avoid
  `buf[a..b]` (it marks the source buffer every call).
- **Never concatenate (`+`) or interpolate (`${}`) in request-serving code** —
  not even on deliberately slow routes. Each one allocates (ints also pay
  `.str()`). Use `const ... .bytes()` for static responses, append parts
  straight into `out` (`push_many` + `strconv.write_dec`), and a single
  `strings.Builder` (`write_string` / `write_decimal` / `write_u8`) when a
  dynamic string is unavoidable. `${}` is fine in `eprintln`/`error()`
  diagnostics off the request path.
- Allocate with intent: `[]u8{cap: n}` is uninitialized/noscan; large `cap`
  costs GC pressure. Size to the realistic case.
- **Benchmark before/after** any perf change with `-prod`; verify thread safety
  with `valgrind --tool=helgrind`.

## Commit messages

Write git commit messages in **English**.
