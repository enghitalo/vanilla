# Performance Gap Analysis: vanilla vs. the fast HTTP servers

Analysis of six reference implementations — HttpArena **tokio**, **minima-sync**
(C#/NativeAOT, raw io_uring), **rust-epoll**, **zeemo** (Zig, io_uring),
**libreactorng** (C, raw io_uring, TechEmpower plaintext leader), and the
**liburing** library/examples (proxy.c, releases 2.9–2.14) — compared against
vanilla's epoll and io_uring backends.

## What ALL the fast servers have in common

Every one of these servers, regardless of language or backend, shares the same
five architectural decisions. None of them wins through exotic tricks; they win
through syscall economy and shared-nothing dataflow.

1. **Shared-nothing, one listener per worker (`SO_REUSEPORT`).** Each
   worker thread/process creates its *own* listening socket with
   `SO_REUSEPORT` and accepts its own connections. The kernel load-balances.
   There is **no accept thread, no cross-thread handoff, no round-robin
   distribution** anywhere. (tokio: one current-thread runtime + listener per
   core; minima-sync & zeemo: pinned reactor per core, own listener;
   rust-epoll: thread per core, own listener; libreactorng: thread-local
   reactor, deployed one process per core.)

2. **HTTP/1.1 pipelining with batched writes.** One `recv` may contain N
   requests. They all parse every complete request in the buffer, append every
   response into a single per-connection write buffer, and issue **one
   `send` for the whole batch**. Leftover partial bytes are compacted to the
   buffer start (`memmove`) and the next recv appends after them. This is
   zeemo's self-described "50M-RPS difference vs the obvious
   one-request-per-recv loop".

3. **Persistent per-connection buffers, fd-indexed.** A connection owns a
   reused recv buffer (8–16 KiB) and write buffer (16–64 KiB) for its whole
   lifetime; state lookup is a flat array indexed by fd (`slots[MAX_FD]`),
   never a hash map. Connection objects are pooled (vanilla's io_uring pool
   already does this part right).

4. **Roughly one syscall per event-loop iteration, not per request.**
   - epoll flavor (rust-epoll): adaptive `epoll_wait` timeout — `0` (pure
     poll) while the last wait returned events, `-1` (block) only after an
     empty poll. Plus `accept4` drain loops.
   - io_uring flavor (minima-sync, zeemo, libreactorng): a single
     `io_uring_submit_and_wait(1)` per loop iteration submits *all* SQEs
     queued during the previous CQE drain and waits, then the CQ ring is
     drained in a batch directly from the mmap'd ring (zero syscalls) and
     acknowledged with **one** `cq_advance(n)` — never `cqe_seen` + `submit`
     per CQE.

5. **Zero hot-path allocation and minimal parsing.** Responses are built from
   precomputed static byte literals + an in-place itoa for `Content-Length`
   (or a back-patched placeholder), written directly into the connection's
   write buffer. Only the 3–4 headers that affect framing/lifetime are
   parsed (`Content-Length`, `Transfer-Encoding: chunked`, `Connection:
   close`); everything else is skipped or kept as raw slices. None of them
   sends a `Date` header (libreactorng sends one cached per second).

Secondary common traits: `TCP_NODELAY` set at accept, `accept4(SOCK_NONBLOCK)`,
`MSG_NOSIGNAL` on sends, CPU pinning of each worker to one core
(`sched_setaffinity`), large backlog, and aggressive inlining of tiny helpers.

## Why they beat vanilla on epoll

Vanilla epoll backend today (`backend_epoll/worker_linux.c.v`,
`conn_state_linux.c.v`):

| Aspect | vanilla | fast servers |
|---|---|---|
| Accept | dedicated accept loop thread, round-robin fd handoff to worker epolls | per-worker `SO_REUSEPORT` listener, kernel balances |
| Pipelining | **dropped** — `buf.trim(total)` discards trailing pipelined bytes | parse all, one batched send |
| Recv buffer | fresh `[]u8{cap: 256}` allocated *per EPOLLIN event*, grown by doubling | persistent 8–16 KiB per-conn buffer, reused |
| State lookup | `map[int]&ConnState` | flat fd-indexed array |
| Wait strategy | `epoll_wait(-1)` (or 250 ms sweep) | adaptive timeout 0/-1 busy-poll hybrid |
| Response | handler allocates `[]u8`, one `send` per request, freed after | static prefix + itoa into reused write buffer |
| Pinning | none | `sched_setaffinity` per worker |

The handoff model is the structural cost: every connection crosses a thread
boundary (cache-cold), the accept thread serializes all accepts, and the
round-robin ignores load. The 256-byte starting buffer guarantees ≥2 recv
calls + reallocs for any normal request. Dropping pipelined bytes makes
pipelined benchmarks (and clients) outright fail/slow.

## Why they beat vanilla on io_uring

Vanilla io_uring backend today (`http_server_io_uring_linux.c.v`,
`io_uring/io_uring_linux.c.v`):

| Aspect | vanilla | fast servers / liburing guidance |
|---|---|---|
| Setup flags | `IORING_SETUP_SQPOLL`, sq thread pinned per worker | **no SQPOLL**: `SINGLE_ISSUER \| DEFER_TASKRUN` (minima-sync; liburing: "the preferred and recommended way"), `COOP_TASKRUN` fallback; libreactorng/zeemo use *no* flags and still win via batching |
| Loop | `wait_cqe` → handle **one** CQE → `cqe_seen` → **`submit` per CQE** | `submit_and_wait(1)` once per loop, batch-drain CQ, one `cq_advance(n)` |
| Accept | single-shot, re-armed each accept | multishot accept, re-arm only when `IORING_CQE_F_MORE` is unset |
| Recv | single-shot into fixed 4 KiB; **partial requests broken** (`buf[..bytes_read]` passed to handler as-is) | single-shot recv appending at offset (minima-sync/zeemo) with framing across recvs; or multishot recv + provided buffer rings (proxy.c) |
| Pipelining | none — one request per recv assumed | drain-all + one batched send |
| Send flags | `0` | `MSG_NOSIGNAL` |
| Response | handler `[]u8` alloc, freed per request | serialized into persistent per-conn write buffer |
| CQ size | SQ=CQ=16384 | small SQ (covers one batch), big CQ (`IORING_SETUP_CQSIZE`, e.g. 4096) to avoid overflow |
| Ring fd | normal | `io_uring_register_ring_fd()` removes fget/fput per enter |

SQPOLL is actively harmful here: with one worker per core *plus* one kernel SQ
poll thread per worker, the machine is 2× oversubscribed and the poll threads
burn the cores the workers need. Every modern reference (liburing proxy.c,
minima-sync) chose `DEFER_TASKRUN + SINGLE_ISSUER` instead. The
submit-per-CQE loop is the second big cost: under load it makes vanilla pay
~2 syscalls per request where the others pay ~1 per *batch* of requests.

The partial-request bug is also a correctness gap: a request fragmented across
TCP segments (or larger than 4096 bytes) reaches the handler truncated.

---

## Changes to make in vanilla

Ordered by expected impact. All consistent with the three rules (no slowdown,
minimal abstraction, keep it simple) and BEST_PRACTICES.md.

### 1. epoll: kill the accept thread — per-worker `SO_REUSEPORT` listeners

Each worker creates its own listening socket (`SO_REUSEADDR + SO_REUSEPORT +
TCP_NODELAY`, nonblocking), registers it in its own epoll, and runs an
`accept4(..., SOCK_NONBLOCK)` drain loop on listener EPOLLIN. Delete
`handle_accept_loop` and the round-robin. The io_uring backend already creates
per-worker listeners — reuse that path. Connections then live and die on one
core: no cross-thread cache misses, no accept serialization.

### 2. Both backends: pipelining with batched send

In the request loop, after framing one request, do **not** trim trailing
bytes. Loop: `frame → handle → append response to write buffer → advance
offset` until the buffer has no complete request left; `memmove` the leftover
to the front; then issue **one** `send` for all accumulated responses.
Backpressure path (partial send → park remainder for EPOLLOUT / resubmit
send from offset) already exists in both backends and stays as is.

### 3. Both backends: persistent per-connection buffers + flat fd table

- Replace `map[int]&ConnState` (epoll) with `[]&ConnState` (or a struct
  array) of size `max_fd`, indexed by fd — O(1), no hashing. Same for any
  per-fd lookup.
- Give every connection a persistent recv buffer (start 8 KiB) and write
  buffer (16 KiB), allocated once at accept (or taken from a pool, as the
  io_uring `pool_init` already does) and reused across requests. Stop
  allocating `[]u8{cap: 256}` per EPOLLIN; recv appends at `len` into the
  spare capacity of the persistent buffer.
- Keep the existing connection pool; on close, return the connection (with
  its buffers) to the pool instead of freeing.

### 4. io_uring: rewrite the event loop for batching

```
// per loop iteration — ONE syscall
io_uring_submit_and_wait(&ring, 1)
for io_uring_peek_cqe(&ring, &cqe) == 0 {   // or copy_cqes batch of 256
    dispatch(cqe)                            // queues new SQEs, no submit
    count++
    advance to next cqe
}
io_uring_cq_advance(&ring, count)            // one ack for the whole batch
```

All `prepare_*` calls only write SQEs; the single `submit_and_wait` at the top
of the loop flushes everything queued during the previous drain. Remove
`io_uring_submit` from `handle_io_uring_read` and friends.

### 5. io_uring: drop SQPOLL, use modern setup flags

```
params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN
             | IORING_SETUP_CLAMP | IORING_SETUP_CQSIZE
params.cq_entries = 4096        // big CQ
entries (SQ)     = 256..1024    // only needs to cover one submit batch
```

Fallback chain for older kernels: drop `DEFER_TASKRUN` → try
`IORING_SETUP_COOP_TASKRUN` → plain `0` flags (libreactorng proves plain flags
+ batching is already fast). Also call `io_uring_register_ring_fd(&ring)`
after init.

### 6. io_uring: multishot accept + fix partial reads

- Enable multishot accept (`io_uring_prep_multishot_accept`); re-arm only
  when the CQE lacks `IORING_CQE_F_MORE`. The code exists
  (`use_multishot`) — it's just never turned on.
- Recv must append: post recv into `buf + bytes_read` with the remaining
  capacity, run the framing parser, and only call the handler when a request
  is complete (reuse `frame_request_length_lim` exactly as the epoll path
  does). This fixes the fragmented/large-request bug and enables pipelining.
- Set `MSG_NOSIGNAL` on `io_uring_prep_send` flags.
- Set `TCP_NODELAY` on accepted fds (currently missing in this backend).

### 7. epoll: adaptive wait timeout (busy-poll hybrid)

```v
mut timeout := -1
for {
    n := C.epoll_wait(epoll_fd, &events[0], max_events, timeout)
    timeout = if n > 0 { 0 } else { -1 }   // poll while hot, block when idle
    ...
}
```

One line of state, measurable latency/throughput win under load, zero cost
idle. (Compose with the existing 250 ms sweep: use `0` when hot, `250`/`-1`
as today when idle.)

### 8. Pin workers to cores

After spawning each worker, `sched_setaffinity` it to CPU `i` (minima-sync,
zeemo). Cheap, keeps caches warm, pairs with `SO_REUSEPORT` balancing.

### 9. Response building: raw write buffer, NO writer abstraction

**Benchmarked (see "Benchmark evidence" below): a ResponseWriter abstraction
is not justified.** The zeemo-style header-gutter `finalize()` (memmove) is
*slower* than writing raw bytes sequentially, and for 1 KiB bodies it is even
slower than malloc-per-response. And end-to-end, the allocation itself is
noise next to syscall structure: with batched sends, malloc-per-response vs
zero-alloc measured within ±1%; without pipelining the three models are
identical. The real win of this item is *enabling item 2's batched send* and
removing GC churn — not the nanoseconds of the alloc.

So the contract should be the rawest possible one: the handler appends the
**complete raw HTTP response bytes (headers included)** to the connection's
persistent write buffer. No struct, no methods, no finalize step:

```v
// handler appends a full raw response into `out` (the conn's write buffer)
fn (req []u8, fd int, mut out []u8) !
```

Static routes append a precomputed `const ... .bytes()`; dynamic routes append
a `const` prefix, the Content-Length digits (`write_decimal`-style helper, or
back-patch), `\r\n\r\n`, and the body. Optional helpers stay plain functions;
nothing is mandatory. The server batches everything in `out` into one send
(item 2) and never frees anything.

**Bug found while tracing this path:** `send_or_park` /
`handle_io_uring_write` call `resp.free()` on whatever the handler returns —
but the bundled examples return module-level consts
(`response.tiny_bad_request_response`). Freeing a const's data once means
every later request that returns it sends from freed memory. Verify with a
running build; if confirmed, this is a correctness reason (not just perf) to
change the ownership contract.

#### Benchmark evidence (Linux x86-64, gcc -O3, 4 cores; C mirrors of each model)

Micro (13-byte body, per response): precomputed-static memcpy 1.6 ns; raw
write into persistent buffer 2.2 ns; gutter-writer finalize 4.6 ns;
malloc+build+free (current contract) 6.6 ns; malloc+copy+free (compat) 8.9 ns.
With a 1 KiB body the gutter writer (30.9 ns) loses to malloc (22.2 ns) — the
memmove dominates. Request side: fresh 256 B grow-buffer per event 21.4 ns vs
persistent 8 KiB buffer 12.4 ns.

End-to-end (loopback epoll server, identical parsing, 16 conns):

| model | depth=1 | depth=16 (pipelined) |
|---|---|---|
| persistent buffers + raw write + one send per batch | 60.4k req/s | **977k req/s** |
| persistent buffers + malloc/copy/free + one send per batch | 61.3k | 961–979k |
| fresh grow buffer + malloc + **send per response** (current) | 61.0k | **606k** |

Reading: per-request allocation costs ~7–9 ns — invisible at depth 1 (syscalls
dominate) and within noise even pipelined. What costs 38% is the send-per-
response structure (items 1–4). Eliminate the allocation anyway — it's free to
do once buffers are persistent, and in V it also removes GC/manualfree churn —
but spend the effort on syscall structure, not on response-builder machinery.
Caveat: C glibc malloc in a tight loop is the *best* case; V's default Boehm
GC makes the gap larger, in vanilla's favor of the raw contract.

### 10. Smaller items

- Backlog: raise `listen()` backlog (rust-epoll uses 65536; at least make it
  configurable — 1024 is fine until accept bursts).
- Limit header parsing on the hot path to the framing trio (already the
  case in `frame_request_length_lim` — keep it that way; never pre-parse all
  headers).
- Events array: 1024 (`socket.max_connection_size`) per `epoll_wait` is fine;
  512 (rust-epoll) and 256 CQEs (zeemo) are in the same range.
- Optional/later, from liburing proxy.c: multishot recv + provided buffer
  rings (`io_uring_setup_buf_ring`, `IOSQE_BUFFER_SELECT`) to cut per-conn
  recv buffer memory; registered files/direct descriptors; `send_zc` for
  large responses; NAPI busy-poll (`io_uring_register_napi`). None of the
  benchmark winners *need* these — zeemo and libreactorng win without them —
  so do items 1–9 first and benchmark before adding this complexity.

## Suggested order of work

| Step | Change | Backend | Risk | Expected gain |
|---|---|---|---|---|
| 1 | Per-worker reuseport listeners | epoll | low | large |
| 2 | Persistent buffers + flat fd table | both | low | large |
| 3 | Pipelining + batched send | both | medium | very large (pipelined), moderate (plain) |
| 4 | Batched submit/drain loop | io_uring | low | large |
| 5 | Drop SQPOLL → DEFER_TASKRUN/SINGLE_ISSUER | io_uring | low | large |
| 6 | Multishot accept + partial-read fix | io_uring | low | correctness + moderate |
| 7 | Adaptive epoll timeout | epoll | trivial | moderate |
| 8 | CPU pinning | both | trivial | small–moderate |
| 9 | Raw write-buffer handler contract (no writer abstraction) | both | medium | small alone; enables 3 |

Benchmark each step in isolation with `-prod` (wrk/rewrk, plain + pipelined
profiles) and verify with helgrind, per CONTRIBUTING.md.
