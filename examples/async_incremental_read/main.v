module main

// Async-runtime example: incremental read from a slow fd, forwarded as it
// arrives. A child process produces a few lines with pauses; we take the read
// end of its stdout pipe, watch it readable, and each time bytes show up we
// forward them as one HTTP chunk and re-arm — never blocking the worker while
// the producer sleeps. This is the reverse-proxy / `tail -f` shape: read what's
// available, stream it, wait for more.
//
// Run:   v run examples/async_incremental_read/
// Try:   curl -N http://localhost:8093/stream
//        # -> "line 1" ... "line 5", each ~200ms apart, chunk-encoded
//
// epoll only watches pollable fds (pipes/sockets), NOT regular files — a file
// reads as "always ready", so streaming one needs no async at all. The pipe here
// is the realistic case: the bytes genuinely arrive over time.
import server
import core
import http1_1.request_parser
import http1_1.response

#include <errno.h>
#include <unistd.h>
#flag @VMODROOT/examples/async_incremental_read/producer.c
#include "@VMODROOT/examples/async_incremental_read/producer.h"

fn C.spawn_producer(sh_path &char, script &char) int
fn C.read(fd int, buf voidptr, count u64) int

// producer is the child's shell loop: five lines, 200 ms apart.
const producer = c'for i in 1 2 3 4 5; do echo "line $i"; sleep 0.2; done'

const chunk_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n'

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// service_unavailable answers /stream when its producer cannot be started
// (no fd or no process left, say): the server failed, not the request.
const service_unavailable = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// last_chunk is the zero-size chunk that ends a chunked body (RFC 9112 §7.1).
const last_chunk = '0\r\n\r\n'

const hex_digits = '0123456789abcdef'

// read_max is the most one wake forwards as a chunk; size_line_max is the
// room its chunk-size line takes at most (`1000\r\n`).
const read_max = 4096

const size_line_max = 6

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
	if !route_is(r, '/stream') {
		core.append_str(mut out, not_found)
		return .done
	}
	// A producer whose output is spread over time — the whole point of streaming.
	// One process spawn per request, which allocates inside glibc
	// (producer.c). fd is the read end of the producer's stdout pipe,
	// non-blocking so read() returns EAGAIN instead of blocking.
	fd := C.spawn_producer(c'/bin/sh', producer)
	if fd < 0 {
		core.append_str(mut out, service_unavailable)
		return .done
	}
	core.append_str(mut out, chunk_headers) // flushed after the initial .suspend
	// fd is request-owned: if the client leaves mid-stream, the runtime closes
	// it, and the producer dies of SIGPIPE on its next write.
	event_loop.watch_fd(fd, .readable, on_chunk, unsafe { nil })
	return .suspend
}

// on_chunk runs whenever the pipe has bytes (or hit EOF): forward what is there
// as one chunk and re-arm. Each chunk flushes on .suspend, so the client sees
// output as the producer emits it.
fn on_chunk(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	// Read straight into out's spare capacity, leaving room for the chunk-size
	// line in front, then slide the bytes down behind the line once their count
	// is known: no scratch buffer to zero and copy on every wake.
	if out.cap - out.len < size_line_max + read_max + 2 {
		out.grow_cap(size_line_max + read_max + 2)
	}
	data := unsafe { &u8(out.data) + out.len + size_line_max }
	n := C.read(ready_fd, data, read_max)
	if n > 0 {
		// HTTP chunk = <hex length>\r\n<bytes>\r\n. The capacity is reserved:
		// the appends below never move out.data.
		wx(mut out, n)
		core.append_str(mut out, '\r\n')
		unsafe {
			vmemmove(&u8(out.data) + out.len, data, n)
			out.len += n
		}
		core.append_str(mut out, '\r\n')
		event_loop.watch_fd(ready_fd, .readable, on_chunk, watch_payload)
		return .suspend
	}
	if n == 0 {
		// EOF: the producer exited, and the kernel reaps it (ignore_sigchld).
		core.append_str(mut out, last_chunk)
		C.close(ready_fd)
		return .done
	}
	// n < 0: nothing ready yet (EAGAIN) → wait for the next readable edge.
	if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
		event_loop.watch_fd(ready_fd, .readable, on_chunk, watch_payload)
		return .suspend
	}
	C.close(ready_fd) // a real read error → drop the connection
	return .close
}

// ignore_sigchld sets SIGCHLD to SIG_IGN. POSIX: a process that ignores
// SIGCHLD gets no zombies, as the kernel reaps each child when it exits. That
// is what reaps the producers. Nothing here waits for them, and nothing could
// once a client disconnects mid-stream: the runtime closes the pipe and never
// runs on_chunk again. Process-wide, so no code in this process can collect a
// child's exit status any more (wait and waitpid fail with ECHILD): fine
// here, where the producers are the only children the process starts.
fn ignore_sigchld() {
	unsafe { C.signal(C.SIGCHLD, C.SIG_IGN) }
}

fn main() {
	ignore_sigchld() // before the server starts: no producer becomes a zombie
	mut srv := server.new_server(server.ServerConfig{
		port:            8093
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
