module core

// V interface to the per-thread connection-takeover hand-off slot (see
// takeover_slot.h) — the conn-mode seam of issue #136.
//
// This is how "one engine, N protocols" happens without the engine importing
// any protocol: a request handler that decides the connection now speaks a
// different protocol (RFC 6455 `Upgrade: websocket` today, the http2 preface
// later) appends its switching response (the 101), queues a ConnHandler here,
// and returns .done. The worker sends the response and flips the connection's
// mode; from then on every readable burst is fed to the ConnHandler instead
// of the HTTP/1.1 state machine. Only a takeover-capable worker (the epoll
// plain worker) calls enable_takeover(); everywhere else queue_takeover()
// returns false and the handler must answer an error instead of upgrading.

#include "@VMODROOT/core/takeover_slot.h"

fn C.vanilla_to_enable()
fn C.vanilla_to_queue(cont voidptr, state voidptr) bool
fn C.vanilla_to_take(out_cont &voidptr, out_state &voidptr) bool

// ConnHandler drives a taken-over connection: it runs on every readable burst,
// consumes complete protocol frames from `buf` (a view of the connection's
// read buffer — copy anything that must outlive the call) and appends response
// bytes to `out` (the same persistent, batch-flushed write buffer handlers
// use). It returns how many bytes of `buf` it consumed plus the next Step:
//
//   .done    — keep the connection open and wait for more bytes
//   .suspend — park the connection on the fd just armed via
//              event_loop.watch_fd(...): the registered continuation (a
//              core.WakeFn, same contract as an h1 park) resumes it when the
//              fd fires — appending protocol bytes to the SAME write buffer —
//              and its .done hands the socket back to the takeover drain.
//              While parked the engine reads nothing from the client (bytes
//              wait in the socket, mirroring a parked h1 request) and at most
//              ONE watch may be armed per connection (the close-path teardown
//              tracks exactly one fd). Suspending WITHOUT arming a watch
//              closes the connection — nothing would ever resume it.
//   .close   — flush whatever is in `out`, then close the connection
//
// A partial frame is expressed by consuming fewer bytes than `buf.len` (or 0):
// the engine keeps the tail buffered, compacts it to the front, and calls
// again when more bytes arrive. Consuming nothing while returning .done on a
// full buffer would spin the connection — the engine closes it if the buffer
// can no longer grow.
//
//   takeover_state — the value passed to queue_takeover (per-connection
//                    protocol state, e.g. fragmentation reassembly); the
//                    engine never inspects or frees it
//   worker_state   — this worker thread's make_state value (nil if unset)
pub type ConnHandler = fn (buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop EventLoop) (int, Step)

// QueuedTakeover is the (handler, state) pair a request handler queued for the
// connection whose request was just handled.
pub struct QueuedTakeover {
pub:
	cont  ConnHandler = unsafe { nil }
	state voidptr
}

// enable_takeover marks the calling worker thread as able to flip a
// connection's mode. Call once per capable worker (the epoll plain worker).
@[inline]
pub fn enable_takeover() {
	C.vanilla_to_enable()
}

// queue_takeover hands the current connection over to `cont`: after the
// handler returns .done, the worker sends whatever the handler appended (the
// switching response) and routes every subsequent readable burst on this
// connection to `cont`. Returns false when the running backend cannot take
// connections over (not the epoll plain worker, or a tcc dev build) — the
// caller MUST then answer an error (e.g. 501) instead of upgrading, because
// the peer would otherwise speak a protocol nobody parses.
@[inline]
pub fn queue_takeover(cont ConnHandler, takeover_state voidptr) bool {
	return C.vanilla_to_queue(voidptr(cont), takeover_state)
}

// take_queued_takeover returns the takeover a handler queued during the
// request just handled, or none. Always clears the slot, so it never leaks
// into the next request.
@[inline]
pub fn take_queued_takeover() ?QueuedTakeover {
	mut cont := unsafe { nil }
	mut state := unsafe { nil }
	if C.vanilla_to_take(&cont, &state) {
		return QueuedTakeover{
			cont:  unsafe { ConnHandler(cont) }
			state: state
		}
	}
	return none
}
