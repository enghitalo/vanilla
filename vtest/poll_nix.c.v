module vtest

// poll(2) surface for the reactor — unix side. The struct layout comes from the
// included header (V `C.` structs are declarations, not definitions); only the
// fields the loop touches are named.
#include <poll.h>

pub struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(__fds voidptr, __nfds u64, __timeout int) int

// poll bit values from <poll.h> (linux/darwin agree on these).
const pollin = int(0x001)
const pollout = int(0x004)
const pollerr = int(0x008)
const pollhup = int(0x010)

// vpoll blocks until at least one fd is ready. -1 = no timeout: the ONLY clocks
// in a vtest run live in the server's config (docs/VTEST.md, goal 2).
fn vpoll(mut fds []C.pollfd) int {
	return C.poll(unsafe { &fds[0] }, u64(fds.len), -1)
}

fn mk_pollfd(fd int, events int) C.pollfd {
	return C.pollfd{
		fd:      fd
		events:  i16(events)
		revents: 0
	}
}
