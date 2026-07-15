# vtest — event-driven e2e testing for vanilla

Design document. Read this before touching `vtest/` or the e2e tests built on it.
Everything here was validated by spikes against the real server before the module
was written (128-conn pipelined storm: 1024 responses, one `poll(-1)` loop, 3 poll
iterations; 64-conn slowloris storm: all reaped by the server's own
`read_timeout_ms` with zero client-side timeouts).

## Goals (the contract)

1. **Concurrent by default.** A test fires N connections at once — heterogeneous
   traffic (well-behaved, pipelined, stalled, malformed) hitting all workers
   simultaneously, like production. The current one-connection-at-a-time tests
   cannot exercise SO_REUSEPORT sharding or cross-worker behavior; vtest can.
2. **No test-side clocks.** There is no timeout anywhere in a vtest test. The only
   clock in the program is the server's own config (`Limits.read_timeout_ms`,
   `write_timeout_ms`, shutdown grace). A stalled-client test *completes* because
   the server's reaper closes the connection — the test exercises the timeout
   machinery instead of duplicating it. If the server loses liveness entirely, the
   test hangs: that is the correct signal (CI step timeout is the backstop).
3. **Starts when the server is ready, ends when everything answered.** The test
   author never sees readiness: `drive()`/`start()` own the lifecycle and fire the
   client reactor from `after_server_start`. A run terminates exactly when every
   connection reached its terminal state (expectation met, or EOF from the server).
   Deterministic completion, not deadline expiry.
4. **The guts, mirrored.** The client is built from the same idioms as the server:
   non-blocking fds, one readiness loop, accumulated buffers, framing as a pure
   predicate over bytes, self-pipe wakeups. Reading vtest teaches you the server.
   Results expose server internals (post-drain `inflight`/`active_conns` counters)
   so every test asserts leak-freedom for free.

## API surface (all of it)

```v
// A Script is one connection's life, as data. No behavior hides in it.
pub struct Script {
pub:
	rounds   []Round // sequenced: round k+1 sends only after round k's expectation met
	then_eof bool    // after the last round, require the SERVER to close (EOF)
	shut_wr  bool    // half-close (SHUT_WR) after the final send — RFC 9112 §9.6 tests
}

pub struct Round {
pub:
	send  []u8
	want  int = 1                       // sugar: `until: frames(want)`
	until fn (acc []u8) bool = unsafe { nil } // general form: pure predicate over accumulated bytes
}

pub struct ConnResult {
pub mut:
	frames      [][]u8 // complete Content-Length-framed responses, in arrival order
	raw         []u8   // everything received (SSE/chunked asserts read this)
	eof         bool   // server closed the connection
	unmet       bool   // reached EOF before the script's expectations were satisfied
	connect_err string
}

pub struct Outcome {
pub:
	conns          []ConnResult // SAME order as the scripts passed in: position = identity
	inflight_after i64          // server counters sampled after shutdown drain —
	active_after   i64          // assert == 0 to prove nothing leaked
}

// One-shot: new_server(port:0) → spawn run() → reactor at readiness → all scripts
// terminal → shutdown(grace) → Outcome.
pub fn drive(config http_server.ServerConfig, scripts []Script) !Outcome

// Session form, for cross-connection choreography (SSE, shutdown-while-in-flight):
pub fn start(config http_server.ServerConfig) !&Harness
pub fn (mut h Harness) fire(scripts []Script) !Outcome   // returns when THESE scripts' last round completed; conns stay open in the reactor
pub fn (mut h Harness) wait(group GroupId, until fn (acc []u8) bool) !Outcome // block until predicate holds on every conn of the group (or EOF)
pub fn (mut h Harness) stop()                             // close client fds, shutdown server, join reactor

// Predicates (pure fns over accumulated bytes — the client-side mirror of the
// server's pure handler):
pub fn frames(n int) fn (acc []u8) bool      // n complete CL-framed responses
pub fn headers_seen(acc []u8) bool           // first \r\n\r\n arrived (SSE head, 100-continue…)
pub fn count(needle string, n int) fn (acc []u8) bool

pub fn repeat(n int, s Script) []Script
```

### Semantics and guarantees

- **Ordering:** `Outcome.conns[i]` is the result of `scripts[i]`. Within one
  connection, `frames[j]` answers the j-th request (RFC 9112 response ordering).
  Across connections there is no global order — assert per index or in aggregate.
- **Terminal states per connection:** expectation of the final round met (client
  closes, `eof=false`), or `then_eof` satisfied by server close, or premature EOF
  (recorded as `unmet=true` + whatever arrived — the test's asserts catch it).
  Refused/reset connects land in `connect_err`.
- **Rounds** sequence *within* a connection with no barrier across connections.
  `fire()` sequences *groups* of connections: an ordering step for choreography
  (subscribe-all → publish → expect events) with completion, never sleeps.
- **No client timeouts, ever.** The reactor blocks in `poll(fds, -1)`. Progress
  comes from the server (bytes or close). See goal 2 for the hang contract.

## Reactor mechanics (one file, ~300 lines, read it once)

- One thread, started by `start()`/`drive()`, woken from `after_server_start` so
  the first connect happens at the readiness instant (listeners are bound+listening
  even earlier — `new_server` is synchronous — so the backlog would absorb earlier
  connects anyway; the hook is the honest signal).
- Per connection: blocking `connect()` on loopback (instant), then `O_NONBLOCK`
  for all I/O. State: bytes sent (partial-send loop), accumulated `acc []u8`
  (noscan, sized 8 KiB, grows), current round index, terminal flag.
- Loop: build pollfd set of live conns (`POLLIN`, plus `POLLOUT` while the current
  round's send is unfinished) + the self-pipe (`fire`/`wait`/`stop` wake the loop
  the same way the server's own reactor is woken from outside) → `poll(-1)` →
  drain readable fds into `acc` → run the current round's predicate → advance
  round / mark terminal → notify the test thread over a channel when a group
  completes.
- `EAGAIN` ends a read burst; `recv == 0` is EOF (terminal); `POLLERR`/reset is
  recorded, never fatal to the run.
- Frame counting = the Content-Length predicate `testkit` uses today, generalized
  to N and kept as a pure `fn (acc []u8) bool`.
- Windows: `WSAPoll` behind `$if windows` (same struct; POLLERR-on-connect quirk
  fixed in Win10 2004+, current runners fine). Winsock init comes free via the
  socket module.

## The enabler: `port: 0` = kernel-assigned ephemeral port

`drive()` defaults to `port: 0` so parallel test binaries never coordinate ports
(the old hand-maintained registry 8121–8162/18181–18184 dies).

Server-side change in `new_server` (cold path only):

- After the first listener is created (`socket.create_server_socket`), if
  `config.port == 0`, resolve the real port via `socket.local_port(socket_fd)`
  (new helper: `getsockname` + `ntohs`, the exact `peer_addr` call shape; ws2_32
  exports both with identical signatures, so one body serves all platforms).
- Use the resolved port for the io_uring per-worker listener loop — **this fixes a
  latent bug**: previously `port: 0` + io_uring bound n_workers *different*
  ephemeral ports, silently destroying the SO_REUSEPORT group.
- Store the resolved port in `Server.port` (immutable `pub`, so resolution must
  precede struct construction). Banners and `after_server_start` consumers then
  see the real port everywhere.
- Measured non-risks: 60k ephemeral binds against a held REUSEPORT listener → 0
  collisions (the kernel skips busy ports); cross-UID joiners get EADDRINUSE;
  listening sockets never enter TIME_WAIT.

## Where things live (module cycles decide this)

- `vtest/` is a **top-level module** (`import vtest`). It imports `http_server`,
  so it can never be imported from files compiled *as part of* module
  `http_server` — including that module's own `_test.v` files.
- Therefore socket e2e tests for the server live in **`tests/`** (repo root),
  standalone `_test.v` files importing `http_server` + `vtest`. They only ever
  used public API; they never needed module-internal access.
- Example tests are `module main` and import `vtest` directly, in place.
- `http_server/testkit` (deadline-bounded readers) stays for the hand-rolled
  escape-hatch tests; vtest does not import it.

## What stays hand-rolled (deliberately)

- The `after_server_start` contract test (it tests the hook itself).
- Graceful-shutdown drain (calls `server.shutdown()` mid-flight — lifecycle owned
  by the test; `start()`'s Harness exposes the underlying `&Server` for this).
- Unit-style tests (parser, reactor invariants, date cache) — untouched.

## Rules that keep tests correct (verified against V 0.5.2 codegen)

1. A failed `assert` longjmps and runs only *same-frame* defers — keep every
   assert of a scenario in the fn that owns any `defer`; helpers return values.
2. `fn [mut x]` closures **copy** the struct (memdup); only reference fields
   (`&core.Counter`) are shared across copies. Never rely on closure-side struct
   mutation being visible outside.
3. io_uring allows one live ring per process: within one test binary, a test must
   fully `stop()`/shutdown its io_uring server before the next starts (the
   sequential-tests-per-file pattern already guarantees this).

## Migration plan (each step = one commit, `v test .` green)

1. `docs/VTEST.md` (this file).
2. `socket.local_port()` + port-0 resolve in `new_server` (+ io_uring port-0 fix),
   with a test.
3. `vtest/` module: reactor + predicates + `drive`/`start`/`fire`/`wait`/`stop` +
   its own smoke tests in `tests/`.
4. Prova de fogo: migrate `http_server/backend_behaviors_test.v` →
   `tests/backend_behaviors_test.v` on vtest (all 19 checks, same coverage,
   storms where they add value).
5. Migrate `server_test.v` (keep hook-contract test hand-rolled),
   `io_uring_backend_test.v`, `io_uring_queue_buf_test.v`.
6. Migrate example e2e tests (simple, simple3, async_pipe); delete every Harness
   copy and the port registry.
7. New capability tests: SSE fan-out (subscribe-all → publish → all receive,
   via `start`/`fire`/`wait`), mixed-traffic storm.

## Honest costs

- The reactor is new code (~300 lines) that itself must be trusted — mitigated by
  it being one file, spike-derived, and exercised by every e2e test in the tree.
- Declarative `Script`s are data, but they are one more concept; the escape hatch
  for anything they cannot express is "write the sockets by hand with testkit",
  which remains supported.
- Tests that would hang on a liveness bug hang instead of failing fast — accepted
  and intended (goal 2); CI step timeouts bound the damage.
