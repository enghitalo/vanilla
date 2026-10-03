module main

// The fastest way to route in vanilla: the router is the core.Handler itself,
// written as `match` statements over the path's segments (routes.v), with the
// `router` module's zero-copy cursor and method enum. Nothing is registered,
// looked up or allocated at runtime; each branch is plain code the compilers
// see whole, and params are typed locals.
//
// Same routes, same responses, same production properties as
// examples/veb_like (the declarative alternative): 400 + close for a request
// the parser rejects, 404 vs 405 + Allow, HEAD served by GET, 501 for unknown
// methods, JSON-escaped URL values, Limits, graceful shutdown.
import server
import core
import http1_1.request_parser { HttpRequest }
import os
import router

// handle is the server's core.Handler: parse, then walk the route tree.
fn handle(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut req := HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << router.bad_request
		return .close
	}
	m := router.method(req)
	if m == .unknown {
		out << router.not_implemented
		return .done
	}
	mut path := router.path(req) or {
		out << router.not_found // `*` or absolute-form: nothing here routes those
		return .done
	}
	start := out.len
	step := route(m, mut path, mut out, mut event_loop)
	if m == .head && step != .suspend {
		router.drop_body(mut out, start)
	}
	return step
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
