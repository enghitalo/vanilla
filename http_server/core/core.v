module core

import runtime
import os

// Shared, dependency-free types used by both the public `http_server` facade and
// the backend implementations (e.g. `backend_epoll`). Keeping them in a leaf
// module breaks what would otherwise be a cycle: `http_server` imports a backend
// to run it, and the backend needs these types — so neither can own them.

// One worker thread per core (thread-per-core model). Both the facade (thread /
// counter array sizing) and the backend (worker fan-out) need this count.
pub const max_thread_pool_size = worker_count()

// worker_count picks the worker-thread count. Default = `runtime.nr_cpus()`.
// `VANILLA_WORKERS` overrides it explicitly.
//
// NOTE: this used to auto-derive the count from `sched_getaffinity` (to avoid
// oversubscribing when pinned to fewer CPUs). That REGRESSED the DB-bound arena
// profiles (crud/api-4/api-16): on a CPU-limited cpuset, affinity cut the worker
// count, but a thread-per-core server with per-worker DB pools WANTS many workers
// there — more workers = more in-flight DB requests hiding latency. Fewer workers
// starved the pools → shedding (503) and idle CPU. So the default is nr_cpus again;
// set VANILLA_WORKERS if you specifically need to cap workers in a constrained box.
fn worker_count() int {
	vw := os.getenv('VANILLA_WORKERS')
	if vw != '' {
		n := vw.int()
		if n > 0 {
			return n
		}
	}
	return runtime.nr_cpus()
}

// Step is what a handler / continuation returns to the worker:
//   .done    — the response is complete in `res`; the worker sends it (and, for
//              a resumed continuation, unparks the connection)
//   .suspend — the handler/continuation registered a watch (ctx.watch); the
//              connection stays parked until that fd is ready (multi-step
//              chains re-suspend)
//   .close   — finish this connection: whatever is in `res` is flushed, then
//              the connection is closed. Append an error response (e.g.
//              response.tiny_bad_request_response) before returning .close if
//              the client should see one.
pub enum Step {
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

// WakeFn is a continuation: it runs when a watched fd (ctx.ready_fd) becomes
// ready, may append the response to `res`, and returns the next Step.
pub type WakeFn = fn (mut res []u8, mut ctx Ctx) Step

// Handler is THE request handler contract — one signature for every use case:
// static routes, per-worker state, and async/parked requests. It receives the
// complete request bytes (a view into the connection's read buffer — copy
// anything that must outlive the call) and APPENDS the complete raw HTTP
// response (status line + headers + body) to `res`, the connection's
// persistent write buffer. The server owns `res`: it batches everything
// appended during one readiness event into a single send and reuses the
// buffer across requests — the handler must never free or keep it.
//
// Static routes append a precomputed `const ... .bytes()` and return .done;
// dynamic routes append a const prefix, the Content-Length digits, '\r\n\r\n'
// and the body. On a bad request, append the canned error response and return
// .close. A handler that must wait on something (a DB socket, an upstream,
// a timer, client writability) PARKS the request on that fd via
// `ctx.watch(...)` and returns .suspend — the worker resumes the registered
// continuation when the fd is ready, all in the same event loop. The DB
// driver, a reverse proxy, timers, and SSE/WebSocket backpressure are all
// consumers of that one primitive.
//
// Per-worker state (a thread-local DB connection, reused render scratch) is
// reachable via ctx.state — the value ServerConfig.make_state returned on THIS
// worker thread (nil when no make_state is configured). The client's fd is
// ctx.client_fd.
pub type Handler = fn (req []u8, mut res []u8, mut ctx Ctx) Step

// RegisterFn is the backend-installed watch-registration hook (see Ctx.register).
// A NAMED fn type, not an inline one on the field: on recent V (c0624b274) calling an
// inline-fn-typed struct field mis-resolves its parameter types and errors with
// "cannot use WatchInterest as WatchInterest" — a named alias resolves the signature
// canonically. (A vlang/v function-pointer-field checker quirk.)
pub type RegisterFn = fn (mut ctx Ctx, ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr)

// Ctx is the per-invocation handle a handler/continuation uses to reach the
// runtime: the client fd (client_fd), this worker's per-thread state (state),
// and the await-an-fd primitive (watch/watch_persistent/ready_fd/ready_err).
// The backend fills it in and installs `register`. It is the layering bridge:
// `core` owns the type and the handler contract, each backend owns the
// registration logic (added via the `register` fn pointer), so `core` stays
// backend-free.
pub struct Ctx {
pub mut:
	client_fd    int
	ready_fd     int = -1 // the fd that woke this continuation (-1 on the initial call)
	ready_err    bool    // backend-filled: ready_fd woke with an error/hangup (epoll EPOLLERR|EPOLLHUP, kqueue EV_ERROR|EV_EOF), not normal readiness — the watched fd is dead, release it
	udata        voidptr // consumer context carried from watch() to the continuation
	state        voidptr // this worker's per-thread state (see make_state on ServerConfig)
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
// back to the continuation via ctx.udata. After calling watch, return .suspend.
pub fn (mut ctx Ctx) watch(ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr) {
	ctx.register(mut ctx, ext_fd, interest, cont, udata)
}

// watch_persistent is watch() for an fd the CALLER owns and reuses across
// requests (a pooled connection): if the parked client disconnects before the
// fd is ready, the runtime drops the request but leaves the fd OPEN for reuse,
// instead of closing it (which on a pooled DB connection would force a reconnect
// and a fresh auth handshake). Use it only for fds whose lifetime you manage;
// per-request fds (timerfd, pipe) must use watch() so they are closed on
// disconnect and do not leak.
pub fn (mut ctx Ctx) watch_persistent(ext_fd int, interest WatchInterest, cont WakeFn, udata voidptr) {
	ctx.persistent = true
	ctx.register(mut ctx, ext_fd, interest, cont, udata)
	ctx.persistent = false
}

// ready_fd is the fd that woke the running continuation (-1 on the initial call).
pub fn (ctx &Ctx) ready_fd() int {
	return ctx.ready_fd
}

// ready_err reports whether ready_fd became ready because of an error or hangup
// (the peer/other end closed, the fd is broken) rather than normal readiness —
// epoll EPOLLERR|EPOLLHUP, kqueue EV_ERROR|EV_EOF. A continuation that observes
// this should stop watching the fd (return .done/.close so the runtime releases
// it) instead of re-arming, otherwise a level-triggered watch on a dead fd
// re-fires every loop iteration (a busy-spin). It is a portable boolean on
// purpose: handlers never name a platform event constant (cf. WatchInterest).
pub fn (ctx &Ctx) ready_err() bool {
	return ctx.ready_err
}

// WorkerStartFn runs ONCE per worker thread, right after make_state and before
// the event loop, ON the worker thread. It receives a Ctx whose client_fd
// is -1 (there is no request): use it to arm CLIENTLESS background watches via
// ctx.watch — e.g. a periodic timerfd that refreshes per-worker state, a signalfd,
// or an inotify fd. Such a watch's continuation later runs on this worker's loop
// with the same -1 client_fd and is handed a scratch (ignored) `res` buffer.
// ctx.state is this worker's make_state value, or nil when no make_state is set
// (a stateless watch is fine; a stateful one must configure make_state).
//
// CONTRACT for a clientless continuation (a core.WakeFn):
//   - To keep the watch alive, re-arm THE SAME fd (`ctx.watch(ctx.ready_fd(), ...)`)
//     and return .suspend — the periodic-refresh pattern; the fd then lives for
//     the worker's whole lifetime and is never timed out or torn down as a conn.
//   - Do NOT close ctx.ready_fd() yourself: on .done/.close the runtime detaches
//     AND closes it (avoiding an fd-reuse race); if you re-arm a DIFFERENT fd the
//     runtime only detaches the old one (you still own and must close it).
//   - Check ctx.ready_err(): if the fd woke with an error/hangup, return .done or
//     .close (do NOT re-arm) — a re-armed watch on a dead level-triggered fd
//     busy-spins. (A timerfd never hangs up, so a refresh watch can ignore it.)
//
// The background watch shares the worker's epoll loop with normal request
// handling. epoll backend only.
pub type WorkerStartFn = fn (mut ctx Ctx)

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
