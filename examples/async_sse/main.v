module main

// Async-runtime example: Server-Sent Events (SSE), the canonical user of
// flush-on-suspend. One periodic `timerfd` drives the stream; each time it fires
// the continuation appends ONE `data:` event and re-arms — and because a
// continuation that wrote bytes before returning `.suspend` has them flushed
// immediately (not buffered until `.done`), the client receives each event the
// instant it is produced. The single worker keeps serving everyone else between
// ticks, so thousands of open streams cost ~one timerfd + a small struct each,
// not a thread each.
//
// Run:   v run examples/async_sse/
// Try:   curl -N http://localhost:8092/events
//        # -> data: tick 1 of 5   (one line per second, then "bye")
//
// The same append-flush-suspend loop is how a chat feed, a progress stream, or a
// log tail would push to many clients from one thread. See core.Handler.
import server
import core

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// Stream is the per-connection cursor, carried across ticks via watch_payload — ONE
// heap allocation for the whole stream, freed when it ends (not per event).
struct Stream {
mut:
	tfd  int // the periodic timerfd this stream is parked on
	sent int // events emitted so far
	max  int // stop (and close) after this many
}

const sse_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// arm_periodic programs a timerfd to fire every `ms` (it_value = it_interval).
fn arm_periodic(tfd int, ms int) {
	// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
	mut spec := [4]i64{}
	spec[0] = i64(ms / 1000)
	spec[1] = i64(ms % 1000) * 1_000_000
	spec[2] = spec[0]
	spec[3] = spec[1]
	C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !req.bytestr().contains('/events') {
		out << not_found
		return .done
	}
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 1000) // one event per second
	st := &Stream{
		tfd:  tfd
		sent: 0
		max:  5
	}
	// Headers go out NOW: async_serve flushes the write buffer after the initial
	// .suspend, so the client sees `200 text/event-stream` before any tick.
	out << sse_headers
	event_loop.watch_fd(tfd, .readable, sse_tick, voidptr(st))
	return .suspend
}

// sse_tick fires once per timer expiry: emit one event and re-arm. The appended
// bytes are flushed on .suspend (the streaming primitive), so each event ships
// immediately instead of waiting for the stream to finish.
fn sse_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // drain the timerfd expiry count
	mut st := unsafe { &Stream(watch_payload) }
	st.sent++
	out << 'data: tick ${st.sent} of ${st.max}\n\n'.bytes()
	if st.sent >= st.max {
		out << 'data: bye\n\n'.bytes()
		C.close(st.tfd) // request owns the timerfd; closing it removes it from epoll
		return .done
	}
	event_loop.watch_fd(st.tfd, .readable, sse_tick, watch_payload) // keep streaming
	return .suspend
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8092
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
