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
//   A client is just an fd that already lives in the server's epoll set. We
//   never spawn anything per client. On `GET /events` we return the SSE
//   headers (the core sends them and, being keep-alive, LEAVES the fd in
//   epoll). From then on a SINGLE broadcaster writes events to every fd.
//   Cost per client: one fd + one map entry. Nothing blocks.
//
// This is the shape SSE should always take on top of a non-blocking core.
import server
import core
import http1.request_parser
import sync
import time

fn C.send(fd int, buf voidptr, n usize, flags int) int

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

// The only shared state: the set of connected client fds.
struct Clients {
mut:
	mu  &sync.RwMutex = sync.new_rwmutex()
	fds map[int]bool
}

fn (mut c Clients) add(fd int) {
	c.mu.lock()
	c.fds[fd] = true
	c.mu.unlock()
}

fn (mut c Clients) drop(fd int) {
	c.mu.lock()
	c.fds.delete(fd)
	c.mu.unlock()
}

fn (mut c Clients) snapshot() []int {
	c.mu.rlock()
	fds := c.fds.keys()
	c.mu.runlock()
	return fds
}

// broadcast writes one pre-framed SSE event to every client in a single pass.
// A non-positive send() means the peer is gone, so we drop that fd. No thread
// per client, no blocking — just a loop over live descriptors.
fn (mut c Clients) broadcast(event []u8) {
	for fd in c.snapshot() {
		if C.send(fd, event.data, event.len, msg_nosignal()) <= 0 {
			c.drop(fd)
		}
	}
}

// SSE response: note the deliberate ABSENCE of Content-Length and the
// text/event-stream content type. The core sends these bytes and keeps the
// connection open. Single literals — no `+` concatenation, even at init.
const sse_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n'.bytes()

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

// Static SSE frame pieces: allocated once, reused for every event.
const keepalive_event = ': keepalive\n\n'.bytes()

const data_prefix = 'data: '.bytes()

const event_end = '\n\n'.bytes()

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
	// The kernel recycles fd numbers: a NEW request arriving on an fd that is
	// still in the subscriber set means that subscription is stale — the old
	// stream's connection was closed by the core and its number reused. Drop
	// it first, or a broadcast would be written into THIS request's response.
	// (A real subscriber never sends a second request on its SSE connection.)
	clients.drop(fd)

	req := request_parser.decode_http_request(req_buffer) or {
		out << bad_request
		return .close
	}

	// GET /events  — subscribe. Register the fd; the core sends the headers
	//                and leaves the connection open. The broadcaster owns it now.
	if slice_eq(req.buffer, req.method, 'GET') && slice_eq(req.buffer, req.path, '/events') {
		clients.add(fd)
		out << sse_headers
		return .done
	}

	// POST /broadcast — fan a message out to every subscriber, right now.
	if slice_eq(req.buffer, req.method, 'POST') && slice_eq(req.buffer, req.path, '/broadcast') {
		// Frame `data: <body>\n\n` once, into ONE contiguous buffer. This single
		// allocation is required: C.send() takes one buffer per call, so the
		// frame must be contiguous. The body itself is never copied to a string —
		// push_many reads it straight out of the request buffer, which is safe
		// because broadcast() completes synchronously inside handle(), before
		// the buffer is recycled. (This is the admin fan-out path, not the
		// subscriber hot path; a shared scratch buffer would need locking across
		// workers — rule 3 says don't.)
		mut event := []u8{cap: data_prefix.len + req.body.len + event_end.len}
		event << data_prefix
		if req.body.len > 0 { // guard: &buf[start] is out of bounds on an empty slice
			unsafe { event.push_many(&req.buffer[req.body.start], req.body.len) }
		}
		event << event_end // an empty body still yields the valid event `data: \n\n`
		clients.broadcast(event)
		out << ok_response
		return .done
	}

	out << bad_request
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
