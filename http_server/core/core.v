module core

import runtime

// Shared, dependency-free types used by both the public `http_server` facade and
// the backend implementations (e.g. `backend_epoll`). Keeping them in a leaf
// module breaks what would otherwise be a cycle: `http_server` imports a backend
// to run it, and the backend needs these types — so neither can own them.

// One worker thread per core (thread-per-core model). Both the facade (thread /
// counter array sizing) and the backend (worker fan-out) need this count.
pub const max_thread_pool_size = runtime.nr_cpus()

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

// AsyncCtx is the per-invocation handle a handler/continuation uses to await an
// fd. The backend fills it in and installs `register`; handlers only call
// watch()/ready_fd()/udata()/state(). It is the layering bridge: `core` owns the
// type and the handler contract, the epoll backend owns the registration logic
// (added via the `register` fn pointer), so `core` stays backend-free.
pub struct AsyncCtx {
pub mut:
	client_fd    int
	ready_fd     int = -1 // the fd that woke this continuation (-1 on the initial call)
	udata        voidptr // consumer context carried from watch() to the continuation
	state        voidptr // this worker's per-thread state (see StatefulHandler/make_state)
	epoll_fd     int     // backend-filled: the worker's epoll instance
	reactor      voidptr // backend-filled: the worker's watch registry
	last_watched int = -1 // backend-filled: the fd passed to the most recent watch()
	register     fn (mut ac AsyncCtx, ext_fd int, events u32, cont WakeFn, udata voidptr) = unsafe { nil }
}

// watch parks the current request and asks the worker to call `cont` when
// `ext_fd` is ready for `events` (EPOLLIN/EPOLLOUT). `udata` is handed back to
// the continuation via ac.udata. After calling watch, return .suspend.
pub fn (mut ac AsyncCtx) watch(ext_fd int, events u32, cont WakeFn, udata voidptr) {
	ac.register(mut ac, ext_fd, events, cont, udata)
}

// ready_fd is the fd that woke the running continuation (-1 on the initial call).
pub fn (ac &AsyncCtx) ready_fd() int {
	return ac.ready_fd
}

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
