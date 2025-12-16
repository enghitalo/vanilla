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

// Proper constants
pub const evfilt_read = i16(-1)
pub const evfilt_write = i16(-2)
pub const ev_add = u16(0x0001)
pub const ev_delete = u16(0x0002)
pub const ev_eof = u16(0x0010)

// V struct for kevent (mirrors C struct)
pub struct C.kevent {
pub mut:
	ident  usize
	filter i16
	flags  u16
	fflags u32
	data   i64
	udata  voidptr
}

// Callbacks for kqueue-driven IO events
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
		flags:  ev_add
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
pub fn remove_fd_from_kqueue(kq int, fd int) {
	mut kev := C.kevent{
		ident: usize(fd)
		flags: ev_delete
	}
	// Remove both read and write filters
	kev.filter = evfilt_read
	C.kevent(kq, &kev, 1, C.NULL, 0, C.NULL)
	kev.filter = evfilt_write
	C.kevent(kq, &kev, 1, C.NULL, 0, C.NULL)
	C.close(fd)
}

// Wait for kqueue events (used by accept loop and workers)
pub fn wait_kqueue(kq int, events &C.kevent, nevents int, timeout int) int {
	mut ts := C.timespec{}
	mut tsp := &ts
	if timeout < 0 {
		tsp = C.NULL
	} else {
		tsp.tv_sec = C.time_t(timeout / 1000)
		tsp.tv_nsec = C.long((timeout % 1000) * 1000000)
	}
	return C.kevent(kq, C.NULL, 0, events, nevents, tsp)
}

// Worker event loop for kqueue io_multiplexing. Processes events for a given kqueue fd using provided callbacks.
pub fn process_kqueue_events(callbacks KqueueEventCallbacks, kq int) {
	mut events := [1024]C.kevent{}
	for {
		nev := wait_kqueue(kq, &events[0], 1024, -1)
		if nev < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'kevent wait')
			break
		}
		for i in 0 .. nev {
			fd := int(events[i].ident)
			if (events[i].flags & ev_eof) != 0 || events[i].fflags != 0 {
				remove_fd_from_kqueue(kq, fd)
				continue
			}
			if events[i].filter == evfilt_read {
				callbacks.on_read(fd)
			} else if events[i].filter == evfilt_write {
				callbacks.on_write(fd)
			}
		}
	}
}
