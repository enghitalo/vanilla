module main

// The Linux half of GET /slow: a one-shot 30 ms timerfd armed through
// event_loop.watch_fd — the async_timer idiom. Lives in an OS-suffix file so
// the example still builds where timerfd does not exist (slow_route's $else
// answers 501 there).
import core

#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

fn slow_route_linux(mut res []u8, mut event_loop core.EventLoop) core.Step {
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, 0)
	if tfd < 0 {
		res << slow_unavailable_response
		return .done
	}
	// struct itimerspec = { it_interval{sec,nsec}, it_value{sec,nsec} } = 4×i64.
	mut spec := [4]i64{}
	spec[3] = 30 * 1_000_000 // one-shot, 30 ms
	C.timerfd_settime(tfd, 0, voidptr(&spec[0]), unsafe { nil })
	event_loop.watch_fd(tfd, .readable, slow_done, unsafe { nil })
	return .suspend
}

// slow_done runs when the timerfd fires: drain it, close it (the request owns
// it), append the response, and finish.
fn slow_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	out << slow_response
	return .done
}
