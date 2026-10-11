module main

// Async-runtime example: Server-Sent Events (SSE), the canonical user of
// flush-on-suspend. One periodic `timerfd` drives the stream; each time it fires
// the continuation appends ONE `data:` event and re-arms — and because a
// continuation that wrote bytes before returning `.suspend` has them flushed
// immediately (not buffered until `.done`), the client receives each event the
// instant it is produced. The single worker keeps serving everyone else between
// ticks, so thousands of open streams cost one timerfd each, not a thread each.
//
// This stream is finite (5 ticks, then "bye"), so the client must be able to
// see where it ends. Each event goes out as one HTTP chunk
// (`Transfer-Encoding: chunked`), and a zero-size chunk ends the body
// (RFC 9112 §7.1). The connection then stays open for the client's next
// request. Without that framing the body would be close-delimited (§6.3): on a
// keep-alive connection it would never end, and the client would hang.
//
// Run:   v run examples/async_sse/
// Try:   curl -N http://localhost:8092/events
//        # -> data: tick 1 of 5   (one line per second, then "bye")
//
// The same append-flush-suspend loop is how a chat feed, a progress stream, or a
// log tail would push to many clients from one thread. See core.Handler.
import server
import core
import strconv
import http1_1.request_parser
import http1_1.response

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// max_events ends the stream after this many ticks.
const max_events = 5

const sse_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n'

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// The literal parts of one `data: tick N of M\n\n` event.
const tick_head = 'data: tick '

const tick_of = ' of '

const event_end = '\n\n'

// The last event as one chunk (`data: bye\n\n` is 0xb bytes), then the
// zero-size chunk that ends the body.
const bye_and_end = 'b\r\ndata: bye\n\n\r\n0\r\n\r\n'

const hex_digits = '0123456789abcdef'

// arm_periodic programs a timerfd to fire every `ms` (it_value = it_interval).
fn arm_periodic(tfd int, ms int) {
	// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
	mut spec := [4]i64{}
	spec[0] = i64(ms / 1000)
	spec[1] = i64(ms % 1000) * 1_000_000
	spec[2] = spec[0]
	spec[3] = spec[1]
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
}

// route_is reports whether the request path, without its query string, is
// `lit`. req.path includes the query, so the compare stops at the first `?`.
// It compares bytes in place: the request is never copied.
@[direct_array_access]
fn route_is(req request_parser.HttpRequest, lit string) bool {
	mut n := 0
	for n < req.path.len && req.buffer[req.path.start + n] != `?` {
		n++
	}
	if n != lit.len {
		return false
	}
	for i in 0 .. n {
		if req.buffer[req.path.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// wi appends the decimal digits of n (zero-alloc: itoa into a stack scratch).
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// wx appends n in lowercase hex without leading zeros: a chunk-size
// (RFC 9112 §7.1).
fn wx(mut out []u8, n int) {
	mut shift := 60
	for shift > 0 && (n >> shift) == 0 {
		shift -= 4
	}
	for shift >= 0 {
		out << hex_digits[(n >> shift) & 0xf]
		shift -= 4
	}
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if !route_is(r, '/events') {
		core.append_str(mut out, not_found)
		return .done
	}
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	arm_periodic(tfd, 1000) // one event per second
	// Headers go out NOW: async_serve flushes the write buffer after the initial
	// .suspend, so the client sees `200 text/event-stream` before any tick.
	core.append_str(mut out, sse_headers)
	// The stream's only state is the number of events sent, carried in
	// watch_payload itself (none yet): nothing is allocated per stream.
	event_loop.watch_fd(tfd, .readable, sse_tick, unsafe { nil })
	return .suspend
}

// sse_tick fires once per timer expiry: emit one event and re-arm. The appended
// bytes are flushed on .suspend (the streaming primitive), so each event ships
// immediately instead of waiting for the stream to finish. watch_payload is the
// number of events sent so far (an integer, not a pointer), and ready_fd is the
// stream's timerfd.
fn sse_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // drain the timerfd expiry count
	sent := int(usize(watch_payload)) + 1
	// One chunk: `<size in hex>\r\n<event>\r\n`. The size is the literal parts
	// plus the digits of the two counters.
	size := tick_head.len + strconv.dec_digits(u64(sent)) + tick_of.len +
		strconv.dec_digits(u64(max_events)) + event_end.len
	wx(mut out, size)
	core.append_str(mut out, '\r\n')
	core.append_str(mut out, tick_head)
	wi(mut out, sent)
	core.append_str(mut out, tick_of)
	wi(mut out, max_events)
	core.append_str(mut out, event_end)
	core.append_str(mut out, '\r\n')
	if sent >= max_events {
		core.append_str(mut out, bye_and_end)
		C.close(ready_fd) // request owns the timerfd; closing it removes it from epoll
		return .done // the body is complete; the connection stays open
	}
	event_loop.watch_fd(ready_fd, .readable, sse_tick, voidptr(usize(sent))) // keep streaming
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
