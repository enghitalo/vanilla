module socket

// AF_UNIX stream listeners (docs/ARCHITECTURE.md: the listen side of local
// IPC, issue #122 §5). The engine treats the returned fd exactly like a TCP
// listener — accept_client/accept4 are family-agnostic — so the only UDS-
// specific code in the whole tree is creating, connecting to and unlinking
// the socket path. `_nix` suffix: every Unix, never Windows.

#include <sys/un.h>

// sun_path is 108 bytes on Linux and 104 on the BSDs/macOS; cap at the
// smaller one (minus the NUL) so a config that builds on Linux also builds
// on macOS. This is a comptime capability const with a consumer at birth:
// create_unix_server_socket/connect_unix below guard against it.
pub const max_unix_path = 103

// The C compiler lays this out from <sys/un.h>, so the BSD `sun_len` byte on
// macOS is handled for free (memset leaves it 0, which the kernel ignores);
// only the fields V touches need declaring.
struct C.sockaddr_un {
mut:
	sun_family u16
	sun_path   [104]char
}

fn C.memset(voidptr, int, usize) voidptr
fn C.memcpy(voidptr, voidptr, usize) voidptr
fn C.unlink(&char) int

// fill_sockaddr_un zeroes and fills an AF_UNIX address, or errors when the
// path cannot fit (a filesystem path, not abstract-namespace: no NUL-prefix).
fn fill_sockaddr_un(path string, mut a C.sockaddr_un) ! {
	if path.len == 0 {
		return error('unix socket path is empty')
	}
	if path.len > max_unix_path {
		return error('unix socket path exceeds ${max_unix_path} bytes: ${path}')
	}
	C.memset(voidptr(&a), 0, sizeof(C.sockaddr_un))
	a.sun_family = u16(C.AF_UNIX)
	C.memcpy(voidptr(&a.sun_path[0]), path.str, usize(path.len))
}

// unlink_socket_path removes a socket file, ignoring errors (the path may
// never have existed). Called before bind (stale socket from a previous run
// would make bind fail with EADDRINUSE) and after shutdown (cleanup).
pub fn unlink_socket_path(path string) {
	C.unlink(&char(path.str))
}

// create_unix_server_socket binds and listens on an AF_UNIX stream socket at
// `path`, non-blocking, and returns the listener fd. A stale socket file at
// the path is unlinked first (standard for UDS servers: the file outlives the
// process). Unlike create_server_socket (TCP, exits on failure at startup),
// path problems are user config errors — surface them as `!` so new_server
// can report them.
pub fn create_unix_server_socket(path string) !int {
	mut addr := C.sockaddr_un{}
	fill_sockaddr_un(path, mut addr)!
	server_fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	if server_fd < 0 {
		return error('unix socket creation failed')
	}
	set_blocking(server_fd, false)
	unlink_socket_path(path)
	println('[socket] Binding to unix:${path}')
	if C.bind(server_fd, voidptr(&addr), sizeof(C.sockaddr_un)) < 0 {
		close_socket(server_fd)
		return error('bind failed for unix:${path}')
	}
	if C.listen(server_fd, listen_backlog) < 0 {
		close_socket(server_fd)
		return error('listen failed for unix:${path}')
	}
	return server_fd
}

// connect_to_unix_server opens a BLOCKING client connection to a UDS listener
// — the test/shutdown-poke helper, mirroring connect_to_server (TCP). The
// non-blocking client dial for handlers lives in `transport.dial_unix`.
pub fn connect_to_unix_server(path string) !int {
	mut addr := C.sockaddr_un{}
	fill_sockaddr_un(path, mut addr)!
	client_fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	if client_fd < 0 {
		return error('unix socket creation failed')
	}
	if C.connect(client_fd, voidptr(&addr), sizeof(C.sockaddr_un)) < 0 {
		close_socket(client_fd)
		return error('connect failed for unix:${path}')
	}
	return client_fd
}
