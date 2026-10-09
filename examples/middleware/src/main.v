module main

// Middleware — reference design (the recommended pattern, consolidated).
//
// How cross-cutting concerns compose on vanilla WITHOUT a framework. Two shapes,
// each in its own file:
//
//   chain.v        the composition primitive (Handler/Middleware + chain())
//   decorators.v   GLOBAL middleware: `fn (next) fn` wrappers (security headers)
//                  + the single-allocation inject_headers
//   access_log.v   GLOBAL middleware: a buffered, zero-alloc, no-reparse access
//                  log written to a file (efficient under the worker model)
//   auth.v         PER-ROUTE guards (Pattern A): require_auth / require_role
//   controllers.v  the router + controllers; each declares its own auth policy
//
// Invariant 2 (zero abstraction) holds: no middleware registry, no DI, no
// dynamic dispatch. The handler contract stays bytes-in/bytes-out.
//
// WORKS TODAY.
import server
import os

fn main() {
	// Open the access log once; the pointer is shared across all workers.
	log := new_access_log('access.log') or {
		eprintln('cannot open access log: ${err}')
		return
	}

	// One wrap, every response: security headers + access log on the whole app.
	// Per-route auth lives INSIDE the controllers (Pattern A), so each route
	// declares its own policy explicitly.
	handler := chain(route, with_security_headers, access_log_mw(log))

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
		handler:         handler
	})!

	// The access log is buffered for throughput, so flush on shutdown or the
	// tail is lost. Not inside the signal handler: it runs in async-signal
	// context, on whichever thread the kernel interrupts, possibly a worker in
	// the middle of an fwrite to this very log, and neither fflush nor exit is
	// async-signal-safe. The handler only write(2)s a byte to a pipe; the
	// spawned thread drains, flushes and exits in normal context.
	wake := os.pipe()!
	on_signal := fn [wake] (_ os.Signal) {
		saved := C.errno
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.int, on_signal)!
	os.signal_opt(.term, on_signal)!
	spawn fn [srv, log, wake] () {
		os.fd_read(wake.read_fd, 1) // blocks until SIGINT / SIGTERM
		srv.shutdown(2000) // stop accepting, let in-flight requests log
		log.flush()
		exit(0)
	}()

	println('Middleware demo on http://localhost:3000/  (access log -> ./access.log)')
	println('  GET /        public  -> 200')
	println('  GET /me      private -> 401 without "Authorization: Bearer tok-alice"')
	println('  GET /admin   admin   -> 403 for tok-alice, 200 for tok-root')
	srv.run()
}
