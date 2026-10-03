module main

// The fastest way to route in vanilla: the router is the core.Handler itself,
// written as `match` statements over the path's segments (routes.v), with the
// `router` module reading the method and path straight from the request line.
// Nothing is registered, looked up or allocated at runtime, and no header is
// parsed to route; each branch is plain code the compilers see whole, and
// params are typed locals.
//
// The app owns every response: its 404 when no route matches the path (a
// malformed request line, `*` and absolute-form included), a 405 + Allow per
// leaf (an unknown method gets it too), HEAD answered by the GET branches.
// Same routes as examples/veb_like (the declarative alternative), plus
// JSON-escaped URL values, Limits and graceful shutdown.
import server
import os

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
		handler:         route
		// Production limits: bound resource use so a single client can't exhaust
		// the server (see examples/veb_like for the reasoning behind each).
		limits:          server.Limits{
			max_header_bytes: 16 * 1024   // 16 KiB headers  -> 431
			max_body_bytes:   1024 * 1024 // 1 MiB body     -> 413 (from Content-Length)
			max_connections:  100_000     // refuse past this many concurrent
			read_timeout_ms:  10_000      // finish the request within 10s of accept / its first byte (408 if partial)
			write_timeout_ms: 30_000      // drain a parked response within 30s
			idle_timeout_ms:  75_000      // keep-alive wait for the next request; longer than a load balancer's usual 60s
		}
	})!

	// Graceful shutdown: SIGTERM/SIGINT stop new accepts and drain in-flight
	// requests. The signal handler only write(2)s a byte to a pipe (it runs in
	// async-signal context); the spawned thread shuts down in normal context.
	wake := os.pipe()!
	on_signal := fn [wake] (_ os.Signal) {
		saved := C.errno
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.term, on_signal)!
	os.signal_opt(.int, on_signal)!
	spawn fn [srv, wake] () {
		os.fd_read(wake.read_fd, 1) // blocks until SIGTERM / SIGINT
		srv.shutdown(2000)
		exit(0)
	}()

	println('router example on http://localhost:3000/')
	srv.run()
}
