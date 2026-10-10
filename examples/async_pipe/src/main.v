// Cross-platform async-runtime example (Linux epoll + macOS kqueue): the smallest
// portable consumer of `event_loop.watch_fd(fd, interest, cont, udata)`. `/async` parks the
// request on a pipe's read end (which we make readable to stand in for async work
// completing), then answers from the continuation. Everything else answers
// immediately. Uses only a pipe + read/write/close, so it builds and runs on both
// backends with no platform code.
//
// Run:  v run examples/async_pipe/src
// Try:  curl http://localhost:8094/async   -> "async-ok"
module main

import server
import core
import http1_1.request_parser
import http1_1.response

#include <unistd.h>

fn C.pipe(fds &i32) int
fn C.write(fd int, buf voidptr, n usize) int
fn C.read(fd int, buf voidptr, n usize) int
fn C.close(fd int) int

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const resp_async = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\nasync-ok'

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

// handle parks /async on a pipe read-end and answers everything else immediately.
fn handle(req []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if route_is(r, '/async') {
		mut fds := [2]i32{} // C ints: V int is 64-bit
		if C.pipe(unsafe { &fds[0] }) != 0 {
			core.append_str(mut out, resp_ok)
			return .done
		}
		// Stand in for "async work finished": make the read end readable. A real
		// consumer would instead watch a DB socket / upstream / timer that becomes
		// ready later — the worker keeps serving others until then.
		b := u8(1)
		C.write(int(fds[1]), &b, 1)
		C.close(int(fds[1]))
		event_loop.watch_fd(int(fds[0]), .readable, pipe_done, unsafe { nil })
		return .suspend
	}
	core.append_str(mut out, resp_ok)
	return .done
}

// pipe_done runs when the pipe read-end is readable: drain it, close it (the
// request owns the watched fd), and answer.
fn pipe_done(mut out []u8, ready_fd int, _ready_fd_error bool, _watch_payload voidptr, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	core.append_str(mut out, resp_async)
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:    8094
		handler: handle
	})!
	srv.run()
}
