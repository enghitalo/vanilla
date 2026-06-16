module main

// Async-runtime example (no database needed): the smallest consumer of the
// opt-in `watch(fd)+continuation` primitive. `/delay?ms=N` PARKS the request on
// a `timerfd` and replies "delayed" when it fires — the single worker keeps
// serving other connections meanwhile, so N concurrent /delay requests overlap
// instead of serializing. Every other path replies immediately.
//
// Run:   v run examples/async_timer/
// Try:   curl 'http://localhost:8091/delay?ms=300'
//        # 20 concurrent 500ms delays finish in ~0.5s, not 10s:
//        seq 20 | xargs -P20 -I{} curl -s 'http://localhost:8091/delay?ms=500' >/dev/null
//
// The same `ac.watch(...)` primitive drives an async DB query (watch the DB
// socket), a reverse proxy (watch the upstream socket), or SSE/WebSocket
// backpressure (watch the client for EPOLLOUT). See core.AsyncHandler.
import http_server
import http_server.core

#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// handle is the async request handler. For /delay it arms a one-shot timerfd and
// parks the request on it (returns .suspend); the worker resumes `timer_done`
// when the timer fires. Anything else is answered immediately (.done).
fn handle(req []u8, mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	if req.bytestr().contains('/delay') {
		ms := 200
		tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
		// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
		mut spec := [4]i64{}
		spec[2] = i64(ms / 1000)
		spec[3] = i64(ms % 1000) * 1_000_000
		C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
		ac.watch(tfd, .readable, timer_done, unsafe { nil })
		return .suspend
	}
	out << resp_ok
	return .done
}

// timer_done runs when the timerfd is readable: drain it, close it (the request
// owns it), append the response, and finish.
fn timer_done(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut tmp := [8]u8{}
	C.read(ac.ready_fd(), &tmp[0], 8)
	C.close(ac.ready_fd())
	body := 'delayed'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
	return .done
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8091
		io_multiplexing: .epoll
		async_handler:   handle
	})!
	server.run()
}
