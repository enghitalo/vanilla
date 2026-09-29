module main

// Request limits — reference design (DoS resistance).
//
// A server with no limits falls over. These are CORE concerns — a handler can't
// enforce them after the fact — so they live in the read loop and are configured
// via `ServerConfig.limits`.
//
// WORKS TODAY (this example):
//   - max_body_bytes   -> 413 Payload Too Large, rejected from Content-Length
//     BEFORE the body is buffered (and bounds a chunked body too).
//   - max_header_bytes  -> 431 Request Header Fields Too Large.
//   - max_connections   -> refuse (close) new connections past the cap, checked
//     at accept; counted per-connection, so zero per-request cost. The cap only
//     bounds how many connections are open, not how long each one lives: a
//     connection that never sends a byte, or a keep-alive peer that vanished
//     without a FIN, holds its slot until a DEADLINE reaps it. Without
//     read_timeout_ms / idle_timeout_ms, enough of those fill the cap and every
//     new connection is refused — so always pair the cap with a timeout.
//   - read_timeout_ms    -> a request (head + body) must arrive complete within
//     this window. The FIRST request's clock starts at accept, so it also
//     bounds a connection that never sends anything (and, over HTTPS, the TLS
//     handshake); a later request's clock starts at its first byte. It is never
//     refreshed by progress — the real slowloris defence: a peer that dribbles
//     one byte at a time is reaped on a deadline, not just on a single
//     readiness burst. 408 Request Timeout if part of the request arrived; a
//     peer that sent nothing is closed silently.
//   - write_timeout_ms   -> a parked response (slow consumer, full socket buffer)
//     that can't drain within this window is dropped.
//   - idle_timeout_ms    -> keep-alive: once a response is fully sent, how long
//     to wait for the next request's first byte before closing silently.
//     0 inherits read_timeout_ms; -1 means never (a handler that hands its fd
//     to another thread to stream needs that — see examples/video_stream).
//   All default to 0 = unlimited and cost nothing on the hot path (no clock
//   reads, no sweep) unless a timeout is set; then each worker sweeps its
//   deadlines every Limits.sweep_interval_ms() (25-250 ms), so a connection
//   closes at most one interval after its deadline. The kqueue (macOS) backend
//   enforces none of max_connections or the timeouts yet.
import server
import core

// The handler is now trivial: the CORE enforces the size limits before the
// handler ever runs — over-large bodies are rejected (413) from Content-Length
// WITHOUT buffering them, and oversized header blocks get 431. That's the whole
// point: limits belong in the read loop, not bolted onto each handler.
fn handle(_req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
	return .done
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
		limits:          server.Limits{
			max_body_bytes:   10 * 1024 * 1024 // 10 MiB -> 413
			max_header_bytes: 16 * 1024        // 16 KiB  -> 431
			max_connections:  100_000          // refuse past this many concurrent
			read_timeout_ms:  5_000            // finish the request within 5s of accept / its first byte (408 if partial)
			write_timeout_ms: 10_000           // drain a parked response within 10s or be dropped
			idle_timeout_ms:  30_000           // keep an idle keep-alive connection 30s (0 would inherit the 5s above)
		}
	})!
	println('Request-limits demo — core enforces size, connection and timeout limits (see file header).')
	srv.run()
}
