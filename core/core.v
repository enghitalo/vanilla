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
//              fd is ready or the park's deadline passes (park_timeout_ms,
//              watch_fd_deadline; multi-step chains re-suspend). Supported on Linux
//              epoll + io_uring and macOS kqueue; the TLS and Windows/IOCP
//              workers have no watch reactor yet, so there a .suspend DROPS
//              the connection (see reject_register).
//   .close   — finish this connection: whatever is in `res` is flushed, then
//              the connection is closed — from a handler or a continuation
//              alike. The TLS worker and macOS kqueue make one best-effort
//              write instead, bounded by the socket send buffer; every other
//              worker closes once all of it is sent. Append an error response
//              (e.g. response.tiny_bad_request_response) before returning
//              .close if the client should see one.
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
//
// It also runs, ONCE, when the watch's deadline passes first
// (Limits.park_timeout_ms, watch_fd_deadline): then event_loop.timed_out() is
// true, ready_fd is the watched fd, which is NOT ready (do not read it), and
// ready_fd_error is false. See EventLoop.timed_out for the contract.
pub type WakeFn = fn (mut response []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop EventLoop) Step

// WakeReason is why a continuation runs (EventLoop.reason; ask
// event_loop.timed_out()). One notion for every backend wake-up, so later
// reasons extend this enum instead of adding a second continuation type.
pub enum WakeReason {
	ready    // the watched fd is ready, or failed (ready_fd_error)
	timeout  // the watch's deadline passed before the fd was ready; or, for a wake fn, its wake_after timer
	posted   // a wake fn: a post reached the connection's ConnHandle (post_tag, post_data)
	closed   // a wake fn's last call: the connection is gone, `response` is scratch
	shutdown // a wake fn: Server.shutdown() was called
}

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
// Static routes append a `const` string with core.append_str and return .done;
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
// developer-facing surface is a handful of methods:
//
//   event_loop.watch_fd(fd, .readable, continuation, watch_payload)
//   event_loop.watch_fd_persistent(fd, .readable, continuation, watch_payload)
//   event_loop.watch_fd_deadline(fd, .readable, continuation, watch_payload, timeout_ms)
//   event_loop.watch_fd_persistent_deadline(fd, .readable, continuation, watch_payload, timeout_ms)
//   event_loop.timed_out() // in a continuation: woken by the deadline, not the fd
//   event_loop.watch_fd_background(fd, .readable, continuation, watch_payload)
//   event_loop.subscribe(wake_fn, sub_state) // server push (conn_handle.v)
//   event_loop.wake_after(ms)
//   event_loop.reason() / post_tag() / post_data() // in a wake fn
//
// Everything else (client_fd — whose request parks, loop_fd, reactor,
// last_watched, persistent, timeout_ms, reason, register, the hooks and the
// post fields) is plumbing filled by the backend; handlers never touch the
// fields. It is the layering bridge:
// `core` owns the type and the handler contract, each backend owns the
// registration logic (installed via the `register` fn pointer), so `core`
// stays backend-free.
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
	// timeout_ms: plumbing, the deadline the most recent watch_fd*() asked for
	// (0 = none of its own: Limits.park_timeout_ms applies; < 0 = none at
	// all). Every watch_fd* call sets it, like last_watched, and the backend
	// reads it when the request parks.
	timeout_ms int
	// reason: plumbing, why the backend is running the current continuation.
	reason   WakeReason
	register RegisterFn = unsafe { nil }
	// Subscriptions (conn_handle.v): the backend's hooks (nil = none here),
	// and the post a wake fn is delivering (.posted).
	subscribe_hook  SubscribeFn = unsafe { nil }
	wake_after_hook WakeAfterFn = unsafe { nil }
	post_tag        u64
	post_ptr        voidptr
	post_len        int
}

// watch_fd parks the current request and asks the worker to run `continuation`
// when `fd` becomes ready for `interest` (readable/writable). `watch_payload`
// is handed back to the continuation as its watch_payload parameter. After
// calling watch_fd, return .suspend. The park is bounded by
// Limits.park_timeout_ms when that is set (see watch_fd_deadline).
pub fn (mut event_loop EventLoop) watch_fd(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr) {
	event_loop.timeout_ms = 0
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
	event_loop.timeout_ms = 0
	event_loop.persistent = true
	event_loop.register(mut event_loop, fd, interest, continuation, watch_payload)
	event_loop.persistent = false
}

// watch_fd_deadline is watch_fd() with a deadline of its own: if `fd` is not
// ready within `timeout_ms`, the continuation runs ONCE with
// event_loop.timed_out() true instead. 0 falls back to Limits.park_timeout_ms;
// a negative value exempts this park from it (a long poll, an SSE heartbeat
// timer longer than the server-wide bound). Each watch_fd* call sets the
// deadline of the park it arms: a continuation that re-arms (a multi-step
// chain, a reply that arrives in pieces) gets a fresh one, so pass the time
// left to bound a whole request.
//
// Enforced by the epoll plain worker. Elsewhere (io_uring, kqueue) it is a
// plain watch_fd: the deadline is not enforced and timed_out() stays false.
// A clientless background watch (on_worker_start, watch_fd_background) has no
// deadline.
pub fn (mut event_loop EventLoop) watch_fd_deadline(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr, timeout_ms int) {
	event_loop.timeout_ms = timeout_ms
	event_loop.register(mut event_loop, fd, interest, continuation, watch_payload)
}

// watch_fd_persistent_deadline is watch_fd_persistent() with the deadline of
// watch_fd_deadline. On timeout the parked request is answered by the
// continuation, but the reply still due on the caller-owned fd is drained IN
// ORDER: the watch stays as a tombstone, and when that reply arrives the
// continuation runs once more against a discarded response buffer, exactly as
// after a client disconnect (see EventLoop.timed_out).
pub fn (mut event_loop EventLoop) watch_fd_persistent_deadline(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr, timeout_ms int) {
	event_loop.timeout_ms = timeout_ms
	event_loop.persistent = true
	event_loop.register(mut event_loop, fd, interest, continuation, watch_payload)
	event_loop.persistent = false
}

// timed_out reports, inside a continuation, that it runs because its watch's
// deadline passed (Limits.park_timeout_ms, watch_fd_deadline) and not because
// the fd became ready. It runs so exactly once per expired park, with
// ready_fd the watched fd (NOT ready: do not read it) and ready_fd_error
// false. Answer the request (e.g. 504 Gateway Timeout, or 503) and return
// .done; or re-arm a watch (on the same fd, with a new deadline, to keep
// waiting; or on another fd) and return .suspend. What happens to the watch
// it stops waiting on:
//   - request-owned (watch_fd, watch_fd_deadline): the runtime forgets it and
//     takes the fd out of the event loop; a readiness that comes later wakes
//     nothing. The fd is still the continuation's: close it there, as on
//     readiness.
//   - caller-owned (watch_fd_persistent*): the reply still due must not reach
//     the next request on that fd, so the watch becomes a tombstone, as when
//     a parked client disconnects: when the reply arrives (or the fd fails),
//     the continuation runs again with timed_out() false, against a discarded
//     response buffer, to consume it in order. So in the timeout branch do NOT
//     consume the fd's reply and do NOT hand the connection back to its pool:
//     the draining run does that. To get the reply sooner, ask the server to
//     abandon the work (pg_async: PgConn.cancel); to give up on the
//     connection, shutdown(2) its socket (the tombstone then drains on the
//     hangup).
// Always false outside a continuation, and on backends that do not enforce
// deadlines.
@[inline]
pub fn (event_loop &EventLoop) timed_out() bool {
	return event_loop.reason == .timeout
}

// watch_fd_background arms a CLIENTLESS watch on this worker's event loop from
// a handler or a continuation: no request parks on it (the caller still
// returns whatever Step it returns), and `continuation` later runs on this
// worker with a scratch `response` that is discarded, under the
// on_worker_start contract (see WorkerStartFn): re-arm the same fd and return
// .suspend to keep watching; .done/.close and the runtime detaches AND closes
// the fd. Fire-and-forget I/O tied to the worker, e.g. pg_async's
// CancelRequest. Returns false, arming nothing, where the worker cannot run
// clientless watches (every backend but the epoll plain worker): the fd is
// then still the caller's to close.
pub fn (mut event_loop EventLoop) watch_fd_background(fd int, interest WatchInterest, continuation WakeFn, watch_payload voidptr) bool {
	mut bg := EventLoop{
		...event_loop
		client_fd:       -1
		last_watched:    -1
		persistent:      false
		timeout_ms:      0
		subscribe_hook:  unsafe { nil }
		wake_after_hook: unsafe { nil }
	}
	bg.register(mut bg, fd, interest, continuation, watch_payload)
	return bg.last_watched == fd
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
// checks are zero-cost unless a server opts in — with ONE exception:
// idle_timeout_ms = 0 inherits read_timeout_ms (Go net/http's IdleTimeout
// rule), so a server that sets read_timeout_ms alone also reaps idle
// keep-alive connections. With both at 0 nothing is armed. Re-exported
// publicly as `server.Limits` for the ergonomic config API.
//
// Timeouts are enforced by each worker's deadline sweep, which runs every
// sweep_interval_ms(): a connection is closed at most that long after its
// deadline. park_timeout_ms is not swept (see its field). The kqueue (darwin)
// backend does not enforce max_connections or any timeout yet.
pub struct Limits {
pub:
	max_header_bytes  int // > 0 ⇒ 431 Request Header Fields Too Large
	max_body_bytes    int // > 0 ⇒ 413 Payload Too Large (rejected from Content-Length, before buffering)
	max_request_bytes int // > 0 ⇒ ceiling on a single buffered request (headers+body); 0 ⇒ default_max_request_bytes (8 MiB)
	max_connections   int // > 0 ⇒ refuse new connections past this many concurrent (checked at accept). Pair with read_timeout_ms: without a deadline, connections that never send (or peers that vanish) hold their slots forever
	read_timeout_ms   int // > 0 ⇒ a request (head + body) must arrive complete within this long, else close — 408 if part of it arrived and no earlier response is still being sent (plaintext epoll/poll/iocp), silently otherwise. The FIRST request's clock starts at accept (it bounds a silent connect and the TLS handshake); a later request's starts at its first byte. Not refreshed on progress: size it for your largest upload
	write_timeout_ms  int // > 0 ⇒ close a connection whose parked response can't drain in this long
	idle_timeout_ms   int // keep-alive: after a response is fully sent, how long to wait for the first byte of the next request before closing silently. It bounds only the wait for a request's first byte: a started request is bounded by read_timeout_ms alone, so pair max_connections with read_timeout_ms (and write_timeout_ms, for peers that stop reading). 0 ⇒ read_timeout_ms; < 0 (use -1) ⇒ never, e.g. a handler that hands the fd to another thread to stream, or a proxy in front that manages upstream idle itself
	// park_timeout_ms > 0 ⇒ the default deadline of a request parked on a
	// watch (.suspend): a watched fd that is not ready within this long (a
	// hung database or upstream, a pipe whose writer died) runs the
	// continuation once with event_loop.timed_out() true, which answers (504)
	// and cleans up. Per park: each watch_fd* call arms a fresh one, and
	// watch_fd_deadline overrides it per watch (a negative value exempts one).
	// Not swept: each worker keeps its park deadlines in a heap and wakes for
	// the earliest, so it fires within ~1 ms of its time and needs no other
	// timeout set. Read, write and idle deadlines never apply to a parked
	// request, so without it a park waits as long as its fd does. 0 ⇒ none.
	// Epoll plain worker only (io_uring and kqueue do not enforce it).
	park_timeout_ms int
}

// default_max_request_bytes is the ceiling on a single buffered request
// (headers+body) when Limits.max_request_bytes is 0: past it the request is
// refused, so a hostile peer can't grow a read buffer without bound. Every
// backend falls back to it, and http2 caps a stream's body at it.
pub const default_max_request_bytes = 8 * 1024 * 1024

// max_pending_write_bytes is the write-side cap: a connection whose unsent
// responses exceed it is closed, since a peer that pipelines requests but
// never reads the answers would otherwise grow its write buffer without bound.
// Fixed, not a Limits field; it also caps ServerConfig.push_watermark_bytes.
// Enforced by the plain epoll, io_uring, poll and IOCP backends.
pub const max_pending_write_bytes = 8 * 1024 * 1024

// idle_ms resolves the keep-alive idle budget: idle_timeout_ms when > 0,
// read_timeout_ms when idle_timeout_ms is 0, and 0 (off) when idle_timeout_ms
// is negative. Backends resolve it once per worker, off the hot path. When
// read_timeout_ms is 0 it also bounds a new connection's wait for its first
// byte (a connection that has sent nothing is idle).
pub fn (l Limits) idle_ms() int {
	if l.idle_timeout_ms > 0 {
		return l.idle_timeout_ms
	}
	if l.idle_timeout_ms == 0 && l.read_timeout_ms > 0 {
		return l.read_timeout_ms
	}
	return 0
}

// sweep_interval_ms is how often a worker scans its connections for expired
// deadlines: a quarter of the shortest active timeout, clamped to [25, 250]
// ms. 0 when no timeout is set — then there is no sweep and an idle worker
// never wakes. Rate-limiting the scan to this cadence keeps a busy worker from
// walking its whole connection table after every batch.
pub fn (l Limits) sweep_interval_ms() int {
	mut shortest := 0
	for t in [l.read_timeout_ms, l.write_timeout_ms, l.idle_ms()]! {
		if t > 0 && (shortest == 0 || t < shortest) {
			shortest = t
		}
	}
	if shortest == 0 {
		return 0
	}
	return if shortest / 4 < 25 {
		25
	} else if shortest / 4 > 250 {
		250
	} else {
		shortest / 4
	}
}
