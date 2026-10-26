module main

// Server-Sent Events over server push (vanilla#230): `GET /events`
// subscribes, `POST /broadcast` sends its body to every subscriber as one
// `data:` event, and every subscriber gets a `: keepalive` comment every
// heartbeat.
//
// A subscriber stays the server's connection. `GET /events` appends the SSE
// head, hands the connection to drain_conn (core.queue_takeover: what the
// client sends from now on is not HTTP) and subscribes it
// (event_loop.subscribe). Its handle (core.ConnHandle) goes into the hub, the
// one registry of subscribers. Then, on the subscriber's own worker, between
// its other work, sse_wake gets:
//
//   - .posted: a broadcast, handled on any worker, posted its body to every
//     handle (post_bytes); sse_wake appends the `data:` event to the
//     connection's write buffer, behind whatever went out before it;
//   - .timeout: the heartbeat, a wake_after timer re-armed on every tick;
//   - .shutdown: Server.shutdown() was called, and the stream ends, so it
//     does not hold the shutdown drain;
//   - .closed, last, however the connection went: the hub forgets it. A
//     handle carries its connection's generation, so a post that races the
//     close is dropped on the worker, never delivered to the connection that
//     reuses the fd number (#232).
//
// No thread per client or per heartbeat, and no thread writes to a socket it
// does not own: each connection is written by its worker only, with the same
// backpressure as every response. A subscriber costs a hub entry and its
// connection; nothing is allocated per event or per heartbeat.
//
// Takeover and push run on the Linux epoll worker, built with gcc or clang
// (`v -prod`). Elsewhere (kqueue, IOCP, a tcc build) `GET /events` answers
// 501 Not Implemented.
import core
import http1_1.request_parser
import server
import sync
import sync.stdatomic

// SSE response head: note the deliberate ABSENCE of Content-Length and the
// text/event-stream content type. The stream is the rest of the connection.
const sse_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n'

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const too_large = 'HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// 501: this server cannot keep a stream (no takeover or no subscriptions here).
const not_implemented = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const keepalive_event = ': keepalive\n\n'

const data_prefix = 'data: '

const data_next = '\ndata: '

const event_end = '\n\n'

// max_event is the largest body POST /broadcast takes: what one mailbox slot
// carries inline (post_bytes reports .too_big past it). A larger event would
// stay in the app's store, with its tag posted instead.
const max_event = 240

// Hub is the subscribers, by handle: the only shared state. Every worker
// reaches it through its make_state value (the same &Hub on each). Its lock is
// taken once per subscribe, departure and broadcast, never per event
// delivered or per heartbeat.
@[heap]
struct Hub {
	heartbeat_ms int
mut:
	mu      &sync.Mutex = sync.new_mutex()
	subs    []Sub
	next_id u64 // atomic: the last subscriber id given
}

struct Sub {
	id     u64
	handle core.ConnHandle
}

fn new_hub(heartbeat_ms int) &Hub {
	return &Hub{
		heartbeat_ms: heartbeat_ms
	}
}

// new_id is a fresh subscriber id (from 1): the subscription's sub_state.
fn (mut hub Hub) new_id() u64 {
	return stdatomic.add_u64(&hub.next_id, 1)
}

fn (mut hub Hub) add(id u64, handle core.ConnHandle) {
	hub.mu.lock()
	hub.subs << Sub{
		id:     id
		handle: handle
	}
	hub.mu.unlock()
}

fn (mut hub Hub) leave(id u64) {
	hub.mu.lock()
	for i in 0 .. hub.subs.len {
		if hub.subs[i].id == id {
			hub.subs[i] = hub.subs[hub.subs.len - 1]
			hub.subs.delete_last()
			break
		}
	}
	hub.mu.unlock()
}

fn (mut hub Hub) size() int {
	hub.mu.lock()
	n := hub.subs.len
	hub.mu.unlock()
	return n
}

// broadcast posts one event to every subscriber. It never blocks: a subscriber
// whose worker's mailbox is full misses the event (a real app would keep a
// backlog in its store and post a tag).
fn (mut hub Hub) broadcast(event []u8) {
	hub.mu.lock()
	for s in hub.subs {
		s.handle.post_bytes(0, event)
	}
	hub.mu.unlock()
}

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		core.append_str(mut out, bad_request)
		return .close
	}
	mut hub := unsafe { &Hub(worker_state) }
	if slice_eq(req_buffer, req.method, 'GET') && slice_eq(req_buffer, req.path, '/events') {
		return subscribe(mut hub, mut out, mut event_loop)
	}
	// POST /broadcast: the body goes to every subscriber, straight out of the
	// request buffer (post_bytes copies it into each mailbox slot).
	if slice_eq(req_buffer, req.method, 'POST') && slice_eq(req_buffer, req.path, '/broadcast') {
		if req.body.len > max_event {
			core.append_str(mut out, too_large)
			return .done
		}
		mut body := []u8{}
		if req.body.len > 0 { // guard: &buf[start] is out of bounds on an empty slice
			body = unsafe { (&req_buffer[req.body.start]).vbytes(req.body.len) }
		}
		hub.broadcast(body) // an empty body still yields the valid event `data: \n\n`
		core.append_str(mut out, ok_response)
		return .done
	}
	core.append_str(mut out, bad_request)
	return .done
}

// subscribe answers GET /events: the SSE head, and the connection is a
// subscriber from now on (see the top of this file).
fn subscribe(mut hub Hub, mut out []u8, mut event_loop core.EventLoop) core.Step {
	if !core.queue_takeover(drain_conn, unsafe { nil }) {
		core.append_str(mut out, not_implemented)
		return .close
	}
	id := hub.new_id()
	handle := event_loop.subscribe(sse_wake, voidptr(u64(id)))
	if handle.is_nil() {
		// Taken over but not subscribed: nothing could ever reach it. The
		// takeover queued above is dropped with this .close.
		core.append_str(mut out, not_implemented)
		return .close
	}
	hub.add(id, handle)
	event_loop.wake_after(hub.heartbeat_ms)
	core.append_str(mut out, sse_head)
	return .done
}

// drain_conn is a subscriber's ConnHandler: a subscriber has nothing more to
// say after GET /events, so what it sends is dropped (a request pipelined
// behind the subscribe too: it subscribes once). Its EOF closes the
// connection, and sse_wake gets .closed.
fn drain_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	return buf.len, core.Step.done
}

// sse_wake is a subscriber's wake fn (see the top of this file).
// watch_payload is its hub id, worker_state the hub.
fn sse_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut hub := unsafe { &Hub(worker_state) }
	match event_loop.reason() {
		.posted {
			append_event(mut out, event_loop.post_data())
		}
		.timeout {
			core.append_str(mut out, keepalive_event)
			event_loop.wake_after(hub.heartbeat_ms)
		}
		.shutdown {
			return .close // the stream ends here; an EventSource reconnects later
		}
		.closed {
			hub.leave(u64(u64(watch_payload)))
		}
		else {}
	}
	return .done
}

// append_event frames `data` as one SSE event: a `data: ` line for each of its
// lines (a CR, LF or CRLF in it starts the next one, so a body can neither end
// the event early nor add a field of its own), then the blank line that ends
// it.
@[direct_array_access]
fn append_event(mut out []u8, data []u8) {
	core.append_str(mut out, data_prefix)
	mut start := 0
	for i := 0; i < data.len; i++ {
		c := data[i]
		if c != `\r` && c != `\n` {
			continue
		}
		if i > start {
			unsafe { out.push_many(&data[start], i - start) }
		}
		if c == `\r` && i + 1 < data.len && data[i + 1] == `\n` {
			i++
		}
		core.append_str(mut out, data_next)
		start = i + 1
	}
	if data.len > start {
		unsafe { out.push_many(&data[start], data.len - start) }
	}
	core.append_str(mut out, event_end)
}

// new_config is the server's config: the hub reaches every worker through
// make_state. `workers` 0 = one per CPU.
fn new_config(port int, workers int, hub &Hub) server.ServerConfig {
	return server.ServerConfig{
		port:               port
		io_multiplexing:    default_backend()
		handler:            handle
		workers:            workers
		push_mailbox_slots: 4096
		make_state:         fn [hub] () voidptr {
			return voidptr(hub)
		}
	}
}

// default_backend selects the backend per OS explicitly (other OSes keep the
// default, 0).
fn default_backend() server.IOBackend {
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	return backend
}

fn main() {
	mut srv := server.new_server(new_config(3000, 0, new_hub(15_000)))!
	println('SSE server on http://localhost:3000/  (GET /events, POST /broadcast)')
	srv.run()
}
