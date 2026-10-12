module main

// Server-Sent Events from a timer, over server push (vanilla#230): `/events`
// streams five `data:` events, one per second, then `data: bye`.
//
// The stream is a subscribed connection. `handle` appends the head, hands the
// connection to drain_conn (core.queue_takeover: what the client sends from
// now on is not HTTP), subscribes it (event_loop.subscribe) and arms its timer
// (event_loop.wake_after). Each time the timer fires, sse_tick appends ONE
// event to the connection's write buffer, which goes out at once, and re-arms.
// The connection is never parked: it does not hold Server.shutdown(grace),
// and on .shutdown the stream ends early, with its `bye`. Each worker keeps
// serving everyone else between ticks, so thousands of open streams cost a
// timer each in the worker's heap: no thread, no fd, no allocation.
//
// This stream is finite, so the client must be able to see where it ends.
// Each event goes out as one HTTP chunk (`Transfer-Encoding: chunked`), and a
// zero-size chunk ends the body (RFC 9112 §7.1). A taken-over connection does
// not go back to HTTP/1.1, so the connection then closes, as the head's
// `Connection: close` says.
//
// Run:   v -prod run examples/async_sse/
//        (-prod: a tcc build, V's default without it, leaves the takeover
//        inert and /events answers 501)
// Try:   curl -N http://localhost:8092/events
//        # -> data: tick 1 of 5   (one line per second, then "bye")
//
// The same subscribe-and-tick loop is how a progress stream or a log tail
// would push to many clients from one thread; examples/sse adds events
// posted from other workers.
import server
import core
import strconv
import http1_1.request_parser
import http1_1.response

// max_events ends the stream after this many ticks, tick_ms apart.
const max_events = 5

const tick_ms = 1000

const sse_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n'

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// 501: this server cannot keep a stream (no takeover or no subscriptions here).
const not_implemented = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

// The literal parts of one `data: tick N of M\n\n` event.
const tick_head = 'data: tick '

const tick_of = ' of '

const event_end = '\n\n'

// The last event as one chunk (`data: bye\n\n` is 0xb bytes), then the
// zero-size chunk that ends the body.
const bye_and_end = 'b\r\ndata: bye\n\n\r\n0\r\n\r\n'

const hex_digits = '0123456789abcdef'

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
	if !core.queue_takeover(drain_conn, unsafe { nil }) {
		core.append_str(mut out, not_implemented)
		return .close
	}
	// The stream's only state is the number of events sent, carried in the
	// subscription's state itself (none yet): nothing is allocated per stream.
	if event_loop.subscribe(sse_tick, unsafe { nil }).is_nil() {
		// Taken over but not subscribed: nothing could ever tick. The takeover
		// queued above is dropped with this .close.
		core.append_str(mut out, not_implemented)
		return .close
	}
	event_loop.wake_after(tick_ms)
	// The head goes out NOW, with the response: the client sees
	// `200 text/event-stream` before any tick.
	core.append_str(mut out, sse_headers)
	return .done
}

// drain_conn is the stream's ConnHandler: the client has nothing more to say
// after GET /events, so what it sends is dropped. Its EOF closes the
// connection, and its timer goes with it.
fn drain_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	return buf.len, core.Step.done
}

// sse_tick is the stream's wake fn. On each timer expiry (.timeout) it
// appends ONE event as a chunk, which goes out at once, and re-arms the
// timer; the last tick ends the body and closes. On .shutdown the stream ends
// early, with its `bye`. watch_payload is the number of events sent so far
// (an integer, not a pointer); re-subscribing stores the new count (it
// replaces the subscription's state, same handle).
fn sse_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	match event_loop.reason() {
		.timeout {}
		.shutdown {
			core.append_str(mut out, bye_and_end)
			return .close
		}
		else {
			return .done // .closed: nothing to free
		}
	}
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
		return .close // the body is complete; it goes out, then the connection closes
	}
	event_loop.subscribe(sse_tick, voidptr(usize(sent)))
	event_loop.wake_after(tick_ms) // keep streaming
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8092
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
