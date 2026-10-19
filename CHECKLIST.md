# Vanilla HTTP Server - Improvement Checklist

> Comprehensive roadmap of improvements, features, and implementations
>
> **Last Updated:** 2026-10-11
> **Project:** Vanilla HTTP Server v0.0.1

Each item carries a status in its heading:

- **✅ RESOLVED** — done; the entry says where it lives and what tests it.
- **🟡 PARTIAL** — mostly done; the entry lists only what remains.
- **🔴 OPEN** — not done yet.

Open work links its GitHub issue. Code sketches follow
[docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md): handlers are `core.Handler`s
that append into `out` and return a `core.Step`, static responses are `const`
strings appended with `core.append_str`, and nothing on the request path
concatenates, interpolates or allocates per request. The
[README roadmap](README.md#roadmap) tracks the same work at feature level.

---

## 📋 Table of Contents

1. [Critical Bugs](#-critical-bugs-must-fix)
2. [Foundation Improvements](#-foundation-improvements-enables-everything)
3. [HTTP Protocol Features](#-http-protocol-features)
4. [TLS/HTTPS Support](#-tlshttps-support)
5. [Backend Improvements](#-backend-improvements)
6. [Code Quality & Safety](#-code-quality--safety)
7. [Performance Optimizations](#-performance-optimizations)
8. [Example Applications](#-example-applications-priority)
9. [Testing & Validation](#-testing--validation)
10. [Documentation](#-documentation)

---

## 🔴 Critical Bugs (MUST FIX)

### 2. Dynamic Route Matching — ✅ RESOLVED
- **Resolution:** routing moved from the example into two library modules,
  both zero-allocation per request:
  - `http1_1/veb_like/` — `@['GET /users/:id']` methods compiled into a segment
    trie at startup; 404/405/501 and HEAD handled; parameters are zero-copy
    `Params` views (`get`/`at`/`slice`), not percent-decoded; the query string
    is excluded from matching.
  - `http1_1/router/` — the method and a segment cursor (`Path.next/done/rest`)
    read straight from the request line, for handlers written as `match`.
- **PRs:** #238 (two zero-allocation routers), #240, #242.
- **Testing:** `http1_1/veb_like/router_test.v`, `http1_1/router/router_test.v`,
  `examples/veb_like/src/main_test.v` (incl. `test_routing_allocates_nothing`),
  `examples/router/src/main_test.v`; benchmark in `bench/router/`.
- **Follow-up:** compiler features for a zero-allocation declarative router
  ([#239](https://github.com/enghitalo/vanilla/issues/239)).

### 3. Windows IOCP Overlapped Structure — ✅ RESOLVED
- **File:** `server/server_windows.c.v`
- **Issue:** `h_event` in OVERLAPPED structure never initialized
- **Resolution:** The IOCP backend was rewritten around completion-port
  dispatch only — no event handles at all. Each connection embeds two
  `WinOp` contexts (OVERLAPPED first field, zeroed before every post); a
  completion's `lpOverlapped` pointer IS the op context, so `hEvent` is
  never used and nothing leaks (PR #118).
- **Testing:** Covered by the backend behaviour suite
  (`tests/backend_behaviors_test.v`) running against IOCP on Windows.

### 4. Kqueue Client Writes Have No Backpressure — 🔴 OPEN ([#154](https://github.com/enghitalo/vanilla/issues/154))
- **Was:** "Empty kqueue write callback". The callback struct is gone (PR #102
  unified the handler contract); `kqueue/kqueue_darwin.c.v` is now thin
  wrappers and the worker is `process_kqueue_worker` in
  `server/async_darwin.c.v`.
- **Issue now:** client writes are synchronous — `kq_handle_request` and
  `kq_run_cont` call `response.send_response`, which fails on `EAGAIN`, so a
  response larger than the socket buffer closes the connection.
  `EVFILT_WRITE` is only used for watches on external fds.
- **Priority:** 🟡 MEDIUM (macOS only)
- **Strategy:** keep unsent bytes per connection and resume them on
  `EVFILT_WRITE`, as epoll (`park_write` / `flush_batch`) and poll
  (`server/backend_poll/reactor_nix.c.v`) do. Sketch:
  ```v
  // server/async_darwin.c.v — one per connection, reused for its whole life
  struct KqConn {
  mut:
  	read_buf    []u8 // framing loop: every complete request, split or pipelined (#19)
  	out         []u8 // what the handler appended; reset, never reallocated
  	write_off   int  // bytes of `out` already on the wire
  	awaiting_fd int = -1
  }

  // Send what fits; park the rest on EVFILT_WRITE. false = close the connection.
  fn kq_flush(kq int, fd int, mut c KqConn) bool {
  	for c.write_off < c.out.len {
  		n := C.send(fd, unsafe { &c.out[c.write_off] }, c.out.len - c.write_off, 0)
  		if n > 0 {
  			c.write_off += int(n)
  			continue
  		}
  		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
  			// resume on writable; read nothing more until `out` drains
  			return kqueue.add_fd_to_kqueue(kq, fd, kqueue.evfilt_write) == 0
  		}
  		return false
  	}
  	unsafe {
  		c.out.len = 0
  	}
  	c.write_off = 0
  	return true
  }
  ```
- **Dependencies:** none; lands together with #19 and #21's kqueue part.
- **Testing:** add kqueue to `tests/backend_behaviors_test.v` (large
  responses, slow readers, `write_timeout_ms`).

---

## 🏗️ Foundation Improvements (ENABLES EVERYTHING)

### 5. Query String Parsing — ✅ RESOLVED
- **Resolution:** `HttpRequest.get_query_slice(key []u8) ?Slice`
  (`http1_1/request_parser/request_parser.v`) returns a zero-copy `Slice` into
  the request buffer, with no `error()` on the not-found path
  (`find_byte_idx`); `has_query(key []u8) bool` also sees a bare flag
  (`?debug`), which `get_query_slice` returns as none. Both cut each element at
  its `&` and compare its name in place, one `memchr` per element.
  `get_query(key string)` is kept as a deprecated wrapper. Values are raw;
  `percent_decode_into(src, mut out, plus_as_space)` appends them decoded into
  a buffer the caller reuses (no allocation once it has the room), and
  `examples/url_form/` decodes with it once at the edge.
- **Testing:** `request_parser_test.v` (single, multiple, last, missing key,
  no query, `?empty=`, an empty key, special characters, bare keys before,
  between and after valued ones, name prefixes; decoding: malformed and
  truncated escapes, `+` both ways, decode-once, NUL/CR/LF, zero heap growth
  over 20k calls).
- **PRs:** #279 (empty key), #286 (`has_query`), #289 (`percent_decode_into`).

### 8. Header Injection Utility — ✅ RESOLVED (in the examples)
- **Resolution:** header injection is a wrapper around the handler that
  splices into `out` in place, not a library function returning a new array
  (that would be one allocation and a copy per response, against
  [BEST_PRACTICES §1/§4](docs/BEST_PRACTICES.md)).
  `insert_after_status_line(mut out, start, headers)` (in
  `examples/security_headers/src/main.v` and
  `examples/middleware/src/decorators.v`) inserts a `const` header block after
  the status line with `vmemmove` / `vmemcpy`, allocation-free once `out` has
  reached its high-water mark, and never slices `out`.
- **Testing:** `examples/security_headers/src/main_test.v`,
  `examples/middleware/src/main_test.v` (`test_chain_allocates_nothing`,
  `test_chain_keeps_the_write_buffer`).

---

## 🌐 HTTP Protocol Features

### 10. HTTP/1.1 Host Header Requirement — ✅ RESOLVED
- **Resolution:** `HttpRequest.validate_http1()`
  (`http1_1/request_parser/request_parser.v`) rejects an HTTP/1.1 request
  without exactly one `Host` (RFC 9112 §3.2) and one carrying both
  `Content-Length` and `Transfer-Encoding`; `count_header()` counts the
  occurrences. It is opt-in: the handler calls it and answers 400.
  `examples/conformance/` does so (and also rejects whitespace in the Host
  value); so does `examples/chunked_streaming/`.
- **PRs:** commit `8c05b43` (RFC parsing), #105 (conformance example + CI).
- **Testing:** `test_validate_http1_*`, `test_count_header` in
  `request_parser_test.v`; h1spec `--strict` and Http11Probe CI gates (see the
  README scorecard).

### 11. Case-Insensitive Header Names — ✅ RESOLVED
- **Resolution:** `ascii_ci_eq()` folds ASCII case without allocating; it backs
  `get_header_value_slice()`, `count_header()`, `line_header_value()` and the
  chunked `Transfer-Encoding` check (`http1_1/request_parser/request_parser.v`).
- **Testing:** `test_get_header_value_case_insensitive` and the
  `Host`-vs-`Hostname` test in `request_parser_test.v`.

---

## 🔒 TLS/HTTPS Support

### 15. V TLS Bindings — ✅ RESOLVED
- **Resolution:** instead of V declarations of raw `mbedtls_*` structs, a C
  shim over Mbed TLS 4 / PSA (`tls/vanilla_tls.c`, `tls/vanilla_tls.h`) is
  bound from `tls/tls_mbedtls_d_vanilla_tls.c.v`, built with `-d vanilla_tls`
  (`tls/tls_stub_notd_vanilla_tls.c.v` otherwise). API: `tls.initialize()`,
  `new_self_signed()`, `new_from_pem()`, `new_client()`, `set_alpn()`,
  `set_ktls()`; `Session.handshake()`, `read_into()`, `write_from()`,
  `enable_ktls()`, `close_notify()`. TLS 1.3, kTLS offload, client mode with SNI
  and certificate verification.
- **PRs:** commit `794d685`, #16 (opt-in build), #74, #79, #178, #227, #245.
- **Testing:** `tls/tls_test.v`, `tls/tls_client_nix_test.v`.
- **Note:** [#13](https://github.com/enghitalo/vanilla/issues/13) ("support
  https") is closed by the HTTPS example (#34).

### 16. Integrate TLS into the Server — 🟡 PARTIAL
- **Done:** TLS lives in the backend worker, not in the request/response
  codecs, enabled with `ServerConfig.tls_config`. HTTPS connections run on
  the epoll worker's own connection state, reactor and timeouts, the same as
  plain HTTP: `server/backend_epoll/tls_conn_linux.c.v` adds only the
  handshake and the record I/O (Mbed TLS, or kTLS with `sendfile(2)`) behind
  `conn_recv` / `conn_send`. So `.suspend` with park deadlines, takeover
  (WebSocket over TLS), server push, `on_worker_start`, streamed uploads,
  `Expect: 100-continue` and a `.close` that sends everything first
  ([#275](https://github.com/enghitalo/vanilla/issues/275)'s TLS gap) all
  work over HTTPS; on userspace TLS a `core.queue_file` region goes out in
  64 KiB chunks, and a request pipelined behind a file waits until the file
  is out (no 8 MiB write-cap truncation). The plaintext path did not get
  slower: callgrind counts 792 → 789 instructions per request. PRs #96,
  #158, #159, #160, #181, #182, #320.
- **Testing:** `tests/tls_async_test.v` (the async features above, over
  userspace TLS and kTLS), `tls_pipelining_test.v`, `tls_static_test.v`,
  `tls_timeouts_test.v`, `tls_workers_test.v` (`.github/workflows/tls_backend.yml`).
- **Also done:** `new_server` refuses `tls_config` on every backend but
  epoll, before it binds anything; io_uring and kqueue used to accept it and
  serve plaintext ([#156](https://github.com/enghitalo/vanilla/issues/156)).
  Tested by `test_new_server_refuses_tls_where_it_is_not_served` in
  `server/server_test.v`, on Linux, Windows and in a macOS job.
- **Remains:**
  - TLS on io_uring and kqueue (refused for now), and on IOCP ([#115](https://github.com/enghitalo/vanilla/issues/115)),
    HTTP/2 over TLS + ALPN ([#142](https://github.com/enghitalo/vanilla/issues/142)),
    kTLS + `sendfile` for every static path ([#76](https://github.com/enghitalo/vanilla/issues/76)).

### 17. Self-Signed Certificate Generation — ✅ RESOLVED
- **Resolution:** `tls.new_self_signed(SelfSignedOpts)` generates an X.509 v3
  certificate in C (`vtls_use_self_signed` in `tls/vanilla_tls.c`) with SANs
  (default `localhost`, `127.0.0.1`, `::1`; `sans: ['IP:203.0.113.5']` for a
  real host) and keeps the identity across restarts with `persist_dir`.
  `Config.cert_pem()` / `key_pem()` export it.
- **PRs:** commit `794d685`, #150 (SANs + persistent identity, closes #149).
- **Testing:** `test_self_signed_*` in `tls/tls_test.v`.

---

## ⚙️ Backend Improvements

### 18. Keep-Alive in the Epoll Backend — ✅ RESOLVED
- **Resolution:** pooled per-connection state (`server/backend_epoll/conn_state_linux.c.v`)
  with persistent read and write buffers; every complete request in a read is
  answered (pipelining) and unsent bytes park on `EPOLLOUT`; idle keep-alive
  connections are closed after `idle_timeout_ms`. The server keeps the
  connection unless the handler returns `.close`.
- **PRs:** #22 (keep-alive + pipelining), #50 (pooled `ConnState`), #151
  (idle timeouts).
- **Testing:** `test_epoll_pipelining_and_framing`,
  `test_epoll_keepalive_under_timeouts`, `test_epoll_idle_keepalive_timeout`
  in `tests/backend_behaviors_test.v`;
  `server/backend_epoll/reactor_pipelining_test.v`.
- **Related:** `Connection: close` ignored by the benchmark entries
  ([#88](https://github.com/enghitalo/vanilla/issues/88)); ConnState pool
  high-water mark ([#166](https://github.com/enghitalo/vanilla/issues/166)).

### 19. Keep-Alive in the Kqueue Backend — 🟡 PARTIAL ([#154](https://github.com/enghitalo/vanilla/issues/154))
- **Done:** the fd stays registered after `.done` (`server/async_darwin.c.v`),
  and a half-close after a request is handled (#103, PR #108).
- **Remains:** `http1_1/request/request.c.v` `read_request` reads one request
  into a fresh buffer per request: bytes pipelined after it are dropped, a
  request split across segments gets 444, and a request arriving while one is
  parked overwrites `conn.out`. Needs the per-connection read buffer and
  framing loop of `server/backend_poll/reactor_nix.c.v` (see #4's sketch).
- **Testing:** kqueue is not in `tests/backend_behaviors_test.v` yet.

### 20. Complete IOCP Keep-Alive Implementation — ✅ RESOLVED
- **File:** `server/server_windows.c.v`
- **Issue:** Partial keep-alive implementation
- **Resolution:** Full rewrite: per-worker IOCP ports (shared-nothing),
  persistent pooled per-connection buffers, request framing via
  `request_parser`, HTTP/1.1 keep-alive + pipelining (batch answered in one
  WSASend), large-body streaming drain (drain-then-respond), limits
  (max_connections / 413 / 431), read+write timeout sweep, and graceful
  shutdown through the shared `draining` flag (PR #118).
- **Testing:** `tests/backend_behaviors_test.v` (pipelining, split
  framing, max_connections, read timeout, graceful shutdown, 2 MiB upload
  drain) passes on Windows; sustained-load run: ~287K req/s, 0 errors.
- **Follow-ups:** watch reactor for `.suspend` ([#117](https://github.com/enghitalo/vanilla/issues/117)),
  batch dequeue ([#116](https://github.com/enghitalo/vanilla/issues/116)),
  `TransmitFile` ([#114](https://github.com/enghitalo/vanilla/issues/114)).

### 21. Add Timeout Support to Event Loops — ✅ RESOLVED (kqueue still open, [#154](https://github.com/enghitalo/vanilla/issues/154))
- **Files:** All backend files
- **Issue:** Infinite waits in epoll_wait/kevent/etc
- **Impact:** Connections can hang forever
- **Resolution:** `core.Limits` carries `read_timeout_ms`, `write_timeout_ms`
  and `idle_timeout_ms` (0 inherits `read_timeout_ms`, -1 = never). Each worker
  keeps per-connection deadlines and sweeps them at most once per
  `Limits.sweep_interval_ms()`, which is also its blocking-wait timeout while a
  deadline may be armed; with no timeout set there is no sweep and no wake.
  A deadline is armed at **accept** (the read deadline, or the idle one when
  there is no read timeout), so a connection that never sends a byte (or
  never finishes its TLS handshake) is reaped and
  frees its `max_connections` slot; idle keep-alive connections are closed
  silently after the idle budget. 408 only for a partial request. The
  original plan (a fixed 5-second `epoll_wait`/`kevent` timeout) was not used:
  a rate-limited sweep costs nothing when no timeout is configured (PR #151).
  Parked requests are bounded by `Limits.park_timeout_ms` /
  `watch_fd_deadline` (PR #249, #200; epoll worker only). An
  `http1_1.upstream` exchange ends at whichever passes first, its own deadline
  (the pool's maintenance timer) or `park_timeout_ms`, with `.timeout` either
  way (#322).
- **Still open:** the kqueue (darwin) backend enforces none of these timeouts
  (nor `max_connections`): `wait_kqueue(..., -1)` never wakes for a sweep, and
  `accept` busy-spins on `EMFILE`.
- **Testing:** `tests/backend_behaviors_test.v` — `check_silent_conn_timeout`,
  `check_idle_keepalive_timeout`, `check_idle_opt_out`,
  `check_reaped_slots_free_max_connections`, `check_keepalive_under_timeouts`,
  run as `test_{epoll,iouring,poll,iocp}_*`; `tests/tls_timeouts_test.v` for
  the HTTPS path (`-d vanilla_tls`, `.github/workflows/tls_backend.yml`);
  end to end through an example in `examples/request_limits/src/main_test.v`;
  `core/limits_test.v` for the `idle_ms()` / `sweep_interval_ms()` rules.

### 23. Handle Partial Send/Recv — 🟡 PARTIAL
- **Done:** epoll (`park_write` / `flush_batch`, capped by
  `core.max_pending_write_bytes`), io_uring (partial-send remainder + write deadline),
  poll (`write_off` + `POLLOUT`) and IOCP keep the unsent bytes and resume when
  the socket is writable — never a busy retry on `EAGAIN`. Partial reads are
  framed by `request_parser.frame_request_length_lim_idx` on every backend but
  kqueue.
- **Remains:**
  - kqueue: `response.send_response` fails on `EAGAIN` and the connection is
    closed (#4, [#154](https://github.com/enghitalo/vanilla/issues/154)).
  - Server push: a per-connection outbound queue
    ([#23](https://github.com/enghitalo/vanilla/issues/23)).
  - Close paths: the untransmitted tail is lost when the client keeps sending
    after `close()` ([#272](https://github.com/enghitalo/vanilla/issues/272));
    gaps after #268 ([#275](https://github.com/enghitalo/vanilla/issues/275);
    its TLS `.close` gap is fixed);
    `.close` ordering on parked push connections
    ([#270](https://github.com/enghitalo/vanilla/issues/270));
    `core.queue_file` sent after another client's response
    ([#271](https://github.com/enghitalo/vanilla/issues/271)).

---

## 🛡️ Code Quality & Safety

### 25. Bounds Checking in Parsers — ✅ RESOLVED
- **Resolution:** the parser keeps `@[direct_array_access]` and `memchr` /
  `memmem` on the hot path ([V_PERF_TOOLBOX](docs/V_PERF_TOOLBOX.md#attributes-functions--structs));
  every scan is length-bounded (`find_byte_idx(buf, len, c)`), and the bounds
  are proven by tests instead of per-index checks.
- **Testing:** 72 tests in `http1_1/request_parser/request_parser_test.v`
  (malformed, truncated, oversized, `test_frame_split_fuzz` over every prefix
  of a request), `tests/framing_ambiguity_test.v`,
  `tests/chunked_trailer_test.v`, h1spec / Http11Probe CI gates.
- **PRs:** #110, #204, #209, #214.
- **Optional:** a coverage-guided fuzzer, and an ASan/UBSan CI job
  (`race_detector.yml` is TSan only).

### 27. Replace Magic Numbers with Constants — ✅ RESOLVED
- **Resolution:** the tunables are `core.Limits` fields; each backend names its
  own sizes (`sm_*`, `read_buf_cap`, `write_buf_cap` in `server/backend_epoll`,
  `iou_*` in io_uring, `pl_*` in poll, `win_*` in IOCP, `tls_*` for HTTPS,
  `kq_*` in kqueue). The two caps every backend shares are one `core` const
  each: `core.default_max_request_bytes` (8 MiB, the request ceiling when
  `Limits.max_request_bytes` is 0; also the h2 body cap) and
  `core.max_pending_write_bytes` (8 MiB, the write-side cap, which also bounds
  `push_watermark_bytes`).
- **Note:** kqueue's sizes are named, not changed; its backpressure is #154.

### 28. Remove Dead Code — ✅ RESOLVED
- **Resolution:** `examples/veb_like/main.v` and its commented-out blocks were
  replaced in PR #238; the remaining commented code in the tree is usage
  examples inside doc comments.
  The leftovers `v -check` reported (`find_byte`, `bytes_equal`, `slash_u8`,
  `pool_has_capacity`, the commented-out Windows `sockaddr_in`) went with
  [#279](https://github.com/enghitalo/vanilla/issues/279).

---

## ⚡ Performance Optimizations

### 29. Pre-allocate Response Buffers — ✅ RESOLVED
- **Resolution:** no pool — the handler appends into `out`, the connection's
  persistent, server-owned write buffer, reused for every request
  ([BEST_PRACTICES §1](docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)).
  epoll pools `ConnState` across connections (PR #50); io_uring reuses its
  buffers (PRs #62, #75); poll and IOCP keep a persistent `write_buf`; TLS
  buffers are pooled (PR #74); static responses are `const` strings appended
  with `core.append_str` (PR #240).
- **Related:** the GC scans grown write buffers
  ([#27](https://github.com/enghitalo/vanilla/issues/27)); ConnState pool
  high-water mark ([#166](https://github.com/enghitalo/vanilla/issues/166));
  h2c takeover state never freed under `-gc none`
  ([#269](https://github.com/enghitalo/vanilla/issues/269)); kqueue allocates
  per connection and per request (#154).

---

## 📚 Example Applications (PRIORITY)

### 33. Static File Server Example — ✅ RESOLVED
- **Resolution:** `examples/static_files/` (MIME types, ETag + 304, Range +
  206, path-traversal refusal on segment boundaries, `index.html` for `/`;
  `const` 404/405 responses appended with `core.append_str`), and the
  production module `static_assets/` (precomputed ETag/304, 206 with
  `If-Range`, SPA fallback, `sendfile` over kTLS) used by
  `examples/spa_static_assets/` and `examples/video_stream/`.
- **PRs:** #71, #73, #80, #81, #180, #181, #244.
- **Testing:** `examples/static_files/src/main_test.v`; 62 tests + a race
  test in `static_assets/`.
- **Remains:** `examples/static_files/` has no README; `Last-Modified` /
  `If-Modified-Since` is not sent anywhere (README roadmap).
- **Note:** [#14](https://github.com/enghitalo/vanilla/issues/14) ("support
  static file server") is done by this and can be closed.

### 34. HTTPS Example — ✅ RESOLVED
- **Resolution:** `examples/https/` (README) serves `GET`/`HEAD /` over TLS 1.3
  on `:8443`, built with `-d vanilla_tls`. On first run it issues a
  self-signed certificate for localhost, 127.0.0.1 and ::1 and persists it in
  `certs/`, so `curl --cacert certs/cert.pem` keeps working across restarts;
  `HTTPS_CERT` / `HTTPS_KEY` load a CA-issued PEM pair instead. The handler is
  plain HTTP (`http1_1/router`, const responses); `read_timeout_ms` bounds
  the handshake. Closes [#13](https://github.com/enghitalo/vanilla/issues/13).
- **Testing:** `src/main_test.v` (the handler, any build: the answers'
  bytes, no allocation, `load_tls` refusing half a pair) and
  `src/https_e2e_test.v` (`-d vanilla_tls`, run by
  `.github/workflows/tls_backend.yml`): a client that verifies the
  certificate against `cert.pem` as localhost and 127.0.0.1, keep-alive, a
  restart that keeps the identity, the `HTTPS_CERT`/`HTTPS_KEY` path, and a
  plaintext request closed at once with no HTTP answer.

### 35. Middleware Example — ✅ RESOLVED
- **Resolution:** `examples/middleware/` (handler chain, security-header
  decorator, buffered access log, bearer/role guards; README + tests), and one
  example per concern: `cors`, `rate_limit`, `compression`,
  `security_headers`, `auth` (argon2id, JWT, API key).
- **Remains:** no request-ID middleware;
  [#2](https://github.com/enghitalo/vanilla/issues/2) lists further ideas
  (maintenance mode, GeoIP, multitenancy, feature flags, locale).

### 36. Logging Example — ✅ RESOLVED ([#15](https://github.com/enghitalo/vanilla/issues/15))
- **Resolution:** `examples/logging/` writes one JSON line per request into a
  per-worker buffer (`core.append_str`, `wi`), with no syscall, no lock and no
  allocation (`test_logging_allocates_nothing`). The worker's timerfd
  (`on_worker_start`) drains the buffer between requests:
  - one `write(2)` of many lines through the worker's own `O_APPEND`
    descriptor;
  - rotation by size (worker 0 renames) and reopen on `SIGHUP` (the
    async-signal-safe handler bumps an atomic generation, and each worker
    reopens on its own thread);
  - NDJSON batches to a collector through a per-worker `http1_1.upstream`
    pool, with a bounded queue, retry with a backoff, and every dropped line
    counted (`/stats`).

  `SIGTERM` gets a final flush. The example has a README, in-process tests and
  e2e tests against a fake collector. `examples/observability/` has its
  README; `examples/middleware/src/access_log.v` stays as the minimal
  shared-`FILE*` version.

### 37. Security/Attack Protection Example — ✅ RESOLVED (as one example per concern)
- **Resolution:** request size limits, slowloris and connection caps in
  `examples/request_limits/` (`test_slowloris_reaped_by_read_timeout`); path
  traversal in `static_files`; protective headers in `security_headers`;
  per-IP rate limiting in `rate_limit` (spoofable key fixed in PR #211);
  `csrf`, `cors`, `ip_block`, `proxy_aware`, `cookies_sessions`; parameterized
  SQL with an injection regression test in `database` (#193, PR #211); input
  validation in `url_form` and `json_api`; header injection refused by
  `http1_1/client` and `http1_1/upstream`.
- Every one of these directories has a README (#46).

---

## 🧪 Testing & Validation

### 38. Request Parser Edge Case Tests — ✅ RESOLVED
- **Resolution:** `http1_1/request_parser/request_parser_test.v` (72 tests:
  malformed and short request lines, HTTP/0.9, empty method, 413/431 limits,
  CL+TE, chunked edge cases, overflow, bare LF, split-point fuzzing),
  `tests/framing_ambiguity_test.v`, `tests/chunked_trailer_test.v`, and the
  `conformance_h1spec.yml` / `conformance_http11probe.yml` CI gates.
- **PRs:** #64, #105, #110, #112, #204, #209, #214.

### 39. Backend Stress Tests — 🟡 PARTIAL
- **Done:** `tests/backend_behaviors_test.v` runs the same checks on epoll,
  io_uring, poll and IOCP (pipelining, split framing, `max_connections`,
  read/silent/idle timeouts, keep-alive under timeouts, large-upload drain,
  graceful shutdown); `tests/accept_starved_test.v` covers `EMFILE` at listen
  and accept (#256); `race_detector.yml` runs the epoll suites under `-race`.
- **Remains:** a sustained high-concurrency soak (1000+ clients) and many
  requests on one keep-alive connection; kqueue joins with
  [#154](https://github.com/enghitalo/vanilla/issues/154).

### 40. E2E Integration Tests — 🟡 PARTIAL
- **Done:** the `vtest/` scripted client ([docs/VTEST.md](docs/VTEST.md),
  PR #113), the `tests/` e2e suites (TLS, UDS, shutdown drain, pg_async), and
  every example's tests in CI: `build_test_examples_on_linux.yml` runs all 50
  examples, `build_test_examples_on_darwin.yml` the 28 that run on macOS.
  `async_watch_hangup`, `efficient_date`, `io_uring_demo` and `tiny` have
  tests ([#129](https://github.com/enghitalo/vanilla/issues/129)), and the
  `graceful_shutdown` and `request_limits` tests assert real behaviour on
  vtest ([#128](https://github.com/enghitalo/vanilla/issues/128)).
- **Remains:**
  - Consistency sweep of example tests: byte-exact asserts, shared helpers
    ([#130](https://github.com/enghitalo/vanilla/issues/130)).

### 41. Performance Benchmarks — ✅ RESOLVED
- **Resolution:** `bench/request_parser` (parse, header lookup, query,
  framing), `bench/router`, `bench/middleware`, `bench/client_codec`,
  `bench/static_assets_bench`, `bench/etag_hash`, `bench/pg_async`; the full
  cycle in `bench/e2e.c`, `micro.c`, `load.sh`, `wrk.sh`, `load_h2.sh`;
  `bench/measure.sh` for min-of-N runs; CI A/B in `bench.yml` /
  `ci_bench.sh`.
- **PRs:** #67, #68, #69, #243.

---

## 📖 Documentation

### 42. Complete API Documentation — ✅ RESOLVED (`tls/`, `server/`, `pg_async/`)
- **Resolution:** every `pub fn` / `struct` / `enum` / `const` / `type` in
  `tls/`, `server/` (with `server/backend_epoll` and `backend_poll`) and
  `pg_async/` has a doc comment that starts with its name, and so does every
  pub field. The comments give what the symbol returns and how it errors,
  plus allocation, threading and backend support where they matter:
  `Server.run` per backend, `Session.read_into` / `write_from` retry rules,
  and which `Config` setters are atomic. `v doc tls` renders the default build's stub
  (`tls_stub_notd_vanilla_tls.c.v`), so the stub carries the user-facing
  contract, followed by what it does without `-d vanilla_tls`.
- **Measured** with `scripts/doc_coverage.sh` (`-v` lists what is missing; a
  "loose" comment is one that does not start with the name), against origin/main
  d82b7bb:

  | module | before | after |
  |---|---|---|
  | `tls` | 29/67 (43%), 3 loose | 67/67 (100%) |
  | `server` | 9/20 (45%), 3 loose; fields 18/37 | 20/20 (100%); fields 37/37 |
  | `server/backend_epoll` | 5/7 (71%) | 7/7 (100%) |
  | `server/backend_poll` | 1/1 (100%) | 1/1 (100%) |
  | whole repo | 439/689 (64%); fields 135/281 | 490/689 (71%); fields 154/281 |
- **Found while documenting:**
  - [#287](https://github.com/enghitalo/vanilla/issues/287): `ServerConfig.certificates`
    is never read. The field is now documented as ignored, and
    `server/README.md` no longer says to set it.
  - [#297](https://github.com/enghitalo/vanilla/issues/297): `set_alpn`
    silently merges a 5th protocol into the 4th.
  - [#298](https://github.com/enghitalo/vanilla/issues/298): kqueue's `run()`
    returns silently when a kqueue cannot be created.
- **`pg_async/`** ([#360](https://github.com/enghitalo/vanilla/issues/360)):
  the same, checked against the code, its callers and its tests. `PgPool`
  says which backends run its reactor path (the epoll worker and io_uring;
  `start_maintenance`, park deadlines and `PgConn.cancel` the epoll worker
  only), `Result` what its views borrow and for how long, `release()` that it
  is for `acquire()` alone, and `ConnConfig.host` that a re-dial resolves the
  name on the worker (since [#351](https://github.com/enghitalo/vanilla/issues/351),
  only for a pool that follows no `transport.Resolver`). Measured against
  origin/main 86688fa:

  | module | before | after |
  |---|---|---|
  | `pg_async` | 124/189 (66%), 4 loose; fields 23/48 | 189/189 (100%); fields 48/48 |
  | whole repo | 508/707 (72%); fields 155/285 | 573/707 (81%); fields 180/285 |
- **Kept there by CI:** on every pull request, `architecture.yml` runs
  `scripts/doc_coverage_gate.sh` against the base. It fails when a module at
  100% there (every declaration documented, as `doc_coverage.sh` counts) drops
  below it, or leaves a pub field undocumented when all of them had a comment.
- **Next modules** (same style, outside this item), by undocumented
  declarations: `io_uring` (32), `http2` (23), `websocket` (14), `socket`
  (12) and `kqueue` (11); then `http1_1/response` (9) and `epoll` (7). The
  style follows the parser's:
  ```v
  // frame_request_length_lim_idx returns the length of the first complete
  // request in buf, -1 if it is incomplete, or -400 / -413 / -431 when it must
  // be refused. No allocation; the `!` twin is frame_request_length_lim.
  ```

### 43. Architecture Documentation — ✅ RESOLVED
- **Resolution:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (module tree,
  each module's role, the grep-enforced dependency rule), [server/README.md](server/README.md)
  (backends, accept models, workers, limits, TLS threading), and the memory
  model in [BEST_PRACTICES §1-4](docs/BEST_PRACTICES.md) and
  [V_PERF_TOOLBOX](docs/V_PERF_TOOLBOX.md).
- **Optional:** diagrams.

### 44. Security Best Practices Guide — 🟡 PARTIAL
- **Done:** [BEST_PRACTICES §8](docs/BEST_PRACTICES.md#8-security-defaults)
  lists the defaults and points at the `auth`, `cors`, `csrf`, `rate_limit`,
  `request_limits` and `security_headers` examples; TLS configuration is in
  `server/README.md`.
- **Remains:** a dedicated `SECURITY.md`: threat list, timing-safe compares,
  header and body limits, TLS hardening, rate limiting behind proxies, and how
  to report a vulnerability.

### 45. Performance Tuning Guide — ✅ RESOLVED
- **Resolution:** [docs/PERF_TUNING.md](docs/PERF_TUNING.md), the operator's
  page: build flags (`-prod`, `-gc none`, `GC_MARKERS`, `-cc`), the worker
  count (`VANILLA_WORKERS`, `taskset`, containers, `VANILLA_PIN_CPUS`),
  choosing epoll or io_uring, `ulimit -n` and `max_connections`, the listen
  backlog against `net.core.somaxconn` and the SYN sysctls, per-connection
  buffer sizing, io_uring host requirements (kernel, `ulimit -l`, seccomp,
  `VANILLA_NO_IOURING`), kTLS, NUMA and interrupts, and how to measure. Each
  knob is checked against the code, and the measured numbers come from runs
  cited on the page. Linked from `README.md` and `server/README.md`.
  Code-level advice stays in [V_PERF_TOOLBOX](docs/V_PERF_TOOLBOX.md),
  [PERF_GAP_ANALYSIS](docs/PERF_GAP_ANALYSIS.md),
  [BEST_PRACTICES §10](docs/BEST_PRACTICES.md#10-benchmark-before-and-after-every-perf-change)
  and [LOCAL_IPC](docs/LOCAL_IPC.md).
- **Found while verifying:** [#290](https://github.com/enghitalo/vanilla/issues/290)
  (`VANILLA_PIN_CPUS` pins to absolute CPU numbers and escapes a `taskset`
  mask), [#296](https://github.com/enghitalo/vanilla/issues/296) (the epoll
  pool keeps grown per-connection buffers for good; io_uring frees them).

### 46. Example Walkthroughs — ✅ RESOLVED
- **Resolution:** every example directory has a README, on one template
  (see `examples/tiny/README.md`): what the example shows and why, the run
  command, every endpoint with a curl call and the real response it got, the
  design points as they appear in the code, the test command and links into
  [BEST_PRACTICES](docs/BEST_PRACTICES.md). Each command was run against the
  built server, and the PostgreSQL ones against a throwaway `postgres:16`.
  Bugs found while writing them: #292, #293, #294.
  The READMEs of the 24 examples #279 rewrote were then re-verified on their
  own against the new code: every command re-run and every response diffed,
  every name and allocation claim checked against the source and tests. 17
  needed fixes, among them `ip_block`'s edit to see the 403 (`block` now
  returns a Result) and `async_db_pg`'s Docker setup (wait for
  `pg_isready`).

---

## 📊 Priority Matrix

Open and partial items only.

| Priority | Count | Items |
|----------|-------|-------|
| 🔴 HIGH | 0 | — |
| 🟡 MEDIUM | 7 | #4, #16, #19, #23, #39, #40, #44 |
| 🟢 LOW | 0 | — |

---

## 🎯 Implementation Roadmap

### Phase 1: Foundation
- [x] #2 - Dynamic routing
- [x] #5 - Query string parsing
- [x] #8 - Header injection

### Phase 2: TLS/HTTPS
- [x] #15 - TLS bindings
- [ ] #16 - TLS on io_uring, kqueue and IOCP, h2 over TLS (#156 and async over TLS done)
- [x] #17 - Self-signed certificates
- [x] #34 - HTTPS example

### Phase 3: Core Examples
- [x] #33 - Static file server
- [x] #35 - Middleware example
- [x] #36 - Logging example (rotation, JSON, shipping)
- [x] #37 - Security examples

### Phase 4: Protocol & Backend
- [x] #10 - Host header validation
- [x] #11 - Case-insensitive headers
- [x] #18 - Epoll keep-alive
- [x] #20 - IOCP keep-alive
- [ ] #4, #19, #21, #23 - kqueue parity (#154)
- [ ] #23 - Push outbound queue and close-path gaps (#23, #270, #271, #272, #275)

### Phase 5: Quality & Testing
- [x] #25 - Bounds checking
- [x] #27 - Magic numbers
- [x] #28 - Dead code
- [x] #29 - Response buffers
- [x] #38 - Parser tests
- [ ] #39 - Soak test
- [ ] #40 - Consistent example tests (#130)
- [x] #41 - Benchmarks

### Phase 6: Documentation
- [x] #42 - API docs (`tls/`, `server/`, `pg_async/`)
- [x] #43 - Architecture doc
- [ ] #44 - SECURITY.md
- [x] #45 - Performance tuning page
- [x] #46 - Example READMEs

---

## 📈 Progress Tracking

### Resolved: 26/33 (79%)
#2, #3, #5, #8, #10, #11, #15, #17, #18, #20, #21 (except kqueue), #25, #27,
#28, #29, #33, #34, #35, #36, #37, #38, #41, #42, #43, #45, #46

### Partial: 6/33 (18%)
#16, #19, #23, #39, #40, #44

### Open: 1/33 (3%)
#4

---

## 🔗 Dependencies Graph

```
kqueue parity (#154):
  #4 (write backpressure) + #19 (read buffer / pipelining) + #21 (timeouts, max_connections)
    → kqueue joins tests/backend_behaviors_test.v (#39, #40)

TLS:
  #156 (reject tls_config where TLS isn't served, done) → #16 on more backends (#115, #142)

Server push / close paths:
  #23 (outbound queue) ← #270, #271, #272, #275
```

---

## 💡 Quick Wins (< 1 hour each)

None left: every open item is a multi-hour change.

---

## 🎓 Learning Opportunities

For contributors wanting to learn:

- **Intermediate:** #40
- **Advanced:** #4/#19 (kqueue, #154), #16, #23

---

## 🤝 Contributing

To work on an item:

1. Check dependencies are complete
2. Read the strategy section and [docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md)
3. Implement with tests
4. Update this checklist
5. Submit PR

---

## 📞 Support

For questions about implementation strategies:
- Open an issue on GitHub
- Reference the item number (#N)
- Include your proposed approach

---

**Last Updated:** 2026-10-11
**Maintainer:** @enghitalo
**Version:** 0.0.1
