# Local IPC: serving HTTP without the network stack

Services on the same machine do not need the network to talk to each other.
This document is the answer to a simple hypothesis: *TCP sockets exist to expose
a server to the world; when both peers live on one host, most of those layers
are pure overhead — and every server burns a port.* The hypothesis is correct,
the fix is old, boring, and excellent: **Unix domain sockets** — plus a ladder
of sharper tools above them when microseconds matter.

What you get: local service meshes with **zero or one open ports**, fully
**offline** operation (no NICs, no DNS, no firewall traversal), **~2.5–3×
lower request latency** and **~1.7–2.4× higher streaming throughput** than
loopback TCP (measured on one machine across two kernels, see §2), **no
TIME_WAIT / ephemeral-port exhaustion** in connection-churning test suites, and
kernel-verified **peer identity (pid/uid/gid) instead of IP-based auth**. The
HTTP layer does not change at all: RFC 9112 explicitly presumes only "a
reliable transport with in-order delivery" — which `AF_UNIX SOCK_STREAM` is.

vanilla ships this: `ServerConfig.unix_socket_path` (listen),
`transport.dial_unix` (dial), `socket.peer_cred` (identity). §5 records how
they were built; the rest of the document is the evidence and the map beyond
them.

## 1. What loopback TCP actually costs

`127.0.0.1` is not a shortcut through the kernel. The `lo` interface is a real
netdevice, and every loopback connection still runs:

- the **full TCP state machine** — 3-way handshake, FIN/ACK teardown, and
  **TIME_WAIT** (hardcoded 60 s in `include/net/tcp.h`, not a sysctl);
- **ACK generation, delayed-ACK logic, retransmit/keepalive timers** (armed and
  book-kept even though they never fire usefully on `lo`);
- **congestion control and Nagle** — cwnd, slow start apply; you still need
  `TCP_NODELAY` (vanilla sets it on every accepted connection);
- **netfilter hooks** (`LOCAL_OUT`/`LOCAL_IN`, conntrack if loaded) — on a box
  with a fat iptables/nftables ruleset, loopback pays per-packet rule
  evaluation; this is why firewalls need an explicit `-i lo -j ACCEPT`;
- a **routing/FIB lookup** into the `local` table;
- **segmentation** — mitigated (`lo` has a 64 KiB MTU and software GSO) but
  present.

The one classic cost loopback *does* skip is checksums (`loopback_setup()` sets
`NETIF_F_HW_CSUM | NETIF_F_RXCSUM`, so TX checksums are never computed and RX is
trusted) — so the difference measured below is *not* checksum math; it is all of
the above.

An `AF_UNIX SOCK_STREAM` write, by contrast, is: allocate an skb, append it to
the peer socket's receive queue under one lock, wake the peer. No headers, no
FSM, no timers, no congestion control, no netfilter, no routing. Nagle cannot
exist (there is no TCP), so the `TCP_NODELAY` footgun disappears by
construction. Flow control is just `SO_SNDBUF` accounting.

Two more structural wins for local meshes:

- **Namespace.** TCP ports are a single flat `u16` space per address — two
  services cannot share 8080, discovery means a registry or a config file of
  port numbers. UDS addresses are filesystem paths: per-user directories,
  ordinary permissions, `ls /run/myapp/` *is* service discovery.
- **Connection churn.** Each loopback TCP client connection consumes an
  ephemeral 4-tuple (`ip_local_port_range` default ≈ 28k ports) and parks it in
  TIME_WAIT for 60 s on active close. Where TIME_WAIT reuse is unavailable
  (non-loopback peers, `tcp_tw_reuse=0`, timestamps off, pre-4.19 kernels) a
  churning e2e suite saturates at roughly 470 connects/s per (dst ip, port)
  before `EADDRNOTAVAIL`; Linux ≥ 4.19 defaults rescue loopback specifically
  (`tcp_tw_reuse=2`, ~1 s reuse — measured here: 14.8k connects/s sustained
  with zero errors, TIME_WAIT pool plateauing at ~15k entries). UDS sidesteps
  the mechanism entirely: no port space, no TIME_WAIT (both are TCP-FSM
  concepts); `close()` releases everything immediately.

## 2. Measured on this machine

`bench/ipcbench.c` (cc -O2, no deps) forks an echo server and a client pinned
to different cores (2 and 4), runs 2 000 warmup + 20 000 timed round trips per
payload size with full short-read/short-write handling, a ~2 s 64 KiB-chunk
streaming phase, and 2 000 connect/close cycles. AMD Ryzen 7 5800H, best of 3
runs per metric (p50 spread across runs < 5%), measured twice on the same
hardware: Linux 6.8.0-124-generic (2026-07) and Linux 7.1.13 (2026-10). TCP
uses `TCP_NODELAY` on both ends.

**Ping-pong RTT (µs), Linux 6.8:**

| Payload | TCP p50 | TCP p99 | UDS p50 | UDS p99 | UDS vs TCP p50 |
| ------- | ------- | ------- | ------- | ------- | -------------- |
| 64 B    | 31.01   | 39.60   | 10.48   | 19.14   | **2.96× faster** |
| 512 B   | 31.01   | 41.35   | 10.41   | 18.51   | **2.98×**      |
| 4 KiB   | 32.20   | 41.48   | 12.22   | 21.79   | **2.63×**      |
| 16 KiB  | 34.85   | 46.37   | 13.69   | 24.79   | **2.55×**      |

**Ping-pong RTT (µs), Linux 7.1:**

| Payload | TCP p50 | TCP p99 | UDS p50 | UDS p99 | UDS vs TCP p50 |
| ------- | ------- | ------- | ------- | ------- | -------------- |
| 64 B    | 25.21   | 35.34   | 9.85    | 16.62   | **2.56× faster** |
| 512 B   | 25.28   | 35.83   | 9.92    | 16.76   | **2.55×**      |
| 4 KiB   | 27.66   | 39.04   | 11.59   | 20.11   | **2.39×**      |
| 16 KiB  | 36.67   | 53.43   | 19.55   | 28.56   | **1.88×**      |

**Streaming throughput** (64 KiB writes): Linux 6.8 — TCP **2.76 GiB/s**, UDS
**6.56 GiB/s** (2.38×); Linux 7.1 — TCP **2.81 GiB/s**, UDS **4.69 GiB/s**
(1.67×). **Connection setup** (socket+connect+close p50): Linux 6.8 — TCP
**41.8 µs**, UDS **7.7 µs** (5.4×); Linux 7.1 — TCP **34.3 µs**, UDS
**7.1 µs** (4.8×). On both kernels the TCP churn phase parked ~2 000 TIME_WAIT
entries per run (`ss -tan state time-wait`); UDS left zero residue.

The kernel moved both sides — loopback TCP got cheaper, large UDS writes got
dearer — so quote the *shape*, not one ratio, and re-run `ipcbench` on the
target box before leaning on a number. The TCP penalty is a near-constant
~15–21 µs of protocol work per round trip, so the *relative* win shrinks as
payloads grow. Published results agree on the
shape — UDS wins by 1.5–5× on small messages (Marhubi 2015: 1.44 vs 7.29 µs
RTT, ~5×; Redis docs: "around 50% more throughput" without pipelining, ~1.5×)
— **but the gap can invert for very large single writes**: uvloop #345
measured UDS ~2.5× *slower* at 1 MB messages, because loopback TCP rides
autotuned `tcp_wmem` and 64 KiB GSO segments while one UDS write is capped by
`net.core.wmem_default`. Writes that fit the default send buffer are
unaffected — the 64 KiB-chunk streaming above is exactly that case and still
won 1.67–2.38×. If a route must issue megabyte-sized writes over UDS, raise
`SO_SNDBUF` or chunk the writes (for UDS the send buffer is the one that
matters; `SO_RCVBUF` is ignored). For HTTP/RPC-sized traffic, UDS wins across
the board.

## 3. The ladder

From "works today" to "nanoseconds, but you give up sockets":

| Tier | Mechanism | Latency class | HTTP works? | When |
| ---- | --------- | ------------- | ----------- | ---- |
| 0 | TCP loopback | ~25–31 µs RTT¹ | yes | Cross-machine tomorrow; tooling that only dials `host:port` |
| 1 | **Unix domain socket** | **~10 µs RTT¹** | **yes, unchanged** | **The default for same-host. This doc's recommendation; shipped as `unix_socket_path` (§5).** |
| 2 | UDS + `SCM_RIGHTS` fd-passing | one-time cost per connection | yes | One front door, N services, zero proxy hop (§7) |
| 3 | `socketpair()` | as UDS | yes | Parent↔child worker channels; nothing else can ever connect |
| 4 | Shared-memory rings (iceoryx2, Aeron IPC) | ~0.1–1 µs | **no** | Internal bus where µs matter; you lose fd semantics, epoll/io_uring, curl, crash isolation |
| 5 | Same process: co-hosted `Server` instances / plain function calls | ns | n/a | The honest endgame of "why are these two processes?" — vanilla already co-hosts servers in one process (`ServerConfig.workers` splits cores) |

¹ 64 B p50, §2 (Linux 7.1 / 6.8).

Special mentions: **vsock** (`AF_VSOCK`) is the same-idea transport for
VM↔host (Firecracker/QEMU agents); **`SOCK_SEQPACKET`** on AF_UNIX gives
connection-oriented, reliable, ordered *datagrams* — the nicest RPC framing
primitive nobody uses (Linux/FreeBSD; no Windows, and reportedly absent on
macOS); even UDS **`SOCK_DGRAM`** is reliable and ordered by contract
(unix(7)).

Tier 1 is the sweet spot because it is the *only* rung that is simultaneously
faster, drop-in for HTTP, portable (Linux, macOS/BSD, Windows ≥ 1803 for
SOCK_STREAM), observable (`ss -x`, `lsof -U`), and secured by things the kernel
already enforces (file permissions, `SO_PEERCRED`).

## 4. Everyone already does this

This is not an exotic path — it is the default control plane of the
infrastructure you use daily:

- **Docker**: the entire REST API on `/var/run/docker.sock` (0660,
  root:docker); `curl --unix-socket /var/run/docker.sock http://localhost/v1.55/containers/json`.
- **Kubernetes**: kubelet↔runtime is gRPC over UDS (`unix:///run/containerd/containerd.sock`);
  CSI and device plugins are UDS-discovered.
- **systemd**: socket activation (`ListenStream=/run/app.sock`), journald,
  D-Bus — all UDS, all authenticated via `SO_PEERCRED`.
- **The classic web deployment**: nginx `server unix:/run/php.sock` →
  PHP-FPM/Gunicorn/uWSGI. HAProxy (`bind unix@`), Envoy (`pipe`), Caddy
  (`bind unix//run/caddy`) all speak it on both sides.
- **Databases**: PostgreSQL and MySQL default to UDS for local clients
  (`psql` with no `-h` never touches TCP); Redis supports it opt-in and
  documents the throughput win.

HTTP semantics over UDS are settled by practice: the transport is out-of-band
(curl's `--unix-socket`), the URL keeps a fake authority (`http://localhost/...`)
and the mandatory `Host` header derives from it as usual. No RFC change, no
parser change, nothing in vanilla's HTTP/1.1 layer is affected.

## 5. vanilla's implementation: `unix_socket_path`

Shipped in 2026-07 under issue #122: the listener (`2fdbf4d`),
`transport.dial_unix` (`f62d200`), `socket.peer_cred` (`3e7e405`) and
`examples/mesh` (`1d29592`). This section began as the design plan. It now
records what landed, where, and which parts of the plan the implementation
corrected. One config field; the request-serving hot path is untouched.

```v
mut s := server.new_server(server.ServerConfig{
	handler:          my_handler
	unix_socket_path: '/run/myapp/api.sock' // '' (default) = TCP on `port`
})!
```

The audit of every backend found the fd is opaque everywhere past `accept()` —
parser, handlers, limits, timeouts, sendfile, suspend/resume watches and
pipelining are family-agnostic. What changed:

1. **Listener — [`socket/socket_unix_nix.c.v`](../socket/socket_unix_nix.c.v).**
   `create_unix_server_socket(path)` = zeroed `sockaddr_un` →
   `socket(AF_UNIX, SOCK_STREAM)` → non-blocking → `unlink(path)` (stale socket
   from a crash; `bind()` fails `EADDRINUSE` on an existing path even with no
   listener) → `bind` → `listen(listen_backlog)`. No
   `SO_REUSEPORT`/`SO_REUSEADDR` — neither means anything on AF_UNIX. A path
   longer than `socket.max_unix_path` (103: the BSD/macOS 104-byte `sun_path`
   minus the NUL, so a config that works on Linux works on macOS too) and every
   bind/listen failure come back as `!` errors from `new_server`. Filesystem
   paths only — no abstract namespace (§6). Siblings: `connect_to_unix_server`
   (blocking, for tests) and `unlink_socket_path`.
2. **`new_server` ([`server/server.c.v`](../server/server.c.v))** rejects
   `unix_socket_path` on Windows/IOCP (afunix.h support is a separate, tested
   effort, §8) and together with TLS (see below); branches listener creation;
   skips the ephemeral-port resolution (a UDS has no port); and skips the
   io_uring per-worker `SO_REUSEPORT` listeners — `listener_fds` stays
   `[socket_fd]`.
3. **io_uring backend — the one structural change.** The per-worker-listener
   model rides `SO_REUSEPORT`, which AF_UNIX does not support (modern kernels
   return `EOPNOTSUPP`; a second bind to the same path is `EADDRINUSE`).
   Instead every worker ring arms its (multishot) accept on the **same
   listener fd**: `listener := srv.listener_fds[i % srv.listener_fds.len]` in
   `run_io_uring_backend`
   ([`server/server_io_uring_linux.c.v`](../server/server_io_uring_linux.c.v)).
   `SINGLE_ISSUER`/`DEFER_TASKRUN` bind the *ring* to its thread, not the fds
   it operates on, and the accept SQE passes `addr=nil`. The model was
   verified before landing (4 rings, Linux 6.8): 2 000 connections produced
   exactly 2 000 CQEs across the rings with zero spurious `-EAGAIN`
   completions. Two kernel behaviours to know:
   - **`shutdown(2)` on an AF_UNIX listener completes no armed accept.** On
     TCP, `shutdown(SHUT_RDWR)` on the listener completes every armed accept
     with an error CQE (res `-EINVAL`, within milliseconds). On an AF_UNIX
     listener the call returns 0 but **no CQE ever arrives** —
     `bench/uds_uring_shutdown_repro.c` waits 5 s and gets none (Linux 6.8 and
     7.1; plain and `SINGLE_ISSUER|DEFER_TASKRUN` rings alike). The gap is
     specific to io_uring's armed accept — `epoll_wait` on the same shut-down
     listener wakes fine (item 4) — and to listeners: `shutdown()` on
     *connected* UDS sockets (the timeout-sweep path) behaves normally.
     **For vanilla it is harmless**, and the plan got this wrong (it predicted
     that `Server.shutdown` would hang every io_uring worker). After
     `shutdown()` every new `connect()` fails `ECONNREFUSED`, so the
     still-armed accept is inert until the process exits; and
     `Server.shutdown` drains on the per-worker in-flight *request* counters —
     it never waits for an accept CQE or joins a worker. `Server.shutdown`
     nevertheless shipped the plan's low-tech remedy (one dummy `connect()`
     per worker after setting `draining`), and it is redundant: with it
     disabled, the io_uring idle shutdown in `tests/uds_test.v` still returns
     in 0 ms (measured 2026-10, Linux 7.1). It also could not do what it
     promises: a multishot accept stays armed after delivering the dummy
     connection (`F_MORE` set), and wake-order distribution (next bullet) can
     hand every poke to the same ring. A design that *must* see the terminal
     CQE — joining worker threads, tearing rings down with
     `io_uring_queue_exit` — needs each ring to cancel its own accept with
     `io_uring_prep_cancel_fd(listener, IORING_ASYNC_CANCEL_FD |
     IORING_ASYNC_CANCEL_ALL)`, poked via `IORING_OP_MSG_RING` (under
     `SINGLE_ISSUER` the cancel SQE must come from the ring's own thread).
   - **Distribution is wake-order, not hashed** — and under sequential or
     low-concurrency arrival it is total: all 2 000 test connections landed on
     ring 0 (2000/0/0/0). Balance only emerges under concurrent connection
     pressure, so single-worker throughput is the floor for a lightly-loaded
     UDS front. Fine for a local mesh; the escalation path once one worker
     saturates is a single acceptor ring + `IORING_OP_MSG_RING` fd handoff.
4. **epoll / kqueue backends: zero accept-path changes.** The central acceptor
   never inspects the address family. `set_tcp_nodelay` on a UDS fd returns
   `EOPNOTSUPP`, which the code ignores — one wasted syscall per accept, on
   every backend. Shutdown works unchanged: `shutdown(SHUT_RDWR)` on a UDS
   listener wakes `epoll_wait` with `EPOLLIN|EPOLLHUP`, and `accept()` then
   fails `EAGAIN` (TCP fails `EINVAL` instead) — which the acceptor already
   reads as "backlog drained". `Server.shutdown` closes the listener right
   after `shutdown(2)`, dropping it from the epoll set, so the acceptor goes
   quiet: 0 ms of CPU in the 2 s after shutdown, TCP and UDS alike (measured
   2026-10, Linux 7.1, epoll and io_uring). The one family
   branch epoll did grow came later and off the accept path: the idle reaper's
   leftover-fd check (`PlainState.leftover_fd`, #151) recognises a socket
   accepted on the listener by its local address, which for UDS means
   "AF_UNIX and bound to a path" instead of "same TCP port".
5. **Family guards in [`socket/socket_tcp.c.v`](../socket/socket_tcp.c.v)**:
   `peer_ipv4` returns `none` (and `peer_addr` `''`) unless the family is
   `AF_INET` or an IPv4-mapped `AF_INET6` — without the guard a UDS peer would
   decode as `0.0.0.0` and silently collapse every client into one bucket in
   `examples/rate_limit` and `examples/ip_block` (`none` = "unknown" is those
   examples' documented handling of a failed `getpeername`). `local_port`
   returns `-1` the same way. The UDS-native replacement for IP identity is
   `socket.peer_cred` (§6).
6. **Lifecycle**: `Server.shutdown` unlinks the socket file after the drain;
   the unlink-before-bind (item 1) covers non-graceful exits. `bind()` creates
   the file as `0777 & ~umask` and there is no `unix_socket_mode` option:
   set a restrictive umask before `new_server`, or — portable, and what §6
   recommends anyway — gate access with the socket's directory.
7. **Client side and tests**: `transport.dial_unix(path)`
   ([`transport/transport_nix.c.v`](../transport/transport_nix.c.v)) is the
   non-blocking dial for handlers; it reports a full backlog's `EAGAIN`
   distinctly from an absent server (§8).
   [`tests/uds_test.v`](../tests/uds_test.v) serves HTTP/1.1 over UDS on epoll
   and io_uring, asserts prompt shutdown, unlink and rebind, checks
   `peer_cred`, and runs the `vtest` scripts over UDS (a UDS e2e is a TCP e2e
   plus one config line). The io_uring backend prints
   `listening on unix:<path>`; epoll and kqueue still print the TCP banner.

Research findings that still hold: **static_assets** never sees an address,
and Linux `sendfile(2)` writes to an AF_UNIX socket; `accept4`,
`set_nosigpipe`, `shutdown_write`, the recv/send paths and `max_connections`
accounting are all family-agnostic. **TLS over UDS** showed no family
dependence either (the mbedTLS BIO is plain send/recv on the fd; the kTLS ULP
attach fails with `EOPNOTSUPP` at its designed fallback point and the session
stays on userspace crypto), but `new_server` rejects the combination until an
end-to-end test covers it — lifting the gate is a testing task, not a design
one.

Footprint of the listener commit (`2fdbf4d`): one new 93-line file, +64 lines
in `server/server.c.v`, +11 in the io_uring facade, +10 lines of guards in
`socket_tcp.c.v`. **No change on any request-serving path.**

### Co-hosting: public TCP + internal UDS in one process

The two listeners compose. The pattern for a service that is both an edge and a
mesh member is two co-hosted `Server` instances, splitting cores via
`ServerConfig.workers`:

```v
mut edge := server.new_server(server.ServerConfig{
	port:    8080
	workers: 12
	handler: h
})!
mut mesh := server.new_server(server.ServerConfig{
	unix_socket_path: '/run/app/int.sock'
	workers:          4
	handler:          h
})!
```

[`examples/mesh`](../examples/mesh/) runs this shape end to end: an edge on TCP
calling a backend on UDS in the same process, through `transport.dial_unix`,
the `http1_1/client` codec and a pooled per-worker connection. A whole local
mesh then needs exactly **one** port (the edge) — or zero, if the edge itself
sits behind a reverse proxy or systemd socket activation.

One honest gap the research surfaced: **no established orchestrator wires an
entire local mesh over UDS as its primary model** — this is genuinely
underexplored territory. The working composition today is hand-rolled: systemd
`.socket` units (or a process-manager script) plus one socket directory per
environment — `$XDG_RUNTIME_DIR/<suite>/*.sock` for a test run, so `ls` shows
the mesh and removing the directory tears it all down. That gap is exactly
where a vanilla-based mesh harness would sit.

## 6. Conventions, security, tooling

**Paths.** System services: `/run/<app>/<app>.sock` in a dedicated directory
(`RuntimeDirectory=` under systemd creates and cleans it). Per-user/dev:
`$XDG_RUNTIME_DIR/<app>/` — tmpfs, mode 0700, lifecycle-managed per login; the
convention podman, D-Bus, PipeWire and Wayland all follow. Watch the
`sun_path` limit with deep tempdirs (the classic MySQL bug): vanilla rejects
paths over `socket.max_unix_path` (103 bytes, the portable floor); a shorter
directory, or `chdir()` + a relative path, is the escape hatch.

**Access control.** The portable control is **directory permissions** (0750
dir + 0660 socket; Linux checks write permission on the socket inode, but
unix(7) warns some systems historically ignored socket-file modes — gate with
the directory). For *identity*, `getsockopt(SO_PEERCRED)` returns the
kernel-verified `{pid, uid, gid}` of the peer at connect time — unforgeable,
zero round trips, and strictly stronger than "it came from 127.0.0.1" (which
every uid on the box can say). This is how D-Bus, journald and Docker
authenticate. Kernel ≥ 6.5 adds `SO_PEERPIDFD` for a race-free process handle.
vanilla exposes it as `socket.peer_cred(fd) ?PeerCred` — `SO_PEERCRED` on
Linux, `getpeereid` + `LOCAL_PEERPID` on macOS — the sibling of `peer_ipv4`:
one `getsockopt` when a handler asks, `none` on a TCP socket
([`socket/peer_cred_linux.c.v`](../socket/peer_cred_linux.c.v)).

**Abstract namespace** (Linux-only, `@name` convention → `sun_path[0] = '\0'`):
no filesystem entry, auto-cleanup when the last fd closes — ideal for test
suites (no stale files, no unlink dance). The catch: **file permissions do not
apply at all**; any process in the network namespace can connect, and names are
first-come-first-served (a hostile local process can squat yours). Use it for
tests; use pathname sockets in owned directories for real deployments, or
verify every peer via `SO_PEERCRED`. vanilla's listener takes filesystem paths
only.

**Client tooling.**

| Tool | UDS support |
| ---- | ----------- |
| curl | `--unix-socket /path` (7.40+), `--abstract-unix-socket` (7.53+) |
| Load testing | **oha** `--unix-socket`, vegeta `-unix-socket`, autocannon `-S`, h2load `--base-uri=unix:...`; **wrk: no** (front it with nginx `unix:` if wrk-Lua is non-negotiable, accepting the proxy tax) |
| Node.js | `http.request({ socketPath: '...' })` |
| Go | `http.Transport{ DialContext: ... dial "unix" }` |
| Python | `requests-unixsocket` |
| V | vanilla `transport.dial_unix` (non-blocking, for handlers) and `vtest` (scripted e2e against `unix_socket_path`); stdlib `net.unix` (`connect_stream` / `listen_stream`) |
| Debugging | `ss -x` / `ss -xlp`, `lsof -U`; no tcpdump — `socat` tee or strace/eBPF for wire dumps |

## 7. Beyond tier 1: the zero-hop router

The pattern that makes "one port, N services" cheap: a front-door router
accepts every connection, peeks just enough (first request line, path prefix,
SNI) to pick the owning backend, then ships the **connected client fd itself**
to that backend over a control UDS via `sendmsg(SCM_RIGHTS)` — replaying the
already-consumed bytes as the data part of the same message. From that moment
the client talks to the backend **directly**: no proxy hop, no double copy, no
per-request forwarding tax, the router touches each connection exactly once.
Cloudflare documents the pattern; HAProxy and Envoy use the same mechanism to
hand live connections across restarts. Limits: ≤ 253 fds per message, in-flight
fds count against `RLIMIT_NOFILE`, Linux/BSD only (Windows AF_UNIX has no
ancillary data), and TLS handoff means handing session state too.

The same primitive powers **systemd-style socket activation**: the supervisor
owns the listener and passes it pre-bound (`LISTEN_FDS`, fd 3+); connections
queue in the kernel backlog across service restarts — zero-downtime deploys
with zero dropped connections and no proxy. vanilla's `after_server_start` hook
is where a readiness notification would go; accepting an inherited listener fd
would be a natural `ServerConfig.listener_fd` follow-up.

## 8. Pitfalls checklist

- **Stale socket after crash** → unlink-before-bind (what §5 does, and what
  V's own `net.unix.listen_stream` does). The unlink can steal a *live*
  socket's name if you run two instances by mistake; if that matters,
  connect-probe first (`ECONNREFUSED` ⇒ stale) or flock a sidecar lockfile
  (PostgreSQL's `.lock` pattern).
- **Full backlog behaves differently**: no SYN queue — a non-blocking
  `connect()` to a full UDS backlog fails `EAGAIN` immediately, not
  `EINPROGRESS` (confirmed locally: backlog 1, third connect → `EAGAIN`; TCP
  would queue and add latency instead). Load tests show connect errors where
  TCP showed slowdown; `transport.dial_unix` reports this case as its own
  "backlog full — retry" error. vanilla requests a 65536 backlog but the
  kernel clamps every `listen()` to `net.core.somaxconn` (4096 on modern
  defaults) — still unlikely to fill on a local front, but raise the sysctl if
  you expect >4k un-accepted connections, and size client retries
  accordingly.
- **Megabyte-sized single writes**: raise `SO_SNDBUF` or chunk the writes
  (UDS ignores `SO_RCVBUF`; defaults come from `net.core.wmem_default`, not
  TCP's autotuned buffers — see §2; buffer-sized chunked streaming is fine).
- **`peer_ipv4`-keyed logic** (rate limiting, IP blocks) must treat `none`
  as "unknown transport" and use `socket.peer_cred` on UDS instead (§5 item
  5, §6).
- **Portability**: macOS/BSD — first-class (kqueue identical; `sun_path` 104;
  no abstract namespace; creds via `getpeereid`/`LOCAL_PEERCRED`, which
  `socket.peer_cred` wraps). Windows ≥ 10 1803 —
  `SOCK_STREAM` only, file-ACL access control, **no fd-passing/credentials**,
  abstract namespace effectively unavailable; treat Windows UDS support as a
  separate, tested effort before promising it (`new_server` rejects
  `unix_socket_path` on IOCP today).
- **Containers**: bind-mounting a socket across a VM boundary (Docker Desktop
  on macOS/Windows) is unreliable; on Linux it works and is the standard
  sidecar wiring — but remember mounting a privileged socket (docker.sock)
  into a container hands over its full authority.

## 9. Sources

Local measurements: `bench/ipcbench.c` and `bench/uds_uring_shutdown_repro.c`
(this repo, AMD Ryzen 7 5800H; Linux 6.8.0-124 and 7.1.13). Key external
references:

- unix(7), socket(7) — abstract namespace, `SO_PEERCRED`, datagram reliability,
  buffer sysctls: <https://man7.org/linux/man-pages/man7/unix.7.html>
- Linux `drivers/net/loopback.c` (checksum/GSO flags), `include/net/tcp.h`
  (`TCP_TIMEWAIT_LEN`)
- RFC 9112 §9 (Connection Management), transport-independence paragraph:
  <https://www.rfc-editor.org/rfc/rfc9112.html>
- Kamal Marhubi, IPC latency data (2015): <https://kamalmarhubi.com/blog/2015/06/10/some-early-linux-ipc-latency-data/>
- Redis benchmarks (UDS vs loopback): <https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/>
- uvloop #345 (large-message inversion): <https://github.com/MagicStack/uvloop/issues/345>
- Cloudflare, "Know your SCM_RIGHTS": <https://blog.cloudflare.com/know-your-scm_rights/>
- systemd File Descriptor Store & socket activation: <https://systemd.io/FILE_DESCRIPTOR_STORE/>
- io_uring multishot accept / msg_ring:
  <https://man7.org/linux/man-pages/man3/io_uring_prep_multishot_accept.3.html>,
  <https://man7.org/linux/man-pages/man3/io_uring_prep_msg_ring_fd.3.html>
- `SO_REUSEPORT` unsupported on AF_UNIX (now `EOPNOTSUPP`):
  <https://github.com/amazonlinux/amazon-linux-2023/issues/901>
- Docker Engine API over UDS: <https://docs.docker.com/reference/api/engine/sdk/examples/>
- nginx `unix:` upstreams: <https://nginx.org/en/docs/http/ngx_http_upstream_module.html>
- gRPC naming (`unix:`, `unix-abstract:`): <https://github.com/grpc/grpc/blob/master/doc/naming.md>
- V stdlib `net.unix`: <https://modules.vlang.io/net.unix.html>
- iceoryx2 (~100 ns shared-memory transfers): <https://github.com/eclipse-iceoryx/iceoryx2/discussions/435>
- Man Group, Aeron IPC 0.25 µs RTT: <https://www.man.com/technology/special-fx-execution-system-on-aeron>
