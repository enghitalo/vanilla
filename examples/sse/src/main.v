module main

// Server-Sent Events — reference design.
//
// WHAT WAS WRONG BEFORE
//   The previous version did `spawn sse_handler(fd)` per connection, and each
//   handler sat in an infinite `time.sleep` loop "to keep the thread alive".
//   That is one OS thread parked forever per connected client: 10k SSE clients
//   become 10k blocked threads. It directly contradicts the thread-per-core,
//   non-blocking core this server is built on.
//
// THE PURE DESIGN
//   A client is just a connection. We never spawn anything per client. On
//   `GET /events` the registry takes the connection over through its own
//   dup() (see Clients.add: never the core's fd number, which the kernel
//   reuses), and we return the SSE headers with .close: the core sends them
//   and lets go of its own fd, the stream stays open through the dup. From
//   then on a SINGLE broadcaster writes events to every subscriber. Cost per
//   client: one fd + one map entry. No thread waits on a client: every send
//   is non-blocking, and the lock only serializes broadcasts and subscribes.
//
// This is the shape SSE should always take on top of a non-blocking core.
import server
import core
import http1_1.request_parser
import sync
import time

fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.dup(fd int) int
fn C.close(fd int) int
fn C.shutdown(fd int, how int) int

// msg_nosignal returns MSG_NOSIGNAL on Linux: never raise SIGPIPE when a peer
// has gone away — we detect the dead client from send()'s return value and
// drop it instead. macOS has no such send() flag; SIGPIPE is suppressed
// per-socket via SO_NOSIGPIPE, set at accept.
@[inline]
fn msg_nosignal() int {
	$if linux {
		return 0x4000
	}
	return 0
}

// The only shared state: the subscribers, keyed by the registry's OWN
// descriptor for each connection, never by the core's fd number (see add).
struct Clients {
mut:
	mu  &sync.Mutex = sync.new_mutex() // exclusive: a registry fd is only closed under it
	fds map[int]bool
}

// add registers the subscriber on connection `fd` under a dup() of it, and
// handle() then returns .close: the core flushes the SSE head and closes
// `fd`, so the registry's descriptor is the connection's only one. Never key
// by `fd`: the kernel gives a closed number to the next accepted connection,
// which never subscribed, and it would get every later event and heartbeat
// (#232). The dup keeps the socket open, so its number cannot be reused while
// it is in the map, and only the registry closes it. The core closes `fd`
// with a plain close() after EPOLL_CTL_DEL (kqueue: EV_DELETE), so the dup
// leaves no stale registration behind. And the core never reads the
// connection again: a client that pipelines more requests behind
// `GET /events` subscribes once, not once per request. false: no descriptor
// to spare (EMFILE).
//
// Windows has no dup() for a SOCKET: there the registry keys the core's
// handle and the core keeps the connection (.done). Every request on a
// handle drops it first (drop), but a handle the system reuses can still
// receive a departed subscriber's events until it sends one (README).
fn (mut c Clients) add(fd int) bool {
	mut own := fd
	$if !windows {
		own = C.dup(fd)
		if own < 0 {
			return false
		}
	}
	c.mu.lock()
	c.fds[own] = true
	c.mu.unlock()
	return true
}

// drop forgets the subscriber keyed by the core's handle `fd` (Windows, see
// add): a request on a handle means it is not, or no longer, a stream.
fn (mut c Clients) drop(fd int) {
	c.mu.lock()
	c.fds.delete(fd)
	c.mu.unlock()
}

fn (mut c Clients) snapshot() []int {
	c.mu.lock()
	fds := c.fds.keys()
	c.mu.unlock()
	return fds
}

// broadcast writes one pre-framed SSE event to every subscriber: one
// non-blocking send() each, no thread per client. The lock is held across the
// sends, so broadcasts run one at a time:
//   - a registry fd is closed only under the lock, so a concurrent broadcast
//     never sends to, or closes, a number a new add() was just given;
//   - two broadcasters never interleave partial writes in one socket.
// A send that does not take the whole event ends that stream: the peer is
// gone (EPIPE: the second send after it left, since TCP accepts the first),
// or its buffer is full (EAGAIN or a partial write; reliable buffering is
// #23). shutdown() ends it at once: the client reads EOF after whatever part
// of the event got through, and an EventSource discards an event cut short
// and reconnects.
fn (mut c Clients) broadcast(event []u8) {
	mut dead := []int{} // allocates only when a subscriber is dropped
	c.mu.lock()
	for fd, _ in c.fds {
		if C.send(fd, event.data, event.len, msg_nosignal()) != event.len {
			dead << fd
		}
	}
	for fd in dead {
		c.fds.delete(fd)
		$if !windows {
			C.shutdown(fd, C.SHUT_RDWR) // ENOTCONN once the peer is gone, harmless
			C.close(fd)
		}
	}
	c.mu.unlock()
}

// SSE response: note the deliberate ABSENCE of Content-Length and the
// text/event-stream content type. The core sends these bytes, and the
// connection stays open (through the registry's dup, see Clients.add). Single
// literals — no `+` concatenation, even at init.
const sse_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n'

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const unavailable = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

// Static SSE frame pieces. The heartbeat is sent as it is, so it stays a []u8;
// the two halves of a `data:` event are appended into `out` with
// core.append_str around the body.
const keepalive_event = ': keepalive\n\n'.bytes()

const data_prefix = 'data: '

const event_end = '\n\n'

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

fn handle(req_buffer []u8, fd int, mut out []u8, mut clients Clients) core.Step {
	$if windows {
		clients.drop(fd) // a stream never sends a request: see Clients.add
	}
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		core.append_str(mut out, bad_request)
		return .close
	}

	// GET /events  — subscribe. The registry takes the connection over; the
	//                core sends the headers and lets go of its fd (.close).
	//                The broadcaster writes to it from now on, through the
	//                registry's own descriptor.
	if slice_eq(req_buffer, req.method, 'GET') && slice_eq(req_buffer, req.path, '/events') {
		if !clients.add(fd) {
			core.append_str(mut out, unavailable)
			return .close
		}
		core.append_str(mut out, sse_headers)
		$if windows {
			return .done // the registry keys the core's handle: the core keeps it
		}
		return .close
	}

	// POST /broadcast — fan a message out to every subscriber, right now.
	if slice_eq(req_buffer, req.method, 'POST') && slice_eq(req_buffer, req.path, '/broadcast') {
		// Frame `data: <body>\n\n` once, contiguous, since C.send() takes one
		// buffer per call: at the end of `out`, the worker's own write buffer,
		// so it costs no allocation. broadcast() sends a view of it and keeps
		// nothing (it completes synchronously, before anything else touches
		// `out`), then `out` is rolled back to `mark` and the frame's bytes are
		// overwritten by this request's response. The body is never copied to
		// a string — push_many reads it straight out of the request buffer.
		mark := out.len
		core.append_str(mut out, data_prefix)
		if req.body.len > 0 { // guard: &buf[start] is out of bounds on an empty slice
			unsafe { out.push_many(&req_buffer[req.body.start], req.body.len) }
		}
		core.append_str(mut out, event_end) // an empty body still yields the valid event `data: \n\n`
		clients.broadcast(unsafe { (&out[mark]).vbytes(out.len - mark) })
		unsafe {
			out.len = mark
		}
		core.append_str(mut out, ok_response)
		return .done
	}

	core.append_str(mut out, bad_request)
	return .done
}

fn main() {
	mut clients := &Clients{}

	// ONE heartbeat thread for ALL clients (not one per client). Periodic
	// comments keep intermediaries from idling the connections closed.
	spawn fn [mut clients] () {
		for {
			time.sleep(15 * time.second)
			clients.broadcast(keepalive_event)
		}
	}()

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
		handler:         fn [mut clients] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, client_fd, mut out, mut clients)
		}
	})!
	println('SSE server on http://localhost:3000/  (GET /events, POST /broadcast)')
	srv.run()
}
