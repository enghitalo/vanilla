module core

import runtime
import os

// Shared, dependency-free types used by both the public `http_server` facade and
// the backend implementations (e.g. `backend_epoll`). Keeping them in a leaf
// module breaks what would otherwise be a cycle: `http_server` imports a backend
// to run it, and the backend needs these types — so neither can own them.

// One worker thread per USABLE core (thread-per-core model). Both the facade
// (thread / counter array sizing) and the backend (worker fan-out) need this.
pub const max_thread_pool_size = worker_count()

// worker_count picks the worker-thread count: the number of CPUs THIS PROCESS may
// run on — not the host's total. `runtime.nr_cpus()` is `sysconf(_SC_NPROCESSORS_ONLN)`
// = every online host core, blind to CPU affinity (taskset) and cpuset pinning. A
// server pinned to N cores (a benchmark, or a container limited to N CPUs on a
// larger host) would otherwise spawn host-many workers and oversubscribe them
// N-ways — context-switch churn that drops throughput. On Linux we count the
// process's sched_getaffinity mask; `VANILLA_WORKERS` overrides explicitly (e.g.
// for cgroup CPU-quota limits, which don't restrict the affinity mask).
fn worker_count() int {
	vw := os.getenv('VANILLA_WORKERS')
	if vw != '' {
		n := vw.int()
		if n > 0 {
			return n
		}
	}
	$if linux {
		c := linux_affinity_cpu_count()
		if c > 0 {
			return c
		}
	}
	return runtime.nr_cpus()
}

// RequestHandler is the raw, zero-allocation handler contract: it receives the
// complete request bytes (a view into the connection's read buffer — copy
// anything that must outlive the call) and APPENDS the complete raw HTTP
// response (status line + headers + body) to `out`, the connection's
// persistent write buffer. The server owns `out`: it batches everything
// appended during one readiness event into a single send and reuses the
// buffer across requests — the handler must never free or keep it.
//
// Static routes append a precomputed `const ... .bytes()`; dynamic routes
// append a const prefix, the Content-Length digits, '\r\n\r\n' and the body.
// Returning an error sends 400 and closes the connection.
pub type RequestHandler = fn (req []u8, fd int, mut out []u8) !

// --- Async runtime (opt-in) -------------------------------------------------
//
// AsyncStep is what an async handler / continuation returns to the worker:
//   .done    — the response is in `out`; the worker sends it and unparks the conn
//   .suspend — the handler/continuation registered a watch (ac.watch); the conn
//              stays parked until that fd is ready (multi-step chains re-suspend)
//   .close   — error; the worker drops the connection
pub enum AsyncStep {
	done
	suspend
	close
}

// WatchInterest is the platform-agnostic readiness a watch waits for. The
// backend maps it to its native flag (epoll EPOLLIN/EPOLLOUT on Linux, kqueue
// EVFILT_READ/EVFILT_WRITE on macOS) — so handlers stay portable and never name
// a platform constant.
pub enum WatchInterest {
	readable
	writable
}

// WakeFn is a continuation: it runs when a watched fd (ac.ready_fd) becomes
// ready, may append the response to `out`, and returns the next AsyncStep.
pub type WakeFn = fn (mut out []u8, mut ac AsyncCtx) AsyncStep

// AsyncHandler is the opt-in async request handler. Like RequestHandler it gets
// the request bytes and the connection write buffer, but instead of always
// producing a response it can PARK the request on any fd via `ac.watch(...)` and
// return .suspend — the worker resumes the registered continuation when that fd
// is ready, all in the same epoll loop. The DB driver, a reverse proxy, timers,
// and SSE/WebSocket backpressure are all consumers of this one primitive.
pub type AsyncHandler = fn (req []u8, mut out []u8, mut ac AsyncCtx) AsyncStep

// RegisterFn is the backend-installed watch-registration hook (see AsyncCtx.register).
// A NAMED fn type, not an inline one on the field: on recent V (c0624b274) calling an
// inline-fn-typed struct field mis-resolves its parameter types and errors with
// "cannot use WatchInterest as WatchInterest" — a named alias resolves the signature
// canonically. (A vlang/v function-pointer-field checker quirk.)
pub type RegisterFn = fn (mut ac AsyncCtx, ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr)

// AsyncCtx is the per-invocation handle a handler/continuation uses to await an
// fd. The backend fills it in and installs `register`; handlers only call
// watch()/ready_fd()/udata()/state(). It is the layering bridge: `core` owns the
// type and the handler contract, the epoll backend owns the registration logic
// (added via the `register` fn pointer), so `core` stays backend-free.
pub struct AsyncCtx {
pub mut:
	client_fd    int
	ready_fd     int = -1 // the fd that woke this continuation (-1 on the initial call)
	ready_err    bool    // backend-filled: ready_fd woke with an error/hangup (epoll EPOLLERR|EPOLLHUP, kqueue EV_ERROR|EV_EOF), not normal readiness — the watched fd is dead, release it
	udata        voidptr // consumer context carried from watch() to the continuation
	state        voidptr // this worker's per-thread state (see StatefulHandler/make_state)
	loop_fd      int     // backend-filled: the worker's event-loop fd (epoll on Linux, kqueue on macOS)
	reactor      voidptr // backend-filled: the worker's watch registry
	last_watched int = -1 // backend-filled: the fd passed to the most recent watch()
	// persistent: set by watch_persistent for the duration of the register call to
	// flag the watched fd as a long-lived, caller-owned resource (e.g. a pooled DB
	// connection). The runtime then must NOT close that fd if the client parked on
	// it disconnects mid-wait — it drops the parked request and leaves the fd open
	// for reuse (closing it would force a reconnect + re-handshake). register reads
	// and resets it; a plain watch() leaves it false (the fd is request-owned and
	// closed on disconnect, e.g. a per-request timerfd or pipe).
	persistent bool
	register   RegisterFn = unsafe { nil }
}

// watch parks the current request and asks the worker to call `cont` when
// `ext_fd` becomes ready for `interest` (readable/writable). `udata` is handed
// back to the continuation via ac.udata. After calling watch, return .suspend.
pub fn (mut ac AsyncCtx) watch(ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr) {
	ac.register(mut ac, ext_fd, interest, cont, udata)
}

// watch_persistent is watch() for an fd the CALLER owns and reuses across
// requests (a pooled connection): if the parked client disconnects before the
// fd is ready, the runtime drops the request but leaves the fd OPEN for reuse,
// instead of closing it (which on a pooled DB connection would force a reconnect
// and a fresh auth handshake). Use it only for fds whose lifetime you manage;
// per-request fds (timerfd, pipe) must use watch() so they are closed on
// disconnect and do not leak.
pub fn (mut ac AsyncCtx) watch_persistent(ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr) {
	ac.persistent = true
	ac.register(mut ac, ext_fd, interest, cont, udata)
	ac.persistent = false
}

// ready_fd is the fd that woke the running continuation (-1 on the initial call).
pub fn (ac &AsyncCtx) ready_fd() int {
	return ac.ready_fd
}

// ready_err reports whether ready_fd became ready because of an error or hangup
// (the peer/other end closed, the fd is broken) rather than normal readiness —
// epoll EPOLLERR|EPOLLHUP, kqueue EV_ERROR|EV_EOF. A continuation that observes
// this should stop watching the fd (return .done/.close so the runtime releases
// it) instead of re-arming, otherwise a level-triggered watch on a dead fd
// re-fires every loop iteration (a busy-spin). It is a portable boolean on
// purpose: handlers never name a platform event constant (cf. WatchInterest).
pub fn (ac &AsyncCtx) ready_err() bool {
	return ac.ready_err
}

// WorkerStartFn runs ONCE per worker thread, right after make_state and before
// the event loop, ON the worker thread. It receives an AsyncCtx whose client_fd
// is -1 (there is no request): use it to arm CLIENTLESS background watches via
// ac.watch — e.g. a periodic timerfd that refreshes per-worker state, a signalfd,
// or an inotify fd. Such a watch's continuation later runs on this worker's loop
// with the same -1 client_fd and is handed a scratch (ignored) `out` buffer.
// ac.state is this worker's make_state value, or nil when no make_state is set
// (a stateless watch is fine; a stateful one must configure make_state).
//
// CONTRACT for a clientless continuation (a core.WakeFn):
//   - To keep the watch alive, re-arm THE SAME fd (`ac.watch(ac.ready_fd(), ...)`)
//     and return .suspend — the periodic-refresh pattern; the fd then lives for
//     the worker's whole lifetime and is never timed out or torn down as a conn.
//   - Do NOT close ac.ready_fd() yourself: on .done/.close the runtime detaches
//     AND closes it (avoiding an fd-reuse race); if you re-arm a DIFFERENT fd the
//     runtime only detaches the old one (you still own and must close it).
//   - Check ac.ready_err(): if the fd woke with an error/hangup, return .done or
//     .close (do NOT re-arm) — a re-armed watch on a dead level-triggered fd
//     busy-spins. (A timerfd never hangs up, so a refresh watch can ignore it.)
//
// It composes with ANY handler path (request_handler / stateful_handler /
// async_handler): the background watch shares the worker's epoll loop with normal
// request handling. epoll backend only.
pub type WorkerStartFn = fn (mut ac AsyncCtx)

// StatefulHandler is the per-thread-state variant of RequestHandler. It receives
// the same arguments PLUS an opaque `state voidptr` — the value the server's
// `make_state` callback returned for THIS worker thread (and only this one). It
// lets a handler reach per-thread resources (e.g. its own DB connection) with no
// lock: each worker owns its state, so nothing is shared across threads.
//
// The server never inspects `state`; it hands back exactly the pointer make_state
// produced, so the handler's `unsafe { &MyCtx(state) }` cast is sound. This is the
// same opaque-context contract as picoev's `cb_arg` or libuv's `data` void*.
//
// Wiring: set `make_state` + `stateful_handler` on ServerConfig instead of
// `request_handler`. Each worker calls make_state ONCE, then every request on that
// worker is dispatched through stateful_handler with that state. RequestHandler is
// untouched, so stateless handlers and the other backends are unaffected.
pub type StatefulHandler = fn (req []u8, fd int, mut out []u8, state voidptr) !

// Counter is a single i64 padded to a full cache line, so independent counters
// (per-worker in-flight, global active-connections) never false-share. Mutated
// via atomic add, read via atomic load (sync.stdatomic free funcs on &n).
@[heap]
pub struct Counter {
pub mut:
	n   i64
	pad [56]u8
}

// Limits bounds resource use. Every field defaults to 0 = unlimited, so the
// checks are zero-cost unless a server opts in. Re-exported publicly as
// `http_server.Limits` for the ergonomic config API.
pub struct Limits {
pub:
	max_header_bytes  int // > 0 ⇒ 431 Request Header Fields Too Large
	max_body_bytes    int // > 0 ⇒ 413 Payload Too Large (rejected from Content-Length, before buffering)
	max_request_bytes int // > 0 ⇒ ceiling on a single buffered request (headers+body); 0 ⇒ built-in default (8 MiB)
	max_connections   int // > 0 ⇒ refuse new connections past this many concurrent (checked at accept)
	read_timeout_ms   int // > 0 ⇒ close a connection that can't finish its request in this long (408)
	write_timeout_ms  int // > 0 ⇒ close a connection whose parked response can't drain in this long
}
