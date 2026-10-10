module main

// Async-runtime example (no database needed): the smallest consumer of the
// opt-in `watch(fd)+continuation` primitive. `/delay?ms=N` PARKS the request on
// a `timerfd` and replies "delayed" when it fires — the single worker keeps
// serving other connections meanwhile, so N concurrent /delay requests overlap
// instead of serializing. N defaults to 200 and is capped at 10 s. Every other
// path replies immediately.
//
// Run:   v run examples/async_timer/
// Try:   curl 'http://localhost:8091/delay?ms=300'
//        # 20 concurrent 500ms delays finish in ~0.5s, not 10s:
//        seq 20 | xargs -P20 -I{} curl -s 'http://localhost:8091/delay?ms=500' >/dev/null
//
// The same `event_loop.watch_fd(...)` primitive drives an async DB query (watch the DB
// socket), a reverse proxy (watch the upstream socket), or SSE/WebSocket
// backpressure (watch the client for EPOLLOUT). See core.Handler.
import server
import core
import http1_1.request_parser
import http1_1.response

#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const resp_delayed = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\ndelayed'

const ms_key = 'ms'.bytes()

const default_ms = 200

const max_ms = 10_000

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

// delay_ms reads N from `?ms=N` in place (no copy). A missing, empty, zero or
// non-numeric value means default_ms; anything above max_ms is capped, so a
// client cannot park a request for hours.
@[direct_array_access]
fn delay_ms(req request_parser.HttpRequest) int {
	v := req.get_query_slice(ms_key) or { return default_ms }
	mut n := 0
	for i in 0 .. v.len {
		c := req.buffer[v.start + i]
		if c < `0` || c > `9` {
			return default_ms
		}
		n = n * 10 + int(c - `0`)
		if n > max_ms {
			return max_ms
		}
	}
	return if n > 0 { n } else { default_ms }
}

// handle is the request handler. For /delay it arms a one-shot timerfd and
// parks the request on it (returns .suspend); the worker resumes `timer_done`
// when the timer fires. Anything else is answered immediately (.done).
fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if route_is(r, '/delay') {
		ms := delay_ms(r)
		tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
		// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
		mut spec := [4]i64{}
		spec[2] = i64(ms / 1000)
		spec[3] = i64(ms % 1000) * 1_000_000
		C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
		event_loop.watch_fd(tfd, .readable, timer_done, unsafe { nil })
		return .suspend
	}
	core.append_str(mut out, resp_ok)
	return .done
}

// timer_done runs when the timerfd is readable: drain it, close it (the request
// owns it), append the response, and finish.
fn timer_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	core.append_str(mut out, resp_delayed)
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            8091
		io_multiplexing: .epoll
		handler:         handle
	})!
	srv.run()
}
