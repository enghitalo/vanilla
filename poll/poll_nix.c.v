module poll

// Thin wrapper over POSIX poll(2) — the portability floor every Unix (and
// QNX/VxWorks, later) provides. Mirrors the shape of the other event-wrapper
// modules (epoll/, kqueue/, iocp/): C bindings + tiny helpers, no policy.
// The reactor that uses it lives in server/backend_poll/. Per-OS wake
// primitives (wake_qnx.c.v self-pipe, wake_vxworks.c.v pipe device) land
// here with their consumers when those ports arrive (issue #122).
// `_nix` suffix: every Unix, never Windows.

#include "@VMODROOT/poll/poll_shim.h"

@[typedef]
pub struct C.vanilla_pollfd {
pub mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds voidptr, nfds u64, timeout int) int

// Event masks, re-exported as V consts so callers avoid `C.` spelling.
pub const pollin = i16(C.POLLIN)
pub const pollout = i16(C.POLLOUT)
pub const pollerr = i16(C.POLLERR)
pub const pollhup = i16(C.POLLHUP)
pub const pollnval = i16(C.POLLNVAL)

// wait blocks until an fd in `fds` is ready or `timeout_ms` elapses
// (-1 = forever). Returns the number of ready fds, 0 on timeout, <0 on error
// (EINTR included — callers just loop).
@[inline]
pub fn wait(fds &C.vanilla_pollfd, nfds u64, timeout_ms int) int {
	return C.poll(voidptr(fds), nfds, timeout_ms)
}
