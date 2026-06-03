module epoll

#include <errno.h>

#include <sys/epoll.h>
#include "@VMODROOT/http_server/epoll/epoll_shim.h"

fn C.epoll_create1(__flags int) int
fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int
fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int
fn C.perror(s &u8)
fn C.close(fd int) int

// fd get/set go through C shims (epoll_shim.h) so V never models the
// `union epoll_data` inside `struct epoll_event` — modeling it makes the Boehm
// GC emit a keepalive that mislabels the union as a `struct` and breaks `-prod`.
fn C.v_epoll_event_get_fd(ev &C.epoll_event) int
fn C.v_epoll_event_set_fd(ev &C.epoll_event, fd int)

// We only ever read `.events` from V; the data union is touched only via the
// shims above, so it's intentionally absent from this declaration. Size/layout
// still come from <sys/epoll.h> (this is a `C.` type).
pub struct C.epoll_event {
	events u32
}

// event_fd extracts the client fd stored in an epoll_event's data union.
@[inline]
pub fn event_fd(ev C.epoll_event) int {
	return C.v_epoll_event_get_fd(&ev)
}

// Callbacks for epoll-driven IO events.
pub struct EpollEventCallbacks {
pub:
	on_read  fn (fd int) @[required]
	on_write fn (fd int) @[required]
}

// Create a new epoll instance. Returns fd or <0 on error.
pub fn create_epoll_fd() int {
	epoll_fd := C.epoll_create1(0)
	if epoll_fd < 0 {
		C.perror(c'epoll_create1')
	}
	return epoll_fd
}

// Add a file descriptor to an epoll instance with given event mask.
pub fn add_fd_to_epoll(epoll_fd int, fd int, events u32) int {
	mut ev := C.epoll_event{
		events: events
	}
	C.v_epoll_event_set_fd(&ev, fd)
	if C.epoll_ctl(epoll_fd, C.EPOLL_CTL_ADD, fd, &ev) == -1 {
		eprintln(@LOCATION)
		C.perror(c'epoll_ctl')
		return -1
	}
	return 0
}

// Change the watched events for an fd already in the epoll set (EPOLL_CTL_MOD).
// Used to add/drop EPOLLOUT when a response is parked for backpressure.
pub fn mod_fd_in_epoll(epoll_fd int, fd int, events u32) int {
	mut ev := C.epoll_event{
		events: events
	}
	C.v_epoll_event_set_fd(&ev, fd)
	return C.epoll_ctl(epoll_fd, C.EPOLL_CTL_MOD, fd, &ev)
}

// Remove a file descriptor from an epoll instance.
pub fn remove_fd_from_epoll(epoll_fd int, fd int) {
	C.epoll_ctl(epoll_fd, C.EPOLL_CTL_DEL, fd, C.NULL)
	C.close(fd)
}
