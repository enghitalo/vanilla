module core

import runtime
import os

// Shared, dependency-free types used by both the public `server` facade and
// the backend implementations (e.g. `backend_epoll`). Keeping them in a leaf
// module breaks what would otherwise be a cycle: `server` imports a backend
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
//   .suspend — the handler/continuation registered a watch
//              (event_loop.watch_fd); the connection stays parked until that
//              fd is ready (multi-step chains re-suspend). Supported on Linux
//              epoll + io_uring and macOS kqueue; the TLS and Windows/IOCP
//              workers have no watch reactor yet, so there a .suspend DROPS
//              the connection (see reject_register).
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

// WakeFn is a continuation: it runs when a watched fd becomes ready. Every
// input is an explicit parameter — nothing is hidden in a context object:
//   ready_fd       — the fd whose readiness woke this continuation
//   ready_fd_error — that fd woke with an error/hangup (epoll EPOLLERR|
//                    EPOLLHUP, kqueue EV_ERROR|EV_EOF), not normal readiness:
//                    the watched fd is dead — release it (return .done/.close),
//                    do NOT re-arm it (a level-triggered dead fd busy-spins)
//   watch_payload  — the value handed to watch_fd() by whoever armed the watch
//   worker_state   — this worker thread's make_state value (nil if unset)
// It may append the response to `response` and returns the next Step.
pub type WakeFn = fn (mut response []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop EventLoop) Step

// Handler is THE request handler contract — one signature for every use case:
// static routes, per-worker state, and parked/resumed requests. Every input is
// an explicit, self-describing parameter — nothing hides in a context object:
//
//   request      — the complete request bytes (a view into the connection's
//                  read buffer; copy anything that must outlive the call)
//   response     — the connection's persistent write buffer: APPEND the
//                  complete raw HTTP response (status line + headers + body).
//                  The server owns it: everything appended during one
//                  readiness event goes out in a single send and the buffer is
//                  reused across requests — never free or keep it.
//   client_fd    — the served client connection's fd
//   worker_state — the value ServerConfig.make_state returned on THIS worker
//                  thread (nil when no make_state is configured). The server
//                  never inspects it, so `unsafe { &MyState(worker_state) }`
//                  is sound, and it is thread-local by construction — no lock.
//   event_loop   — this worker's event loop, for handlers that must wait (see
//                  EventLoop): park with event_loop.watch_fd(...) + .suspend.
//
// Static routes append a precomputed `const ... .bytes()` and return .done;
// dynamic routes append a const prefix, the Content-Length digits, '\r\n\r\n'
// and the body. On a bad request, append the canned error response and return
// .close. A handler that must wait on something (a DB socket, an upstream,
// a timer, client writability) PARKS the request on that fd via
// `event_loop.watch_fd(...)` and returns .suspend — the worker resumes the
// registered continuation when the fd is ready, all in the same event loop.
// The DB driver, a reverse proxy, timers, and SSE/WebSocket backpressure are
// all consumers of that one primitive.
pub type Handler = fn (request []u8, mut response []u8, client_fd int, worker_state voidptr, mut event_loop EventLoop) Step

// RegisterFn is the backend-installed watch-registration hook (see
// EventLoop.register). A NAMED fn type, not an inline one on the field: on
// recent V (c0624b274) calling an inline-fn-typed struct field mis-resolves
// its parameter types and errors with "cannot use WatchInterest as
// WatchInterest" — a named alias resolves the signature canonically. (A
// vlang/v function-pointer-field checker quirk.)
pub type RegisterFn = fn (mut event_loop EventLoop, ext_fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr)

// EventLoop is the ONE deliberately small struct in the handler contract: the
// handle to this worker's event loop, carried only because the wait primitive
// needs backend plumbing that would otherwise leak into every signature. Its
// developer-facing surface is exactly two methods:
//
//   event_loop.watch_fd(fd, .readable, continuation, watch_payload)
//   event_loop.watch_fd_persistent(fd, .readable, continuation, watch_payload)
//
// Everything else (client_fd — whose request parks, loop_fd, reactor,
// last_watched, persistent, register) is plumbing filled by the backend;
// handlers never touch the fields. It is the layering bridge: `core` owns the
// type and the handler contract, each backend owns the registration logic
// (installed via the `register` fn pointer), so `core` stays backend-free.
pub struct EventLoop {
pub mut:
	client_fd    int = -1 // plumbing: the client whose request parks on the next watch_fd (-1 = clientless background watch)
	loop_fd      int     // plumbing: the worker's event-loop fd (epoll on Linux, kqueue on macOS)
	reactor      voidptr // plumbing: the worker's watch registry
	last_watched int = -1 // plumbing: the fd passed to the most recent watch_fd()
	// persistent: set by watch_fd_persistent for the duration of the register
	// call to flag the watched fd as a long-lived, caller-owned resource (e.g. a
	// pooled DB connection). The runtime then must NOT close that fd if the
	// client parked on it disconnects mid-wait — it drops the parked request and
	// leaves the fd open for reuse (closing it would force a reconnect +
	// re-handshake). register reads and resets it; a plain watch_fd() leaves it
	// false (the fd is request-owned and closed on disconnect, e.g. a
	// per-request timerfd or pipe).
	persistent bool
	register   RegisterFn = unsafe { nil }
}

// watch_fd parks the current request and asks the worker to run `continuation`
// when `fd` becomes ready for `interest` (readable/writable). `watch_payload`
// is handed back to the continuation as its watch_payload parameter. After
// calling watch_fd, return .suspend.
pub fn (mut event_loop EventLoop) watch_fd(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr) {
	event_loop.register(mut event_loop, fd, interest, continuation, watch_payload)
}

// watch_fd_persistent is watch_fd() for an fd the CALLER owns and reuses across
// requests (a pooled connection): if the parked client disconnects before the
// fd is ready, the runtime drops the request but leaves the fd OPEN for reuse,
// instead of closing it (which on a pooled DB connection would force a reconnect
// and a fresh auth handshake). Use it only for fds whose lifetime you manage;
// per-request fds (timerfd, pipe) must use watch_fd() so they are closed on
// disconnect and do not leak.
pub fn (mut event_loop EventLoop) watch_fd_persistent(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr) {
	event_loop.persistent = true
	event_loop.register(mut event_loop, fd, interest, continuation, watch_payload)
	event_loop.persistent = false
}

// reject_register is the EventLoop.register stub for workers that have NO
// watch reactor (the TLS worker and the Windows/IOCP worker): it arms nothing
// and leaves last_watched at -1, so a handler that suspends anyway is simply
// dropped by the caller — parking cannot be resumed where nothing watches.
// Shared here so the reactorless backends cannot drift apart.
pub fn reject_register(mut event_loop EventLoop, ext_fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr) {
	event_loop.last_watched = -1
}

// WorkerStartFn runs ONCE per worker thread, right after make_state and before
// the event loop, ON the worker thread. There is no request and no client: use
// it to arm CLIENTLESS background watches via event_loop.watch_fd — e.g. a
// periodic timerfd that refreshes per-worker state, a signalfd, or an inotify
// fd. Such a watch's continuation later runs on this worker's loop and is
// handed a scratch (ignored) `response` buffer. worker_state is this worker's
// make_state value, or nil when no make_state is set (a stateless watch is
// fine; a stateful one must configure make_state).
//
// CONTRACT for a clientless continuation (a core.WakeFn):
//   - To keep the watch alive, re-arm THE SAME fd
//     (`event_loop.watch_fd(ready_fd, ...)`) and return .suspend — the
//     periodic-refresh pattern; the fd then lives for the worker's whole
//     lifetime and is never timed out or torn down as a conn.
//   - Do NOT close ready_fd yourself: on .done/.close the runtime detaches
//     AND closes it (avoiding an fd-reuse race); if you re-arm a DIFFERENT fd
//     the runtime only detaches the old one (you still own and must close it).
//   - Check ready_fd_error: if the fd woke with an error/hangup, return .done
//     or .close (do NOT re-arm) — a re-armed watch on a dead level-triggered
//     fd busy-spins. (A timerfd never hangs up, so a refresh watch can ignore it.)
//
// The background watch shares the worker's epoll loop with normal request
// handling. epoll backend only.
pub type WorkerStartFn = fn (worker_state voidptr, mut event_loop EventLoop)

// AfterStartFn runs ONCE, on the main thread, the moment the server is accepting
// connections — every listener is bound + listening and the worker threads are
// spawned — right before run() blocks in its accept/idle loop. Unlike
// WorkerStartFn (which is per-worker, on the worker thread, epoll-only), this is a
// single process-level lifecycle hook and works on EVERY backend.
//
// It takes no arguments: it is the "server is up" signal. Use it to log
// "listening on :3000", register in service discovery, write a PID/health/ready
// file, notify a supervisor (systemd sd_notify), or — in tests — signal a channel
// so the client proceeds the instant the server is ready instead of polling. It
// runs synchronously in run() before the loop, so keep it quick (or hand heavy
// work to a spawned thread); a panic in it propagates out of run().
pub type AfterStartFn = fn ()

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
// `server.Limits` for the ergonomic config API.
pub struct Limits {
pub:
	max_header_bytes  int // > 0 ⇒ 431 Request Header Fields Too Large
	max_body_bytes    int // > 0 ⇒ 413 Payload Too Large (rejected from Content-Length, before buffering)
	max_request_bytes int // > 0 ⇒ ceiling on a single buffered request (headers+body); 0 ⇒ built-in default (8 MiB)
	max_connections   int // > 0 ⇒ refuse new connections past this many concurrent (checked at accept)
	read_timeout_ms   int // > 0 ⇒ close a connection that can't finish its request in this long (408)
	write_timeout_ms  int // > 0 ⇒ close a connection whose parked response can't drain in this long
}
