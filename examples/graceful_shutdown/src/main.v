module main

// Graceful shutdown — now WORKING via Server.shutdown().
//
// On SIGTERM/SIGINT (what `docker stop` / k8s send) the server must not drop
// in-flight requests. A normal thread, woken by the signal, calls
// `srv.shutdown(grace_ms)`, which:
//   1. closes the listening socket -> the kernel refuses NEW connections;
//   2. waits grace_ms for in-flight request handling to finish;
// then we exit(0). Idle keep-alive connections are dropped (they hold no
// in-flight work). Without this, rolling deploys / autoscaling / spot
// reclamation emit a burst of 502s; with it, deploys are invisible to users.
//
// The signal handler itself does NOT call shutdown() or exit(). It runs in
// async-signal context, on whichever thread the kernel interrupts (possibly a
// worker), where only async-signal-safe calls are allowed: exit() runs atexit
// handlers and flushes stdio (it can deadlock on a lock the interrupted thread
// holds), and a worker spinning in shutdown() could not finish its own
// request. So the handler only write(2)s one byte to a pipe, and a spawned
// thread blocked on that pipe does the drain and the exit in normal context.
//
// The drain is PRECISE: shutdown sums per-worker in-flight counters and returns
// the instant the last request finishes (so an idle server exits in ~ms, not the
// full 2s grace; the grace is just the cap). The counters are per-worker and
// cache-line-padded, so the per-request increment is free on the hot path.
import server
import core
import os

// A static response is a const string, appended with core.append_str: no
// per-request copy (docs/BEST_PRACTICES.md §3a).
const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

fn handle(_req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	core.append_str(mut out, ok_response)
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
	})!

	// Signal handler: async-signal-safe work only, one write(2) to a pipe.
	// (write may set errno; restore it for the code the signal interrupted.)
	wake := os.pipe()!
	on_signal := fn [wake] (_ os.Signal) {
		saved := C.errno
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.term, on_signal)!
	os.signal_opt(.int, on_signal)!

	// Normal thread: wait for the byte, then stop accepting, drain briefly and
	// exit cleanly. (Captures `srv` by value — shutdown only needs the listener
	// fds and the shared in-flight counters.)
	spawn fn [srv, wake] () {
		os.fd_read(wake.read_fd, 1) // blocks until SIGTERM / SIGINT
		eprintln('signal received: stop accepting, draining (2s), exiting...')
		srv.shutdown(2000)
		exit(0)
	}()

	println('Graceful-shutdown demo on http://localhost:3000/  (send SIGTERM to drain & exit)')
	srv.run()
}
