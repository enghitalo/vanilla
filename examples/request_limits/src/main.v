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
//     at accept; counted per-connection, so zero per-request cost.
//   - read_timeout_ms    -> a connection that opens but can't finish its request
//     within this window is closed with 408 Request Timeout. This is the real
//     slowloris defence: a peer that dribbles one byte at a time is reaped on a
//     deadline, not just on a single readiness burst.
//   - write_timeout_ms   -> a parked response (slow consumer, full socket buffer)
//     that can't drain within this window is dropped.
//   All default to 0 = unlimited (zero-cost on the hot path — the worker only
//   arms a periodic sweep when a timeout is set AND a connection is mid-transfer).
//
// STILL TO COME (see IMPLEMENTATION_PLAN.md, Phase 2 remainder):
//   - idle_timeout to reap idle keep-alive connections (max_connections already
//     bounds total fds).
import http_server

// The handler is now trivial: the CORE enforces the size limits before the
// handler ever runs — over-large bodies are rejected (413) from Content-Length
// WITHOUT buffering them, and oversized header blocks get 431. That's the whole
// point: limits belong in the read loop, not bolted onto each handler.
fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: handle
		limits:          http_server.Limits{
			max_body_bytes:   10 * 1024 * 1024 // 10 MiB -> 413
			max_header_bytes: 16 * 1024        // 16 KiB  -> 431
			max_connections:  100_000          // refuse past this many concurrent
			read_timeout_ms:  5_000            // finish the request within 5s or get 408
			write_timeout_ms: 10_000           // drain a parked response within 10s or be dropped
		}
	})!
	println('Request-limits demo — core enforces max body/header/connections (see file header).')
	server.run()
}
