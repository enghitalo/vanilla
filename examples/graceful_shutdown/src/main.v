module main

// Graceful shutdown — now WORKING via Server.shutdown().
//
// On SIGTERM/SIGINT (what `docker stop` / k8s send) the server must not drop
// in-flight requests. The signal handler calls `server.shutdown(grace_ms)`,
// which:
//   1. closes the listening socket -> the kernel refuses NEW connections;
//   2. waits grace_ms for in-flight request handling to finish;
// then we exit(0). Idle keep-alive connections are dropped (they hold no
// in-flight work). Without this, rolling deploys / autoscaling / spot
// reclamation emit a burst of 502s; with it, deploys are invisible to users.
//
// The drain is PRECISE: shutdown sums per-worker in-flight counters and returns
// the instant the last request finishes (so an idle server exits in ~ms, not the
// full 2s grace; the grace is just the cap). The counters are per-worker and
// cache-line-padded, so the per-request increment is free on the hot path.
import http_server
import http_server.core
import os

fn handle(_req_bufferreq_buffer []u8, mut out []u8, _client_fdclient_fd int, _worker_stateworker_state voidptr, mut _event_loopevent_loop core.EventLoop) core.Step {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
	return .done
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
		handler:         handle
	})!

	// Stop accepting, drain briefly, exit cleanly. (Captures `server` by value —
	// shutdown only needs the listener fd.)
	os.signal_opt(.term, fn [server] (_ os.Signal) {
		eprintln('SIGTERM: stop accepting, draining (2s), exiting...')
		server.shutdown(2000)
		exit(0)
	}) or {}
	os.signal_opt(.int, fn [server] (_ os.Signal) {
		eprintln('SIGINT: stop accepting, draining (2s), exiting...')
		server.shutdown(2000)
		exit(0)
	}) or {}

	println('Graceful-shutdown demo on http://localhost:3000/  (send SIGTERM to drain & exit)')
	server.run()
}
