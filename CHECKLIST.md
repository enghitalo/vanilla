# Vanilla HTTP Server - Improvement Checklist

> Comprehensive roadmap of improvements, features, and implementations
>
> **Last Updated:** 2026-10-10
> **Project:** Vanilla HTTP Server v0.0.1

Each item carries a status in its heading:

- **✅ RESOLVED** — done; the entry says where it lives and what tests it.
- **🟡 PARTIAL** — mostly done; the entry lists only what remains.
- **🔴 OPEN** — not done yet.
- **⚪ OBSOLETE** — the premise no longer applies (the code or the design moved
  on); the entry says what replaced it.

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

### 1. Undefined Function `vmemcmp` — ⚪ OBSOLETE
- **Premise:** `vmemcmp` was never undefined: it is a V builtin
  (`vlib/builtin/cfns_wrapper.c.v`), still used in `server/backend_poll`,
  `server/backend_epoll` and `pg_async`.
- **Today:** `http1_1/request_parser/request_parser.v` no longer calls it;
  header lookup (`get_header_value_slice`) compares with `ascii_ci_eq`, and the
  other byte compares use `C.memcmp`.

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

### 5. Query String Parsing — 🟡 PARTIAL
- **Done:** `HttpRequest.get_query_slice(key []u8) ?Slice`
  (`http1_1/request_parser/request_parser.v`) returns a zero-copy `Slice` into
  the request buffer, with no `error()` on the not-found path
  (`find_byte_idx`). `get_query(key string)` is kept as a deprecated wrapper.
  Values are raw; `examples/url_form/` percent-decodes them once at the edge.
- **Testing:** `request_parser_test.v` (single, multiple, last, missing key,
  no query, `?empty=`, special characters).
- **Remains:**
  - A flag-only key (`?novalue`) is indistinguishable from a missing one; no
    presence check (`has_query`).
  - An empty `key` reaches `&key[0]` on an empty array: guard `key.len == 0`
    and return `none`.
  - No percent-decoding helper in the library (an `_into(mut out []u8)` form,
    so decoding allocates nothing).
- **Priority:** 🟢 LOW

### 6. Add Standard HTTP Status Codes — ⚪ OBSOLETE
- **Premise:** a library table of status-line consts
  (`'HTTP/1.1 200 OK\r\n'`) only makes sense if handlers concatenate the rest
  of the response. They don't: [BEST_PRACTICES §3a](docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)
  has each app write its complete responses (status line + headers + body) as
  `const` strings appended with `core.append_str`, and dynamic ones appended
  part by part (§3b).
- **Today:** `http1_1/response/response.c.v` holds the server's own complete
  responses (100, 400, 408, 413, 431, 444); `http1_1/veb_like` has its 404,
  405 and 501.

### 8. Header Injection Utility — ✅ RESOLVED (in the examples)
- **Resolution:** header injection is a wrapper around the handler that
  splices into `out` in place, not a library function returning a new array
  (that would be one allocation and a copy per response, against
  [BEST_PRACTICES §1/§4](docs/BEST_PRACTICES.md)).
  `examples/security_headers/src/main.v` `insert_after_status_line(mut out, start, headers)`
  inserts a `const` header block after the status line with `vmemmove` /
  `vmemcpy`, allocation-free once `out` has reached its high-water mark.
- **Testing:** `examples/security_headers/src/main_test.v`,
  `examples/middleware/src/main_test.v`.
- **Remains:** `examples/middleware/src/decorators.v` `inject_headers(resp, headers) []u8`
  still builds a new array per response (and its README recommends it):
  switch it to the in-place splice.

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
  https") is still open although HTTPS works on epoll; it can be closed or
  narrowed to the example (#34).

### 16. Integrate TLS into the Server — 🟡 PARTIAL
- **Done:** TLS lives in the backend worker, not in the request/response
  codecs: `server/backend_epoll/tls_conn_linux.c.v` (handshake, record I/O,
  pipelining, `sendfile` over kTLS, deadline sweep), enabled with
  `ServerConfig.tls_config`. PRs #96, #158, #159, #160, #181, #182.
- **Testing:** `tests/tls_pipelining_test.v`, `tls_static_test.v`,
  `tls_timeouts_test.v`, `tls_workers_test.v` (`.github/workflows/tls_backend.yml`).
- **Remains:**
  - io_uring and kqueue accept `tls_config` and serve **plaintext**:
    `new_server` must reject it ([#156](https://github.com/enghitalo/vanilla/issues/156), security).
  - TLS on IOCP ([#115](https://github.com/enghitalo/vanilla/issues/115)),
    HTTP/2 over TLS + ALPN ([#142](https://github.com/enghitalo/vanilla/issues/142)),
    kTLS + `sendfile` for every static path ([#76](https://github.com/enghitalo/vanilla/issues/76)).
  - A TLS `.close` is one best-effort write ([#275](https://github.com/enghitalo/vanilla/issues/275)).
  - `on_worker_start` and server push are not available with TLS.

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
  `watch_fd_deadline` (PR #249, #200; epoll plain worker only).
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
  `sm_max_pending_write`), io_uring (partial-send remainder + write deadline),
  poll (`write_off` + `POLLOUT`) and IOCP keep the unsent bytes and resume when
  the socket is writable — never a busy retry on `EAGAIN`. Partial reads are
  framed by `request_parser.frame_request_length_lim_idx` on every backend but
  kqueue.
- **Remains:**
  - kqueue: `response.send_response` fails on `EAGAIN` and the connection is
    closed (#4, [#154](https://github.com/enghitalo/vanilla/issues/154)).
  - Server push: a per-connection outbound queue
    ([#23](https://github.com/enghitalo/vanilla/issues/23)); `examples/sse`
    still drops a client on a short `C.send`.
  - Close paths: the untransmitted tail is lost when the client keeps sending
    after `close()` ([#272](https://github.com/enghitalo/vanilla/issues/272));
    gaps after #268 ([#275](https://github.com/enghitalo/vanilla/issues/275));
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

### 26. Consistent Error Handling — ⚪ OBSOLETE
- **Premise:** "always `!`" would put an allocation on every hot-path failure.
- **Today:** a deliberate two-style convention
  ([BEST_PRACTICES §4](docs/BEST_PRACTICES.md#4-allocate-on-the-hot-path-with-intent),
  [V_PERF_TOOLBOX](docs/V_PERF_TOOLBOX.md#v-allocation-gotchas-filed-upstream--all-fixed)):
  hot paths return int sentinels (`frame_request_length_lim_idx` → -1 / -400 /
  -413 / -431, `find_byte_idx`), with a `!` wrapper (`frame_request_length_lim`,
  `error_with_code`) for callers off the hot path; `error()` with context
  elsewhere. Tested by `test_frame_idx_error_sentinels` and
  `test_frame_wrapper_codes_match_idx`.

### 27. Replace Magic Numbers with Constants — 🟡 PARTIAL
- **Done:** the tunables are `core.Limits` fields; each backend names its own
  sizes (`sm_*`, `read_buf_cap`, `write_buf_cap` in `server/backend_epoll`,
  `iou_*` in io_uring, `pl_*` in poll, `win_*` in IOCP, `tls_*`).
- **Remains:**
  - The 8 MiB request cap and 8 MiB pending-write cap are separate consts in
    five places; one shared `core` const each would keep them in step.
  - Unnamed literals in `server/async_darwin.c.v` (`[1024]C.kevent`,
    `cap: 4096`) — they go with #154 — and `cap: 4096` in
    `server/backend_epoll/tls_conn_linux.c.v`.
- **Priority:** 🟢 LOW

### 28. Remove Dead Code — ✅ RESOLVED
- **Resolution:** `examples/veb_like/main.v` and its commented-out blocks were
  replaced in PR #238; the remaining commented code in the tree is usage
  examples inside doc comments.
- **Leftover** (`v -check` reports the unused ones):
  - commented-out `C.in_addr` / `C.sockaddr_in` declarations in
    `socket/socket_windows.c.v`;
  - unused `find_byte`, `bytes_equal` and `slash_u8` in
    `http1_1/request_parser/request_parser.v`, and `pool_has_capacity` in
    `io_uring/io_uring_linux.c.v`.

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

### 32. Response Caching — ⚪ OBSOLETE (as designed)
- **Premise:** a process-wide `map` behind a `sync.Mutex` on the hot path goes
  against [BEST_PRACTICES §6](docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)
  (shared-nothing, lock-free workers).
- **Covered by:** `const` complete responses (§3a); `static_assets/` (a
  build-once, lock-free asset server with precomputed responses, ETag, 304 and
  206, bodies optionally in RAM, snapshots published atomically with
  `follow_disk`; PRs #73, #80, #81, #180); `examples/etag/` (dynamic
  `If-None-Match` → 304); the cached `Date` line (`examples/date_header`,
  `examples/efficient_date`).
- **If a TTL cache for dynamic responses is ever needed:** keep it per worker
  (built in `make_state`, reached through `worker_state`), so lookups take no
  lock. The cache example request is
  [#3](https://github.com/enghitalo/vanilla/issues/3).

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

### 34. HTTPS Example — 🔴 OPEN ([#13](https://github.com/enghitalo/vanilla/issues/13))
- **Issue:** the HTTPS server works on epoll (#15, #16) but no example serves
  TLS: it is shown only in `server/README.md` and the `tests/tls_*` suites.
  `examples/https_upstream/` is the client side.
- **Priority:** 🔴 HIGH
- **Effort:** 1-2 hours
- **Strategy:** `examples/https/src/main.v`, built with `-d vanilla_tls`:
  ```v
  module main

  import core
  import server
  import tls

  const resp_200 = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, HTTPS!'

  fn handle(_req []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
  	core.append_str(mut out, resp_200)
  	return .done
  }

  fn main() {
  	// localhost/127.0.0.1/::1 SANs; persist_dir keeps the identity across
  	// restarts, so `curl --cacert certs/cert.pem` keeps working
  	cfg := tls.new_self_signed(persist_dir: './certs')!
  	mut srv := server.new_server(server.ServerConfig{
  		port:            8443
  		handler:         handle
  		io_multiplexing: .epoll // the only backend that serves TLS (#156)
  		tls_config:      cfg
  		limits:          server.Limits{
  			read_timeout_ms: 10_000 // bounds the handshake and slowloris
  		}
  	})!
  	srv.run()
  }
  ```
- **Testing:** `curl --cacert certs/cert.pem https://localhost:8443/`, plus a
  `main_test.v` run by `.github/workflows/tls_backend.yml`.

### 35. Middleware Example — ✅ RESOLVED
- **Resolution:** `examples/middleware/` (handler chain, security-header
  decorator, buffered access log, bearer/role guards; README + tests), and one
  example per concern: `cors`, `rate_limit`, `compression`,
  `security_headers`, `auth` (argon2id, JWT, API key).
- **Remains:** no request-ID middleware;
  [#2](https://github.com/enghitalo/vanilla/issues/2) lists further ideas
  (maintenance mode, GeoIP, multitenancy, feature flags, locale).

### 36. Logging Example — 🟡 PARTIAL ([#15](https://github.com/enghitalo/vanilla/issues/15))
- **Done:** `examples/middleware/src/access_log.v` (a buffered, zero-alloc
  access log written to a file, flushed on shutdown) and
  `examples/observability/` (one `key=value` line per request, `/healthz`,
  `/readyz`, `/metrics`).
- **Remains:** log rotation (reopen on `SIGHUP` or by size), a JSON line
  format, shipping to an external collector (off the worker, through
  `http1_1.upstream`), and a README for `examples/observability/`. Keep
  [BEST_PRACTICES §5](docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path):
  each line is appended into a per-worker buffer (`core.append_str`,
  `strconv.write_dec`), never written synchronously per request.

### 37. Security/Attack Protection Example — ✅ RESOLVED (as one example per concern)
- **Resolution:** request size limits, slowloris and connection caps in
  `examples/request_limits/` (`test_slowloris_reaped_by_read_timeout`); path
  traversal in `static_files`; protective headers in `security_headers`;
  per-IP rate limiting in `rate_limit` (spoofable key fixed in PR #211);
  `csrf`, `cors`, `ip_block`, `proxy_aware`, `cookies_sessions`; parameterized
  SQL with an injection regression test in `database` (#193, PR #211); input
  validation in `url_form` and `json_api`; header injection refused by
  `http1_1/client` and `http1_1/upstream`.
- **Remains:** none of these directories has a README (#46).

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
  `build_test_examples_on_linux.yml` running 33 examples' tests.
- **Remains:**
  - Examples with tests that no workflow runs: `cookies_sessions`, `csrf`,
    `date_header`, `ip_block`, `observability`, `proxy_aware`, `redirects`,
    `security_headers`, `simple3`, `spa_static_assets`, `url_form`,
    `video_stream`.
  - Examples with no test: `async_watch_hangup`, `efficient_date`,
    `io_uring_demo`, `tiny` ([#129](https://github.com/enghitalo/vanilla/issues/129)).
  - Consistency sweep of example tests: byte-exact asserts, shared helpers
    ([#130](https://github.com/enghitalo/vanilla/issues/130)).
  - [#128](https://github.com/enghitalo/vanilla/issues/128) (graceful_shutdown
    and request_limits stub tests) looks done: both now assert real behaviour.

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

### 42. Complete API Documentation — 🟡 PARTIAL
- **Done:** about 85% of library `pub fn`s carry a doc comment; most modules
  are at 93-100%.
- **Remains:** `tls/` (~44%) and `server/` (~61%), then `socket/` and
  `pg_async/`. Same style as the parser:
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

### 45. Performance Tuning Guide — 🟡 PARTIAL
- **Done:** [V_PERF_TOOLBOX](docs/V_PERF_TOOLBOX.md) (GC modes, profiling),
  [PERF_GAP_ANALYSIS](docs/PERF_GAP_ANALYSIS.md),
  [BEST_PRACTICES §10](docs/BEST_PRACTICES.md#10-benchmark-before-and-after-every-perf-change)
  (benchmark methodology), [LOCAL_IPC](docs/LOCAL_IPC.md), `server/README.md`
  (workers, `ulimit -n`).
- **Remains:** one operational page: `taskset` + `VANILLA_WORKERS`,
  `ulimit -n`, `net.core.somaxconn` and other sysctls, buffer sizing.

### 46. Example Walkthroughs — 🔴 OPEN
- **Issue:** 12 of 50 example directories have a README (`conformance`,
  `etag`, `hexagonal`, `https_upstream`, `json_api`, `mesh`, `middleware`,
  `router`, `spa_static_assets`, `sse`, `veb_like`, `video_stream`).
- **Priority:** 🟡 MEDIUM
- **Strategy:** most of the other 38 open `main.v` with a long explanatory
  comment that can seed the README; start with the security examples (#37),
  `static_files`, `observability` and `request_limits`.

---

## 📊 Priority Matrix

Open and partial items only.

| Priority | Count | Items |
|----------|-------|-------|
| 🔴 HIGH | 2 | #16 (#156: plaintext on io_uring/kqueue), #34 |
| 🟡 MEDIUM | 9 | #4, #19, #23, #36, #39, #40, #42, #44, #46 |
| 🟢 LOW | 3 | #5, #27, #45 |

---

## 🎯 Implementation Roadmap

### Phase 1: Foundation
- [x] #1 - vmemcmp (obsolete)
- [x] #2 - Dynamic routing
- [ ] #5 - Query string parsing (flag keys, empty-key guard, percent-decode helper)
- [x] #6 - HTTP status codes (obsolete)
- [x] #8 - Header injection

### Phase 2: TLS/HTTPS
- [x] #15 - TLS bindings
- [ ] #16 - TLS on every backend (#156 first)
- [x] #17 - Self-signed certificates
- [ ] #34 - HTTPS example

### Phase 3: Core Examples
- [x] #33 - Static file server
- [x] #35 - Middleware example
- [ ] #36 - Logging example (rotation, JSON, shipping)
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
- [x] #26 - Error handling (obsolete)
- [ ] #27 - Magic numbers
- [x] #28 - Dead code
- [x] #29 - Response buffers
- [x] #32 - Response caching (obsolete)
- [x] #38 - Parser tests
- [ ] #39 - Soak test
- [ ] #40 - Every example's tests in CI
- [x] #41 - Benchmarks

### Phase 6: Documentation
- [ ] #42 - API docs (`tls/`, `server/`)
- [x] #43 - Architecture doc
- [ ] #44 - SECURITY.md
- [ ] #45 - Performance tuning page
- [ ] #46 - Example READMEs

---

## 📈 Progress Tracking

### Resolved: 23/37 (62%)
- ✅ 19 done: #2, #3, #8, #10, #11, #15, #17, #18, #20, #21 (except kqueue),
  #25, #28, #29, #33, #35, #37, #38, #41, #43
- ⚪ 4 obsolete: #1, #6, #26, #32

### Partial: 11/37 (30%)
#5, #16, #19, #23, #27, #36, #39, #40, #42, #44, #45

### Open: 3/37 (8%)
#4, #34, #46

---

## 🔗 Dependencies Graph

```
kqueue parity (#154):
  #4 (write backpressure) + #19 (read buffer / pipelining) + #21 (timeouts, max_connections)
    → kqueue joins tests/backend_behaviors_test.v (#39, #40)

TLS:
  #156 (reject tls_config where TLS isn't served) → #16 on more backends (#115, #142)
  #34 (HTTPS example) → independent, epoll only

Server push / close paths:
  #23 (outbound queue) ← #270, #271, #272, #275

Docs:
  #46 (example READMEs) ← #37's examples first
```

---

## 💡 Quick Wins (< 1 hour each)

1. #5 - Guard an empty `key` in `get_query_slice` (10 min)
2. #28 - Drop the leftover dead code listed in #28 (15 min)
3. #34 - HTTPS example from the sketch above (1 hour)
4. #40 - Add the 12 tested-but-unrun examples to `build_test_examples_on_linux.yml` (30 min)
5. #8 - In-place splice in `examples/middleware` `inject_headers` (30 min)

**Total Quick Wins:** ~2.5 hours for 5 improvements

---

## 🎓 Learning Opportunities

For contributors wanting to learn:

- **Beginner:** #5, #28, #46
- **Intermediate:** #34, #36, #40, #42
- **Advanced:** #4/#19 (kqueue, #154), #16 (#156), #23

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

**Last Updated:** 2026-10-10
**Maintainer:** @enghitalo
**Version:** 0.0.1
