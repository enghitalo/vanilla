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

import http_server
import http_server.core

#include <unistd.h>

fn C.pipe(fds &int) int
fn C.write(fd int, buf voidptr, n usize) int
fn C.read(fd int, buf voidptr, n usize) int
fn C.close(fd int) int

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// handle parks /async on a pipe read-end and answers everything else immediately.
fn handle(req []u8, mut out []u8, _client_fdclient_fd int, _worker_stateworker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/async') {
		mut fds := [2]int{}
		if C.pipe(unsafe { &fds[0] }) != 0 {
			out << resp_ok
			return .done
		}
		// Stand in for "async work finished": make the read end readable. A real
		// consumer would instead watch a DB socket / upstream / timer that becomes
		// ready later — the worker keeps serving others until then.
		b := u8(1)
		C.write(fds[1], &b, 1)
		C.close(fds[1])
		event_loop.watch_fd(fds[0], .readable, pipe_done, unsafe { nil })
		return .suspend
	}
	out << resp_ok
	return .done
}

// pipe_done runs when the pipe read-end is readable: drain it, close it (the
// request owns the watched fd), and answer.
fn pipe_done(mut out []u8, ready_fd int, _ready_fd_errorready_fd_error bool, _watch_payloadwatch_payload voidptr, _worker_stateworker_state voidptr, mut _event_loopevent_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	body := 'async-ok'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:    8094
		handler: handle
	})!
	server.run()
}
