module main

// Async-runtime example: detecting a watched-fd hangup via ac.ready_err().
//
// A clientless background watch (armed by on_worker_start) sits on the read end
// of a pipe whose writer has gone away. epoll delivers that edge as EPOLLHUP; the
// runtime surfaces it to the continuation as the portable ac.ready_err() == true,
// so the continuation RELEASES the fd (returns .close) instead of re-arming it.
// Re-arming a level-triggered watch on a dead fd would busy-spin forever — this
// is the signal a signalfd / inotify / pipe / upstream-socket background watch
// needs to give up. (A timerfd never hangs up, so async_date_timerfd ignores it.)
//
// on_worker_start simulates "the producer went away" by closing the write end
// immediately, so the watch fires once with a hangup. The server then sits idle
// (no CPU spin) and serves normally:
//   v run examples/async_watch_hangup/
//   curl http://localhost:8098/        # -> ok
import http_server
import http_server.core

#include <unistd.h>

fn C.pipe(fds &int) int
fn C.close(fd int) int

const resp = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// on_start arms a clientless watch on a pipe read-end, then closes the write-end
// so the read-end immediately reports a hangup (the "producer" is gone). Composes
// with a plain stateless request_handler — no async_handler, no make_state.
fn on_start(mut ac core.AsyncCtx) {
	mut fds := [2]int{}
	if C.pipe(&fds[0]) != 0 {
		return
	}
	read_fd, write_fd := fds[0], fds[1]
	C.close(write_fd) // producer gone -> read_fd reports EPOLLHUP on the next poll
	ac.watch(read_fd, .readable, on_source_event, unsafe { nil })
}

// on_source_event runs when the watched fd fires. On error/hangup it gives up
// cleanly (return .close — the runtime DEL+closes read_fd); a naive re-arm here
// would spin every loop iteration on the dead, level-triggered fd.
fn on_source_event(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	if ac.ready_err() {
		eprintln('[worker] background source fd ${ac.ready_fd()} hung up — releasing (no spin)')
		return .close // runtime tears the fd down; we do NOT re-arm
	}
	// A real consumer would read the ready data here, then re-arm:
	ac.watch(ac.ready_fd(), .readable, on_source_event, unsafe { nil })
	return .suspend
}

fn handle(req []u8, fd int, mut out []u8) ! {
	out << resp
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8098
		io_multiplexing: .epoll
		request_handler: handle
		on_worker_start: on_start
	})!
	server.run()
}
