module main

// The Linux half of GET /delay/:ms: a one-shot timerfd armed through
// event_loop.watch_fd. Lives in an OS-suffix file so the example builds where
// timerfd does not exist (the route answers 501 there).
import core

#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

const delayed_response = fixed_json(json_200_head, '{"delayed":true}')
const delay_unavailable_response = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// start_delay parks the request on a timerfd that fires in `ms` milliseconds;
// delay_done answers it.
fn start_delay(ms int, mut out []u8, mut event_loop core.EventLoop) core.Step {
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_CLOEXEC)
	if tfd < 0 {
		out << delay_unavailable_response
		return .done
	}
	// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
	// An all-zero it_value disarms the timer, so 0 ms waits 1 ns.
	mut spec := [4]i64{}
	spec[2] = i64(ms / 1000)
	spec[3] = if ms == 0 { 1 } else { i64(ms % 1000) * 1_000_000 }
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	event_loop.watch_fd(tfd, .readable, delay_done, unsafe { nil })
	return .suspend
}

// delay_done runs when the timerfd fires: drain it, close it (the request owns
// it), answer.
fn delay_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	out << delayed_response
	return .done
}
