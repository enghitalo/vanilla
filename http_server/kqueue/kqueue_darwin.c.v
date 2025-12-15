// kqueue_darwin.c.v
// Darwin (macOS) implementation for kqueue-based HTTP server

module kqueue

#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>

fn C.kqueue() int
fn C.kevent(kq int, changelist &C.kevent, nchanges int, eventlist &C.kevent, nevents int, timeout &C.timespec) int
fn C.close(fd int) int
fn C.perror(s &char)

// V struct for kevent (mirrors C struct)
pub struct C.kevent {
	ident  usize
	filter i16
	flags  u16
	fflags u32
	data   i64
	udata  voidptr
}

// Callbacks for kqueue-driven IO events.
pub struct KqueueEventCallbacks {
pub:
	on_read  fn (fd int) @[required]
	on_write fn (fd int) @[required]
}

// Create a new kqueue instance. Returns fd or <0 on error.
pub fn create_kqueue_fd() int {
	kq := C.kqueue()
	if kq < 0 {
		C.perror(c'kqueue')
	}
	return kq
}

// Add a file descriptor to a kqueue instance with given filter (EVFILT_READ/EVFILT_WRITE).
pub fn add_fd_to_kqueue(kq int, fd int, filter i16) int {
	mut kev := C.kevent{
		ident:  usize(fd)
		filter: filter
		flags:  u16(0x0001) // EV_ADD
		fflags: 0
		data:   0
		udata:  unsafe { nil }
	}
	if C.kevent(kq, &kev, 1, C.NULL, 0, C.NULL) == -1 {
		C.perror(c'kevent add')
		return -1
	}
	return 0
}

// Remove a file descriptor from a kqueue instance.
pub fn remove_fd_from_kqueue(kq int, fd int, filter i16) {
	mut kev := C.kevent{
		ident:  usize(fd)
		filter: filter
		flags:  u16(0x0002) // EV_DELETE
		fflags: 0
		data:   0
		udata:  unsafe { nil }
	}
	C.kevent(kq, &kev, 1, C.NULL, 0, C.NULL)
	C.close(fd)
}

// Worker event loop for kqueue io_multiplexing. Processes events for a given kqueue fd using provided callbacks.
pub fn process_kqueue_events(event_callbacks KqueueEventCallbacks, kq int) {
	mut events := [1024]C.kevent{}
	for {
		nev := C.kevent(kq, C.NULL, 0, &events[0], 1024, C.NULL)
		if nev < 0 {
			if C.errno == 4 { // EINTR
				continue
			}
			C.perror(c'kevent wait')
			break
		}
		for i in 0 .. nev {
			fd := int(events[i].ident)
			if events[i].flags & 0x0010 != 0 { // EV_EOF
				remove_fd_from_kqueue(kq, fd, events[i].filter)
				continue
			}
			if events[i].filter == -1 { // EVFILT_READ
				event_callbacks.on_read(fd)
			}
			if events[i].filter == -2 { // EVFILT_WRITE
				event_callbacks.on_write(fd)
			}
		}
	}
}
