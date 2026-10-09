module testkit

// Raw-fd companions to the TcpConn readers in testkit.v: end-to-end tests
// that dial through `transport` (or any raw socket) get the same
// deadline-bounded loops without redeclaring poll(2)/read(2)/write(2) per
// test file — before these landed, tests/uds_test.v and the mesh example's
// e2e test each carried their own copy. Same charter as testkit.v: NO vanilla
// imports (raw libc through the shim typedef keeps the dependency script
// honest), and every loop is deadline-bounded so a stalled peer fails the
// test fast instead of hanging it.
//
// `_nix` suffix: the consumers (UDS / transport e2e tests) are unix-only;
// Windows test binaries compile testkit without this file.
import time

#include <poll.h>
#include <errno.h>
#include "@VMODROOT/testkit/testkit_shim.h"

@[typedef]
struct C.testkit_pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds voidptr, nfds u64, timeout int) int

fn C.read(fd int, buf voidptr, count usize) int

fn C.write(fd int, buf voidptr, count usize) int

// poll bit values from <poll.h> (linux/darwin agree on these).
const fd_pollin = i16(0x001)
const fd_pollout = i16(0x004)

// fd_wait_writable polls fd for writability within deadline_ms. For a
// non-blocking dial this is the connect-completion barrier: writable means
// connected (transport.dial_tcp returns with the connect still in flight).
pub fn fd_wait_writable(fd int, deadline_ms int) bool {
	mut pfd := C.testkit_pollfd{
		fd:     fd
		events: fd_pollout
	}
	return C.poll(voidptr(&pfd), 1, deadline_ms) == 1
}

// fd_write_all writes the whole buffer to a (possibly non-blocking) fd,
// polling for writability between short writes; false when the deadline
// elapses (or the peer dies) with bytes still unwritten.
pub fn fd_write_all(fd int, data []u8, deadline_ms int) bool {
	mut off := 0
	sw := time.new_stopwatch()
	for off < data.len {
		if sw.elapsed().milliseconds() >= deadline_ms {
			return false
		}
		n := C.write(fd, unsafe { &data[off] }, usize(data.len - off))
		if n > 0 {
			off += n
			continue
		}
		if n < 0 && C.errno != C.EAGAIN && C.errno != C.EINTR {
			return false
		}
		mut pfd := C.testkit_pollfd{
			fd:     fd
			events: fd_pollout
		}
		C.poll(voidptr(&pfd), 1, 50)
	}
	return true
}

// fd_read_until accumulates bytes from a (possibly non-blocking) fd until
// `needle` appears, the peer closes, or deadline_ms elapses — poll(2)-paced,
// so a stalled stream fails the caller's assert instead of hanging the test
// binary. Returns everything read.
pub fn fd_read_until(fd int, needle string, deadline_ms int) string {
	mut acc := []u8{cap: 1024}
	mut buf := [4096]u8{}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < deadline_ms {
		mut pfd := C.testkit_pollfd{
			fd:     fd
			events: fd_pollin
		}
		if C.poll(voidptr(&pfd), 1, 50) <= 0 {
			continue
		}
		n := C.read(fd, voidptr(&buf[0]), usize(buf.len))
		if n == 0 {
			break // EOF
		}
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EINTR {
				continue
			}
			break // reset counts as close for test purposes
		}
		unsafe { acc.push_many(&buf[0], n) }
		if acc.bytestr().contains(needle) {
			break
		}
	}
	return acc.bytestr()
}
