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
import http_server
import http_server.http1_1.request_parser
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
// connection open.
const sse_headers = ('HTTP/1.1 200 OK\r\n' + 'Content-Type: text/event-stream\r\n' +
	'Cache-Control: no-cache\r\n' + 'Connection: keep-alive\r\n' +
	'Access-Control-Allow-Origin: *\r\n' + '\r\n').bytes()

const ok_response = ('HTTP/1.1 200 OK\r\n' + 'Content-Length: 0\r\n' +
	'Connection: keep-alive\r\n' + '\r\n').bytes()

const bad_request = ('HTTP/1.1 400 Bad Request\r\n' + 'Content-Length: 0\r\n' +
	'Connection: close\r\n' + '\r\n').bytes()

fn handle(req_buffer []u8, fd int, mut clients Clients) ![]u8 {
	// The kernel recycles fd numbers: a NEW request arriving on an fd that is
	// still in the subscriber set means that subscription is stale — the old
	// stream's connection was closed by the core and its number reused. Drop
	// it first, or a broadcast would be written into THIS request's response.
	// (A real subscriber never sends a second request on its SSE connection.)
	clients.drop(fd)

	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	path := req.path.to_string(req.buffer)

	// GET /events  — subscribe. Register the fd; the core sends the headers
	//                and leaves the connection open. The broadcaster owns it now.
	if method == 'GET' && path == '/events' {
		clients.add(fd)
		return sse_headers
	}

	// POST /broadcast — fan a message out to every subscriber, right now.
	if method == 'POST' && path == '/broadcast' {
		body := req.body.to_string(req.buffer)
		clients.broadcast('data: ${body}\n\n'.bytes())
		return ok_response
	}

	return bad_request
}

fn main() {
	mut clients := &Clients{}

	// ONE heartbeat thread for ALL clients (not one per client). Periodic
	// comments keep intermediaries from idling the connections closed.
	spawn fn [mut clients] () {
		for {
			time.sleep(15 * time.second)
			clients.broadcast(': keepalive\n\n'.bytes())
		}
	}()

	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: fn [mut clients] (req_buffer []u8, fd int) ![]u8 {
			return handle(req_buffer, fd, mut clients)
		}
	})!
	println('SSE server on http://localhost:3000/  (GET /events, POST /broadcast)')
	server.run()
}
