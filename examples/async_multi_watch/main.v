module main

// Async-runtime example: a multi-step chain that watches SEVERAL fds in sequence
// over one request. `/chain` waits on timer A, then on a DIFFERENT timer B, then
// answers — each `.suspend` re-arms the worker on the next fd. This is the shape
// of any "do X, then once it is ready do Y, then reply" flow: connect → send →
// recv, or query → second query → render. v1 runs one in-flight watch per
// connection, so the steps are sequential (not concurrent fan-in).
//
// Run:   v run examples/async_multi_watch/
// Try:   curl http://localhost:8094/chain
//        # -> "stage A done (80ms), then stage B done (140ms)" after ~220ms
//
// The worker is free between stages, so many /chain requests overlap their waits
// instead of serializing. See core.Handler / core.WakeFn.
import http_server
import http_server.core

#include <sys/timerfd.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// one_shot_timer returns a timerfd that fires once after `ms`.
fn one_shot_timer(ms int) int {
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	mut spec := [4]i64{} // { it_interval{0,0}, it_value{sec,nsec} } → one-shot
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
	return tfd
}

// drain_close reads the expiry count off a fired timerfd and closes it (each
// stage owns its own timerfd).
fn drain_close(fd int) {
	mut tmp := [8]u8{}
	C.read(fd, &tmp[0], 8)
	C.close(fd)
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !req.bytestr().contains('/chain') {
		out << not_found
		return .done
	}
	event_loop.watch_fd(one_shot_timer(80), .readable, after_a, unsafe { nil }) // stage A
	return .suspend
}

// after_a runs when timer A fires: close it, then arm a DIFFERENT fd (timer B)
// and park again — demonstrating that a continuation can re-watch a new fd.
fn after_a(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain_close(ready_fd)
	event_loop.watch_fd(one_shot_timer(140), .readable, after_b, unsafe { nil }) // stage B
	return .suspend
}

// after_b runs when timer B fires: close it and produce the response.
fn after_b(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain_close(ready_fd)
	body := 'stage A done (80ms), then stage B done (140ms)'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8094
		io_multiplexing: .epoll
		handler:         handle
	})!
	server.run()
}
