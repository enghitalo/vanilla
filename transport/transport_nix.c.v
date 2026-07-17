module transport

// Client-side dialing (issue #122 step 2): non-blocking connects that hand
// back a bare fd for the caller to compose with the engine's watch API
// (`event_loop.watch_fd(fd, .writable, ...)` + `.suspend` — the existing
// DB/upstream pattern; pg_async is the in-repo precedent).
//
// SCOPE GUARD: bytes + non-blocking fds ONLY. The day this module grows its
// own event loop or an HTTP client, it has become a second framework.
// Protocol clients (request serializers / response parsers) live inside
// their protocol module (http1_1/client later), not here.
//
// `_nix` suffix: every Unix, never Windows (dial_windows lands with a
// consumer, per docs/ARCHITECTURE.md).

#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include "@VMODROOT/transport/transport_shim.h"

// Deliberately no vanilla imports: transport sits in the same band as
// socket/ (dependency rule, docs/ARCHITECTURE.md). The shim header typedefs
// the sockaddr shapes under transport_* names so this module can bind them
// without redeclaring the same C type name socket/ already declares.
@[typedef]
struct C.transport_in_addr {
	s_addr u32
}

@[typedef]
struct C.transport_sockaddr_in {
mut:
	sin_family u16
	sin_port   u16
	sin_addr   C.transport_in_addr
}

@[typedef]
struct C.transport_sockaddr_un {
mut:
	sun_family u16
	sun_path   [104]char
}

fn C.socket(int, int, int) int
fn C.connect(int, voidptr, u32) int
fn C.close(int) int
fn C.fcntl(int, int, int) int
fn C.htons(u16) u16
fn C.inet_pton(int, &char, voidptr) int
fn C.memset(voidptr, int, usize) voidptr
fn C.memcpy(voidptr, voidptr, usize) voidptr

// max_unix_path mirrors socket.max_unix_path (104-byte sun_path minus the
// NUL — the smaller BSD size, so Linux configs stay portable).
pub const max_unix_path = 103

fn set_nonblocking(fd int) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags != -1 {
		C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK)
	}
}

// dial_tcp starts a NON-BLOCKING IPv4 connect and returns the fd immediately.
// The connect is usually still in flight (EINPROGRESS): park on the fd with
// `event_loop.watch_fd(fd, .writable, ...)` + `.suspend`; when it fires, the
// socket is connected (or carries the error in `ready_fd_error`). Close the
// fd with C.close when done.
pub fn dial_tcp(ipv4 string, port int) !int {
	mut addr := C.transport_sockaddr_in{}
	C.memset(voidptr(&addr), 0, sizeof(C.transport_sockaddr_in))
	addr.sin_family = u16(C.AF_INET)
	addr.sin_port = C.htons(u16(port))
	if C.inet_pton(C.AF_INET, &char(ipv4.str), voidptr(&addr.sin_addr)) != 1 {
		return error('dial_tcp: invalid IPv4 address ${ipv4}')
	}
	fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if fd < 0 {
		return error('dial_tcp: socket creation failed')
	}
	set_nonblocking(fd)
	if C.connect(fd, voidptr(&addr), sizeof(C.transport_sockaddr_in)) < 0 {
		if C.errno != C.EINPROGRESS {
			C.close(fd)
			return error('dial_tcp: connect to ${ipv4}:${port} failed (errno ${C.errno})')
		}
	}
	return fd
}

// dial_unix connects NON-BLOCKING to an AF_UNIX stream listener. Unlike TCP
// (where a SYN queues), a UDS connect on a FULL listen backlog fails
// immediately with EAGAIN (issue #122 §8) — surfaced as its own message so
// callers can tell "server overloaded, retry" from "server absent"
// (ENOENT/ECONNREFUSED). On success the fd is connected right away (local
// connects don't go through EINPROGRESS).
pub fn dial_unix(path string) !int {
	if path.len == 0 || path.len > max_unix_path {
		return error('dial_unix: invalid socket path (1..${max_unix_path} bytes): ${path}')
	}
	mut addr := C.transport_sockaddr_un{}
	C.memset(voidptr(&addr), 0, sizeof(C.transport_sockaddr_un))
	addr.sun_family = u16(C.AF_UNIX)
	C.memcpy(voidptr(&addr.sun_path[0]), path.str, usize(path.len))
	fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	if fd < 0 {
		return error('dial_unix: socket creation failed')
	}
	set_nonblocking(fd)
	if C.connect(fd, voidptr(&addr), sizeof(C.transport_sockaddr_un)) < 0 {
		e := C.errno
		C.close(fd)
		if e == C.EAGAIN {
			return error('dial_unix: listener backlog full at unix:${path} (EAGAIN) — retry')
		}
		return error('dial_unix: connect to unix:${path} failed (errno ${e})')
	}
	return fd
}

// close_fd closes a dialed fd — here so callers need no C declarations.
pub fn close_fd(fd int) {
	C.close(fd)
}
