# Performance tuning (for operators)

How to run a vanilla server well on a given machine: the build flags, how many
workers it starts and where they run, the kernel limits it hits first, and how
to measure the result. Every knob here was checked against the code; the
[table at the end](#where-each-knob-lives) names the constant or function
behind it.

This page is about deploying a server, not writing one. For fast handler code
(no allocation on the request path, zero-copy views, no `${}`), read
[BEST_PRACTICES.md](BEST_PRACTICES.md) and [V_PERF_TOOLBOX.md](V_PERF_TOOLBOX.md).
For why the engine is built the way it is, read
[PERF_GAP_ANALYSIS.md](PERF_GAP_ANALYSIS.md).

No number on this page is a promise for your hardware. Each quoted number
comes from a cited run. Where there is none, the page tells you how to measure
your own.

## Quick reference

| Knob | Default | Change it when |
|---|---|---|
| `-prod` (and `-gc none`) | debug build, Boehm GC | always `-prod` in production; `-gc none` only if the request path allocates nothing ([§1](#1-build-flags)) |
| `VANILLA_WORKERS` | online CPUs | `taskset`, a cpuset, a container CPU limit, or a load generator on the same box ([§2](#2-workers-and-cpus)) |
| `GC_MARKERS` | online CPUs − 1 marker threads | a Boehm (default GC) build with fewer CPUs than the host has ([§1](#1-build-flags)) |
| backend | `.epoll` | heavy connection churn: try `.io_uring`; TLS: epoll only ([§3](#3-choosing-a-backend)) |
| `ulimit -n` | 1024 (systemd soft limit) | more than about a thousand open connections ([§4](#4-file-descriptors-and-connection-limits)) |
| `ulimit -l` | system default (8 MiB on the test box) | io_uring rings below full size on kernels that charge rings to it, with more than a couple of workers (stderr says `fell back`; [§7](#7-io_uring-host-requirements)) |
| `Limits.max_connections` + timeouts | unlimited | any server facing the internet ([§4](#4-file-descriptors-and-connection-limits)) |
| `net.core.somaxconn` | 4096 (Linux ≥ 5.4) | listen-queue overflows during connection bursts ([§5](#5-the-accept-queue-backlog-and-sysctls)) |
| buffer sizes | 8 KiB read + 16 KiB write per connection | compile-time constants; see [§6](#6-memory-and-buffer-sizing) |

## 1. Build flags

- **`-prod`** for every production build and every timing run. Never compare
  a `-prod` build against a debug build
  ([BEST_PRACTICES §10](BEST_PRACTICES.md#10-benchmark-before-and-after-every-perf-change)).
- **`-gc none`** removes the garbage collector, and nothing is ever freed. It
  is only safe when the request path allocates nothing: then it avoids
  Boehm's stop-the-world collections. Otherwise every allocation is a leak.
  The epoll build ships `-prod -gc none` and the io_uring one `-prod`
  ([server/README.md](../server/README.md#performance)). Before you
  ship `-gc none`, check that RSS stays flat under load: run
  [`bench/load.sh`](../bench/load.sh) with `GC=none`, then with `GC=boehm`,
  and compare the slopes
  ([V_PERF_TOOLBOX](V_PERF_TOOLBOX.md#the-two-build-modes-default-gc-vs--gc-none)).
- **Boehm marker threads.** A default-GC build starts parallel marking
  threads (`GC-marker-N`) sized from the host's online CPUs, not from the
  CPUs the process may use. Measured on a 16-CPU Ryzen 7 5800H: a server
  started with `VANILLA_WORKERS=2 taskset -c 2,3` had 15 marker threads next
  to its 2 workers. `GC_MARKERS=1` removed all of them, and a `-gc none`
  build has none. In a CPU-capped container, set `GC_MARKERS` to the CPUs the
  process really gets.
- **`-cc gcc` or `-cc clang`** pins the C compiler, so the build does not
  depend on what `cc` happens to be. `v -showcc` prints the exact compiler
  command. CI builds its tests with `-cc gcc -no-parallel` to avoid V
  toolchain flakes in debug builds. That is a test setting, not a speed one.
- **`-d vanilla_tls`** compiles the Mbed TLS backend. Without it, TLS is a
  stub ([§8](#8-tls-and-ktls)). **`-d vanilla_poll`** compiles the `poll(2)`
  backend, a portability floor that is never the default.

## 2. Workers and CPUs

Each worker is one thread running its own event loop. The count comes from,
in order:

1. `ServerConfig.workers`, if it is greater than 0 (per server instance);
2. the `VANILLA_WORKERS` environment variable, if it parses to a positive
   integer (otherwise it is ignored);
3. `runtime.nr_cpus()`, which is `sysconf(_SC_NPROCESSORS_ONLN)`: the
   **online CPUs of the host**.

`VANILLA_WORKERS` is read once, when the process starts (it initializes the
module constant `core.max_thread_pool_size`). Put it in the process
environment. `os.setenv` in `main` comes too late.

`nr_cpus()` does not see `taskset`, cpusets (`docker --cpuset-cpus`,
Kubernetes' static CPU manager) or CPU quotas (`docker --cpus`, a Kubernetes
`limits.cpu`). In all of these the server starts one worker per host CPU and
the extra threads fight over the CPUs it really has. Set `VANILLA_WORKERS`
there. An affinity-aware default was tried and reverted: it cut workers on
DB-bound profiles, where more workers means more database requests in flight
(see the comment on `core.worker_count`).

Sizing:

- **CPU-bound handlers** (plaintext, JSON, static files from memory): one
  worker per CPU the process can use.
- **Handlers that wait on a database or an upstream**, with one pool per
  worker (`make_state`): workers are your unit of I/O concurrency. Measure
  before cutting them down to the CPU count.
- **Several servers in one process:** give each its own
  `ServerConfig.workers` so the total stays near the CPU count
  (`examples/per_server_workers`,
  [#89](https://github.com/enghitalo/vanilla/issues/89)).

Threads besides the workers: the **epoll** backend also runs its acceptor on
the main thread, which gets busy under connection churn. Give it a CPU of its
own when you pin. The io_uring main thread only sleeps. A Boehm build adds its
marker threads ([§1](#1-build-flags)).

Splitting a machine between server and load generator:

```sh
VANILLA_WORKERS=8 taskset -c 0-7 ./server
taskset -c 8-15 wrk -t8 -c256 -d30s http://127.0.0.1:3000/
```

**`VANILLA_PIN_CPUS`** (set to any value) pins worker *i* to CPU *i*:
**absolute** CPU numbers, not positions inside the CPU mask the process
inherited. It is off by default, and it only fits a process that owns CPUs
0 to N−1. Measured on the 16-CPU test box: with
`VANILLA_PIN_CPUS=1 VANILLA_WORKERS=2 taskset -c 2,3`, the two workers moved to
CPUs 0 and 1, outside the `taskset` mask. Inside a cgroup cpuset that does not
contain CPU *i*, the pin fails and the worker stays unpinned (failure is
non-fatal). Until [#290](https://github.com/enghitalo/vanilla/issues/290) is
fixed, use `taskset` or a cpuset alone.

## 3. Choosing a backend

Linux has two production backends. Both run the same request code. They
differ in how connections arrive and in what is supported (full table:
[server/README.md](../server/README.md#backends)).

| | `.epoll` (default) | `.io_uring` |
|---|---|---|
| accept | one acceptor thread (`accept4`) hands fds round-robin to the workers | each worker has its own `SO_REUSEPORT` listener and a multishot accept |
| TLS | yes | no (`new_server` refuses a `tls_config`) |
| park deadlines, server push, `on_worker_start` | yes | no |
| 408 on a read timeout | yes (plaintext) | no, closes silently |
| profiling with valgrind/callgrind | yes | no (valgrind does not emulate io_uring) |
| host requirements | none | see [§7](#7-io_uring-host-requirements) |

What the 64-core HttpArena runs showed
([#82](https://github.com/enghitalo/vanilla/issues/82)): with keep-alive
connections epoll was ahead (baseline at 4096 connections: 4.03M req/s
against 3.62M). With connection churn (a reconnect every 10 requests) io_uring
was ahead (2.25M against 1.01M), because epoll's single acceptor becomes the
ceiling. If your clients keep connections open, stay on epoll. If they
reconnect constantly, measure io_uring.

To keep one binary that works on hosts without io_uring, choose at startup:

```v
io_multiplexing: if server.iou_backend_available() { .io_uring } else { .epoll }
```

`iou_backend_available()` opens one small ring per worker and returns false
if any of them fails, or if `VANILLA_NO_IOURING` is set. The server never
reads `VANILLA_NO_IOURING` itself: the kill switch only works through this
call.

## 4. File descriptors and connection limits

Each connection is one fd. On top of that the server holds its listeners
(one, or one per worker on io_uring), one epoll fd or ring per worker, and
whatever your handlers open (database pools, files, upstreams). Measure your
idle baseline with `ls /proc/<pid>/fd | wc -l`, then add the connections you
expect. With a trivial handler the baseline was 8 fds with 2 workers and 10
with 4 (epoll), stdin/stdout/stderr included. When the process reaches
`RLIMIT_NOFILE`, new connections wait in the listen backlog;
[server/README.md](../server/README.md#running-out-of-file-descriptors)
describes exactly how each backend behaves then.

Raise the limit where the process starts:

| Where | How |
|---|---|
| shell | `ulimit -n 65536` (up to the hard limit) |
| systemd | `LimitNOFILE=65536` in the unit (the default soft limit is 1024) |
| Docker | `--ulimit nofile=65536:65536` |
| system-wide ceiling | `fs.nr_open` caps the hard limit; `fs.file-max` caps all processes |

Then cap connections in the server, below that limit minus your baseline:

```v
limits: server.Limits{
	max_connections:  50_000
	read_timeout_ms:  10_000
	write_timeout_ms: 10_000
}
```

A client over the cap is closed at once instead of waiting in the backlog.
Always set `read_timeout_ms` and `write_timeout_ms` with `max_connections`.
Without them, peers that never send, or never read, keep their slots forever
(field-by-field rules: [server/README.md](../server/README.md#request-limits-serverconfiglimits)).
macOS/kqueue enforces none of these four yet
([#154](https://github.com/enghitalo/vanilla/issues/154)).

**io_uring per-worker cap.** Each io_uring worker has a fixed table of 32768
connection slots (`io_uring.max_conn_per_worker`). A connection accepted on a
full worker is closed. With `VANILLA_WORKERS=2` that caps the server at 65536
connections. The kernel spreads new connections over the per-worker listeners
by hash, not by load, so one worker can fill up first. The epoll connection
table has no fixed cap: it grows as fd numbers grow.

## 5. The accept queue: backlog and sysctls

vanilla calls `listen(fd, 65536)` (`socket.listen_backlog`) on every listener,
TCP and Unix socket alike. The kernel silently lowers that to
**`net.core.somaxconn`**: 4096 by default since Linux 5.4, 128 before. macOS
does the same with `kern.ipc.somaxconn`, which defaults to 128
([BENCHMARK_RESULTS_MACOS.md](../BENCHMARK_RESULTS_MACOS.md)). The value is
fixed when the server calls `listen()`, so restart the server after raising
it.

How many queues you get depends on the backend:

- **epoll, poll, kqueue, IOCP:** one listener, one queue.
- **io_uring:** one listener per worker, in one `SO_REUSEPORT` group, each
  with its own queue of `somaxconn` entries. The kernel picks the listener by
  hashing the connection, so a slow worker's queue can overflow while others
  are empty.

With `somaxconn` at 4096, `ss` showed one listener with `Send-Q` 4096 for
epoll, and two listeners on the same port with `Send-Q` 4096 each for a
2-worker io_uring server.

Half-open connections (SYN received, handshake not finished) are bounded per
listener by **`net.ipv4.tcp_max_syn_backlog`**. With
**`net.ipv4.tcp_syncookies=1`** (the default), an overflowing SYN queue answers
with syncookies instead of dropping.

Check before you change anything:

```sh
ss -ltn 'sport = :3000'          # Send-Q = effective backlog, Recv-Q = waiting now
nstat -az TcpExtListenOverflows TcpExtListenDrops   # rising = the queue overflowed
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
```

If the overflow counters climb during bursts, raise the limit (and persist it
in `/etc/sysctl.d/`):

```sh
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
```

If they climb all the time, the server is not accepting fast enough. Raising
the queue then only adds latency: look at the acceptor
([§3](#3-choosing-a-backend)) or the fd limit ([§4](#4-file-descriptors-and-connection-limits)).

**`SO_REUSEPORT` and several processes.** On Linux every TCP listener is
opened with `SO_REUSEPORT`, epoll's single listener too. A second process of
the same user can therefore bind the same port and take a share of new
connections. A forgotten old instance does exactly that, so check
`ss -ltnp 'sport = :3000'` when numbers look odd. The same property allows a
rolling restart: start the new process, then call `shutdown(grace_ms)` on the
old one. Connections still waiting in the old listeners' queues are reset
when they close, unless `net.ipv4.tcp_migrate_req=1` moves them to another
listener in the group. On macOS the listener uses `SO_REUSEADDR` only: one
process per port.

**What the server sets on its sockets:** `TCP_NODELAY` on every accepted
connection, and non-blocking fds (`accept4` with `SOCK_NONBLOCK` on Linux).
It sets no `SO_RCVBUF`/`SO_SNDBUF`, `TCP_DEFER_ACCEPT`, `TCP_FASTOPEN` or
busy-poll option, so kernel defaults and sysctls apply. It binds `0.0.0.0`:
IPv4 only.

## 6. Memory and buffer sizing

Each connection gets a **read buffer of 8 KiB and a write buffer of 16 KiB**
on its first use. Buffers live in a per-worker pool, so a closed connection's
buffers serve the next one. Steady-state memory therefore follows the
**highest number of connections each worker has held at once**, about 24 KiB
each, and only the pages actually touched count toward RSS
([#166](https://github.com/enghitalo/vanilla/issues/166)).

Buffers grow past that size when a request or a response needs it:

- **Requests.** A request larger than 8 KiB grows the read buffer to its
  framed size, up to `Limits.max_request_bytes` (default 8 MiB). A body above
  1 MiB is streamed: the handler answers from the head and the body is read
  and discarded, so it never sits in memory whole. Set `max_header_bytes` and
  `max_body_bytes` to refuse oversized requests early (431, 413).
- **Responses.** A response larger than 16 KiB grows the write buffer. A peer
  that lets more than 8 MiB of responses pile up unsent is disconnected.
  Large files bypass the buffer: `static_assets` hands files of at least
  `sendfile_min_bytes` (256 KiB) to `sendfile(2)` on epoll, and io_uring sends
  preloaded assets straight from memory.
- **Retention differs by backend.** io_uring frees a grown buffer when its
  connection closes. The epoll plain worker keeps it in the pool, so on epoll
  every pooled connection keeps the largest size it ever needed. Measured
  with 200 connections fetching a 1 MiB response, 2 workers: once they had
  closed, epoll stayed at 209 MiB RSS (4.8 MiB idle), while io_uring was
  back at 21 MiB ([#296](https://github.com/enghitalo/vanilla/issues/296)).
  Size an epoll box
  for peak connections times the largest buffers they may need, or bound
  that product with `max_connections`, `max_request_bytes` and
  `max_header_bytes`.

These sizes are compile-time constants, not configuration: changing them
means editing the source (see the [table](#where-each-knob-lives)).

**io_uring fixed cost per worker.** The ring is created with up to 16384
submission entries (fewer under a tight locked-memory limit, [§7](#7-io_uring-host-requirements))
and twice as many completion entries: at full size, 1 MiB of 64-byte SQEs
plus 512 KiB of 16-byte CQEs. On top of that comes the 32768-slot connection
table. Its buffers are allocated lazily, so idle slots cost only their struct.
Measured at idle with a trivial handler (`-prod -gc none`, Linux 7.1):
epoll used 2.9 MiB RSS with 2 workers and 3.1 MiB with 4; io_uring used
10.1, 17.7 and 23.8 MiB with 1, 2 and 3 workers, about 7 MiB per worker.
The rings also count against the locked-memory limit
([§7](#7-io_uring-host-requirements)).

**Kernel socket buffers.** vanilla does not size them, so TCP autotuning
within `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem` applies. Unix sockets use
`net.core.wmem_default` instead
([LOCAL_IPC §2](LOCAL_IPC.md#2-measured-on-this-machine)).

**Measuring memory.** Watch `VmRSS` in `/proc/<pid>/status` under steady
load; `bench/load.sh` samples it and reports the slope. Where transparent
huge pages are `always`, RSS moves in 2 MiB steps with no allocation at all
([V_PERF_TOOLBOX](V_PERF_TOOLBOX.md#profiling-allocations-under--gc-none)).

## 7. io_uring host requirements

- **Kernel.** On 5.19 or later each worker uses multishot accept. Older
  kernels get single-shot accept re-armed after every connection: correct,
  only slower. The check reads `uname -r`, so a backport that reports an older
  version also gets single-shot. Ring setup tries
  `SINGLE_ISSUER | DEFER_TASKRUN`, then `SINGLE_ISSUER | COOP_TASKRUN`, then no
  flags, at the ring size the locked-memory limit allows (next item). A worker
  whose ring still cannot be set up at that size halves it, down to 256
  entries, and logs it (`io_uring worker N: using M SQ entries (fell back from
  C)`). If nothing works, the process prints `Failed to initialize io_uring
  for worker N` (with a hint to raise `ulimit -l` on `ENOMEM`, where rings
  are charged to it) and exits: there is no automatic fallback to epoll (use
  [`iou_backend_available()`](#3-choosing-a-backend)).
- **Locked memory.** On kernels up to 5.11, and again from 6.14 (when the
  rings moved to io_uring's memory regions), ring memory counts against
  `RLIMIT_MEMLOCK` (`ulimit -l`). 5.12 to 6.13 charge it to the memory cgroup
  instead, as the [liburing README](https://github.com/axboe/liburing/blob/master/README)
  says. The budget is **per user**: every io_uring process of that user draws
  from it. A process with `CAP_IPC_LOCK` in the initial user namespace is
  never charged; root without it is (Docker and Kubernetes drop it by
  default, and a user namespace grants none that counts). A full-size ring
  (16384 SQEs of 64 bytes, 32768 CQEs of 16 bytes) is charged up to 2 MiB;
  measured on Linux 7.1, 1540 KiB at 16384 entries down to 28 KiB at 256.
  Where rings are charged, the backend picks one ring size for every worker
  before it spawns them: the largest that fits an even share of **half** the
  limit, counting a ring as twice max(64 bytes per entry, one page). It logs
  that once (`io_uring: 16 rings of 16384 SQ entries do not fit half of
  RLIMIT_MEMLOCK (ulimit -l); every worker starts at 2048 (fell back from
  16384)`). The other half is for the user's other rings and for rings the
  kernel has not released yet: it returns a closed ring's charge some
  milliseconds after the close, and a previous instance's after that
  process has exited, so a quick restart can still find them counted. A ring
  setup that fails with `ENOMEM` is also retried for about 100 ms. Measured
  on Linux 7.1 with 16 CPUs at 8 MiB: 16 workers start at 2048 entries, 4 at
  8192 and 64 at 512, back-to-back restarts and root in a user namespace
  included. Without the cap the first workers took full-size rings and a
  later one could not get even 256 entries, so 16 workers exited at startup.
  Rings that the user's other processes hold still count: when they hold more
  than half the limit, the last workers walk down to smaller rings, or fail.
  Where rings are not charged, or under no limit (`RLIM_INFINITY`), every
  ring is full size. Raise the limit for the service, with
  `LimitMEMLOCK=infinity` (systemd), `docker --ulimit memlock=-1`, or
  `ulimit -l`, and watch stderr for `fell back`: a worker on a smaller ring
  still runs, with smaller submission and completion queues (it drains
  completions in batches of at most a quarter of its ring). Container memory
  limits also apply to the rings.
- **`kernel.io_uring_disabled`** (Linux 6.6+): `0` allows io_uring (the
  default); `1` limits it to privileged processes and members of
  `kernel.io_uring_group`; `2` disables it. Ring setup then fails with
  `EPERM`.
- **Containers and sandboxes.** The default seccomp profiles of Docker (since
  25.0, [moby#46762](https://github.com/moby/moby/pull/46762)), containerd and
  Podman block the `io_uring_*` syscalls, and so do GitHub's hosted runners.
  Run epoll there, or allow the three syscalls in a custom profile.
- **`VANILLA_NO_IOURING`** (any value) makes `server.iou_backend_available()`
  return false. The test suites skip their io_uring cases on it, and CI sets
  it on hosted runners. It does nothing unless your `main` chooses the
  backend through that call.

## 8. TLS and kTLS

- TLS is served by the **epoll** backend only, and only in a build with
  `-d vanilla_tls`. `new_server` refuses a `tls_config` on every other
  backend (io_uring, poll, kqueue, IOCP).
- **Handshakes in parallel** need Mbed TLS built with `MBEDTLS_THREADING_C`
  and `MBEDTLS_THREADING_PTHREAD`. Distro packages usually are not, and then
  every worker takes turns in the crypto library. The server says so at
  startup, and [server/README.md](../server/README.md#tls) has the build
  recipe.
- **kTLS.** After the handshake, the record crypto moves into the kernel when
  the `tls` kernel module is available. The cipher suite is pinned to TLS 1.3
  `TLS_AES_128_GCM_SHA256` so the kernel can take it over. Look for one of
  these lines on stderr, printed once per process:

  ```text
  [ktls] engaged: kernel TLS TX+RX (TLS 1.3, AES-128-GCM)
  [ktls] fallback to userspace TLS: TCP_ULP failed (errno=2 No such file or directory)
  ```

  errno 2 (`ENOENT`) means the module is not loaded: `modprobe tls`, and list
  it in `/etc/modules-load.d/` to load it at boot. With kTLS, static files
  go out through `sendfile(2)` inside the TLS stream with no userspace copy;
  `/proc/net/tls_stat` counts the kernel's TLS sessions.
- `tls_config.set_ktls(false)` keeps every new connection in userspace (a
  kill switch). `tls_config.set_ktls_rx_no_pad(true)` saves a copy per
  received record, but only enable it on a kernel that has the fix (v7.2,
  v7.1.9+, v6.18.45+) or when no peer pads its records. Older kernels corrupt
  padded records (see the comment on `set_ktls_rx_no_pad`).

## 9. NUMA and interrupts

- `make_state` runs on the worker thread, after the optional pinning, so
  per-worker state (database pools, scratch buffers) is first touched by the
  thread that uses it: on a pinned worker it lands on that CPU's NUMA node.
- On a multi-socket machine, one option is one process per NUMA node, each
  started with `numactl --cpunodebind=N --membind=N` and `VANILLA_WORKERS` set
  to that node's CPU count, all sharing the port through `SO_REUSEPORT`
  ([§5](#5-the-accept-queue-backlog-and-sysctls)). Do not add
  `VANILLA_PIN_CPUS`: its absolute CPU numbers ignore `numactl`
  ([§2](#2-workers-and-cpus)).
- Network interrupts land on whichever CPUs the NIC queues are bound to
  (`/proc/interrupts`; `irqbalance` moves them). CPU 0 usually takes the most,
  which is why `bench/measure.sh` pins to the highest-numbered CPU. On a
  dedicated box, try both keeping the workers off the interrupt CPUs and
  spreading the NIC queues across the worker CPUs (`ethtool -L`), and keep
  whichever measures better.

## 10. Measuring your own box

- **Put the load generator on its own CPUs** (`taskset`, as in
  [§2](#2-workers-and-cpus)) and check that it is not the bottleneck: give it
  more CPUs; if req/s rises, it was. Over loopback the generator and the
  kernel's network path are usually the ceiling, not the server. On a 16-core
  box with an 8/8 split, `examples/tiny` and a hand-written C epoll server
  both topped out at about 340k req/s
  ([PERF_GAP_ANALYSIS](PERF_GAP_ANALYSIS.md#measuring-locally-loopback-is-the-ceiling-not-the-server)).
  For server efficiency, count instructions per request with callgrind, or
  load it from another machine.
- **Keep-alive or churn.** `wrk` keeps connections open. A churn test (a new
  connection per request) also measures the acceptor ([§3](#3-choosing-a-backend))
  and the client's ephemeral ports. Each port spends 60 s in TIME_WAIT on the
  side that closes first; the range is 32768–60999 by default, and
  `net.ipv4.tcp_tw_reuse=2` (the default) only reuses ports on loopback. On
  the generator, widen `net.ipv4.ip_local_port_range` or spread load across
  several source IPs. [LOCAL_IPC §1](LOCAL_IPC.md#1-what-loopback-tcp-actually-costs)
  has the numbers.
- **The repo's harnesses:** [`bench/measure.sh`](../bench/measure.sh) runs a
  micro-benchmark N times pinned to one CPU and reports the minimum;
  [`bench/load.sh`](../bench/load.sh) drives a server with `wrk` and reports
  req/s, RSS slope and CPU per 1k requests; [`bench/wrk.sh`](../bench/wrk.sh)
  is the throughput regression gate against recorded baselines. `wrk.sh` kills
  whatever holds ports 3000 and 8443 (`fuser -k`), so never run it on a
  machine you share. Methodology is in
  [BEST_PRACTICES §10](BEST_PRACTICES.md#10-benchmark-before-and-after-every-perf-change).
- **What to watch during a run:**

  | Question | Command |
  |---|---|
  | are connections waiting to be accepted? | `ss -ltn 'sport = :3000'`, `nstat -az TcpExtListenOverflows` |
  | which threads burn CPU? | `top -H -p <pid>` (workers, the epoll acceptor, `GC-marker-N`) |
  | where does each thread run? | `grep Cpus_allowed_list /proc/<pid>/task/*/status` |
  | how much memory, and is it still growing? | `grep VmRSS /proc/<pid>/status` over time, or `bench/load.sh` |
  | how many fds? | `ls /proc/<pid>/fd \| wc -l` against `ulimit -n` |
  | did kTLS engage? | the `[ktls]` line on stderr, `/proc/net/tls_stat` |

## Where each knob lives

Names as of this writing; grep for them if the code has moved.

| Knob | Where |
|---|---|
| worker count | `core.worker_count()`, `core.max_thread_pool_size` (`core/core.v`); `ServerConfig.workers` (`server/server.c.v`) |
| CPU pinning | `maybe_pin_worker` (`server/backend_epoll/worker_linux.c.v`, `server/server_io_uring_linux.c.v`) |
| listen backlog | `socket.listen_backlog` (`socket/socket_tcp.c.v`) |
| `SO_REUSEPORT`, `TCP_NODELAY` | `socket.create_server_socket`, `socket.set_tcp_nodelay` (`socket/socket_tcp.c.v`) |
| accept pause on `EMFILE` | `socket.accept_pause` (`socket/accept_starved_nix.c.v`) |
| request and pending-write caps (all backends) | `core.default_max_request_bytes`, `core.max_pending_write_bytes` (`core/core.v`) |
| per-connection buffers (epoll) | `read_buf_cap`, `write_buf_cap`, `sm_stream_body_above`, `sm_sendfile_chunk` (`server/backend_epoll/conn_state_linux.c.v`) |
| per-connection buffers (io_uring) | `io_uring.read_buf_cap`, `io_uring.write_buf_cap` (`io_uring/io_uring_linux.c.v`); `iou_stream_body_above` (`server/server_io_uring_linux.c.v`) |
| io_uring ring and pool | `io_uring.default_ring_entries`, `io_uring.max_conn_per_worker` (`io_uring/io_uring_linux.c.v`); `iou_init_ring` (`server/server_io_uring_linux.c.v`) |
| io_uring availability | `server.iou_backend_available()`, `VANILLA_NO_IOURING` (`server/server_io_uring_linux.c.v`) |
| limits and timeouts | `core.Limits` (`core/core.v`) |
| kTLS | `tls.Config.set_ktls`, `set_ktls_rx_no_pad` (`tls/tls_mbedtls_d_vanilla_tls.c.v`); `enable_ktls` (`tls/vanilla_tls.c`) |
| TLS record buffer | `tls_record_bytes` (`server/backend_epoll/tls_conn_linux.c.v`) |
| sendfile threshold | `static_assets.Config.sendfile_min_bytes` (`static_assets/static_assets.v`) |
