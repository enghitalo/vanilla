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

- Handlers are **pure functions** `(request) -> []u8`. No socket I/O, no hidden
  globals, no shared mutable state on the hot path.
- Stay **zero-copy**: work with `Slice` views into the request buffer; defer
  `.to_string()` / `.clone()` until the bytes must outlive the buffer.
- **No `${}` string interpolation on the hot path** — it allocates (and calls
  `.str()` for ints). Use `const ... .bytes()` for static responses and
  `strings.Builder` with `write_string` / `write_decimal` / `write_u8` for
  dynamic ones. `${}` is fine in `eprintln`/`error()` off the hot path.
- Allocate with intent: `[]u8{cap: n}` is uninitialized/noscan; large `cap`
  costs GC pressure. Size to the realistic case.
- **Benchmark before/after** any perf change with `-prod`; verify thread safety
  with `valgrind --tool=helgrind`.

## Commit messages

Write git commit messages in **English**.
