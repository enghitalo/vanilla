module main

// Async-runtime example: incremental read from a slow fd, forwarded as it
// arrives. A child process produces a few lines with pauses; we wrap its pipe,
// watch it readable, and each time bytes show up we forward them as one HTTP
// chunk and re-arm — never blocking the worker while the producer sleeps. This
// is the reverse-proxy / `tail -f` shape: read what's available, stream it, wait
// for more.
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

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

fn C.popen(command &char, mode &char) voidptr
fn C.pclose(stream voidptr) int
fn C.fileno(stream voidptr) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.read(fd int, buf voidptr, count usize) int

const chunk_headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n'

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// last_chunk is the zero-size chunk that ends a chunked body (RFC 9112 §7.1).
const last_chunk = '0\r\n\r\n'

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
	fp := C.popen(c'for i in 1 2 3 4 5; do echo "line $i"; sleep 0.2; done', c'r')
	if fp == unsafe { nil } {
		core.append_str(mut out, not_found)
		return .done
	}
	fd := C.fileno(fp)
	C.fcntl(fd, C.F_SETFL, C.O_NONBLOCK) // so read() returns EAGAIN instead of blocking
	core.append_str(mut out, chunk_headers) // flushed after the initial .suspend
	event_loop.watch_fd(fd, .readable, on_chunk, fp) // carry FILE* so we can pclose at EOF
	return .suspend
}

// on_chunk runs whenever the pipe has bytes (or hit EOF): forward what is there
// as one chunk and re-arm. Each chunk flushes on .suspend, so the client sees
// output as the producer emits it.
fn on_chunk(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut buf := [4096]u8{}
	n := C.read(ready_fd, &buf[0], 4096)
	if n > 0 {
		// HTTP chunk = <hex length>\r\n<bytes>\r\n
		wx(mut out, n)
		core.append_str(mut out, '\r\n')
		unsafe { out.push_many(&buf[0], n) }
		core.append_str(mut out, '\r\n')
		event_loop.watch_fd(ready_fd, .readable, on_chunk, watch_payload)
		return .suspend
	}
	if n == 0 {
		core.append_str(mut out, last_chunk)
		C.pclose(watch_payload)
		return .done
	}
	// n < 0: nothing ready yet (EAGAIN) → wait for the next readable edge.
	if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
		event_loop.watch_fd(ready_fd, .readable, on_chunk, watch_payload)
		return .suspend
	}
	C.pclose(watch_payload) // a real read error → drop the connection
	return .close
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8093
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
