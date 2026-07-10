module main

// The composition primitive. A middleware is a function that wraps a handler;
// chain() folds a list of them into one, ONCE at startup. No registry, no DI,
// no per-request dispatch — Invariant 2 (zero abstraction).
import http_server.core

// Handler is the frozen core contract: bytes in (+ worker), response bytes
// APPENDED to `out`, next Step returned.
type Handler = fn (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step

// Middleware takes the next handler and returns a wrapping handler.
type Middleware = fn (Handler) Handler

// chain composes middlewares around a handler. The FIRST listed is the
// OUTERMOST: it runs first on the request and last on the response.
//
//   handler := chain(route, with_security_headers, with_access_log)
//   // request flow:  security -> log -> route
//   // response flow: route -> log -> security
fn chain(handler Handler, middlewares ...Middleware) Handler {
	mut h := handler
	for i := middlewares.len - 1; i >= 0; i-- {
		h = middlewares[i](h)
	}
	return h
}
