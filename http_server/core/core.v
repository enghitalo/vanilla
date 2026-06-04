module core

import runtime

// Shared, dependency-free types used by both the public `http_server` facade and
// the backend implementations (e.g. `backend_epoll`). Keeping them in a leaf
// module breaks what would otherwise be a cycle: `http_server` imports a backend
// to run it, and the backend needs these types — so neither can own them.

// One worker thread per core (thread-per-core model). Both the facade (thread /
// counter array sizing) and the backend (worker fan-out) need this count.
pub const max_thread_pool_size = runtime.nr_cpus()

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
