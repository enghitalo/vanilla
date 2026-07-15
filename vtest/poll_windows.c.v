module vtest

// WSAPoll surface for the reactor — Windows side. Same loop, same semantics;
// WSAPoll takes the winsock pollfd (fd is a SOCKET, i.e. u64 on win64 — the
// header defines the real layout, we only name the fields we touch). Note the
// bit values DIFFER from unix. POLLERR/POLLHUP are output-only here (WSAPoll
// rejects them in `events`), which the reactor already respects.
#include <winsock2.h>

pub struct C.pollfd {
mut:
	fd      u64
	events  i16
	revents i16
}

fn C.WSAPoll(fdArray voidptr, fds u32, timeout int) int

// winsock2.h values: POLLIN = POLLRDNORM|POLLRDBAND, POLLOUT = POLLWRNORM.
const pollin = int(0x0300)
const pollout = int(0x0010)
const pollerr = int(0x0001)
const pollhup = int(0x0002)

fn vpoll(mut fds []C.pollfd) int {
	return C.WSAPoll(unsafe { &fds[0] }, u32(fds.len), -1)
}

fn mk_pollfd(fd int, events int) C.pollfd {
	return C.pollfd{
		fd:      u64(fd)
		events:  i16(events)
		revents: 0
	}
}
