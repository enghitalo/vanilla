# Architecture — module tree and dependency rule

Plan of record: GitHub issue #122 (module tree restructure for multi-protocol +
multi-platform growth). This document records the shape the tree must keep.

## The tree

Flat top-level modules — no `protocol/` or `platform/` umbrella layers (each
directory segment is an import segment in V; an umbrella segment inflates every
import and says nothing). Protocols are **siblings** over one engine:

| module | role |
|---|---|
| `core/` | protocol-neutral contract: `Handler`, `Step`, `Counter`, `Limits`, hand-off slots. `Handler` is bytes-in/bytes-out — nothing HTTP about it. |
| `socket/` | listen side: TCP listeners, Windows sockets; UDS listeners, peer credentials and fd passing land here (docs/LOCAL_IPC.md §5–§7). |
| `tls/` | mbedTLS split (`-d vanilla_tls` / stub) — server today, client transports later. |
| `epoll/` `io_uring/` `kqueue/` `iocp/` | thin per-mechanism syscall wrappers, one dir-module each (`poll/` joins them as the portability floor). |
| `server/` | **the engine** (was `http_server`) — one engine, N protocols via conn modes. OS facades (`server_linux.c.v`, …) select an `IOBackend`; `server/backend_*` are the reactors. |
| `http1/` | HTTP/1.1 codecs (was `http1_1`): `request_parser/`, `response/`; a `client/` codec lands here later. |
| `http2/` | frame/hpack/types grow in place: stream mux, flow control, settings. |
| `websocket/` `grpc/` | reserved siblings (RFC 6455 framing; length-prefixed messages over http2). Future protocols land as siblings here. |
| `static_assets/` `testkit/` `vtest/` `pg_async/` | reusable handler-side and test-side modules. |
| `transport/` | reserved: client-side dialing (`dial_tcp`, `dial_unix`) — bytes + non-blocking fds ONLY; protocol clients compose it, they don't live in it. |

## Dependency rule (grep-enforceable, one direction)

```
core  <-  { socket, transport, tls, epoll, io_uring, kqueue, iocp, poll,
            http1, http2, websocket, grpc, static_assets }  <-  server
```

- Protocol modules import protocol modules **downward only**
  (websocket→http1, grpc→http2).
- Protocol modules may import `transport/`, `socket/`, `tls/` (downward) —
  that is what lets a protocol ship its **client** codec without a second
  framework growing under `transport/`.
- Wrappers, `socket/`, `transport/`, `tls/` **never** import a protocol.
- `server/backend_*` is the **single sanctioned meeting point** of platform +
  transport + protocol — by design, because that is the measured fast path
  (reactors keep their *direct* imports of the http1 codec; no interface
  dispatch is introduced anywhere).

CI enforces this with `scripts/check_dependency_direction.sh` (grep over
import lines — run it locally from the repo root).

## Platform rule of thumb (the tree's existing idiom, made explicit)

- Different **event-delivery model** → new `server/backend_*` dir-module
  (poll vs epoll vs ionotify are different loops, not different lines).
- Same contract, **per-OS implementation** → OS-suffix file inside the
  existing module (`socket_windows.c.v` today; `wake_qnx.c.v` tomorrow).
- **Single-line divergence** → `$if` block.

Arch targets (ARM, RISC-V) are cross-compilation concerns (`-arch` + cross
`-cc`) and have zero tree impact.

## Imports

Use fully-qualified imports from the repo root (`import server.backend_epoll`,
`import http1.response`) — never sibling-relative paths — so any future
directory move stays a pure import-line change (CONTRIBUTING.md).

External consumers use the `vanilla.` prefix (`import vanilla.server`,
`import vanilla.core`, `import vanilla.http1.response`); CI compiles a
synthetic external consumer to keep that convention honest. Migrating a
pre-restructure consumer: `scripts/migrate_imports.sh`.
