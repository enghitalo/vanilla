module socket

pub const max_connection_size = 1024

// listen() backlog: the depth of the kernel's queue of established-but-not-yet-
// accepted connections. The kernel silently clamps this to
// /proc/sys/net/core/somaxconn, so we pass a large value and let the OS cap it —
// a small backlog drops SYNs during accept bursts (e.g. a benchmark ramping up
// hundreds of connections at once). rust-epoll, the reference epoll server, uses
// the same 65536.
pub const listen_backlog = 65536

#include <fcntl.h>
#include <sys/socket.h>

$if !windows {
	#include <netinet/in.h>
	// superset of previous
	#include <netinet/ip.h>
	#include <netinet/tcp.h> // TCP_NODELAY
	#include <arpa/inet.h> // inet_ntop
}

fn C.getpeername(fd int, addr voidptr, addrlen &u32) int
fn C.inet_ntop(af int, src voidptr, dst &char, size u32) &char

$if linux {
	// accept4 sets the client socket non-blocking atomically, saving the two
	// fcntl() syscalls that set_blocking() would otherwise do per connection.
	fn C.accept4(sockfd int, address voidptr, addrlen voidptr, flags int) int
}

fn C.socket(socket_family int, socket_type int, protocol int) int

$if linux {
	fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int
} $else {
	fn C.bind(sockfd int, addr voidptr, addrlen u32) int // Use voidptr for generic sockaddr
}
fn C.setsockopt(__fd int, __level int, __optname int, __optval voidptr, __optlen u32) int
fn C.listen(__fd int, __n int) int
fn C.perror(s &char)
fn C.close(fd int) int
fn C.shutdown(__fd int, __how int) int

$if linux {
	fn C.accept(sockfd int, address &C.sockaddr_in, addrlen &u32) int
} $else {
	fn C.accept(sockfd int, address voidptr, addrlen &u32) int // Use voidptr here too
}
fn C.htons(__hostshort u16) u16
fn C.fcntl(fd int, cmd int, arg int) int
fn C.connect(sockfd int, addr &C.sockaddr_in, addrlen u32) int

// Internet address
struct C.in_addr {
	// address in network byte order
	s_addr u32
}

// An IP socket address is defined as a combination of an IP
// interface address and a 16-bit port number.  The basic IP protocol
// does not supply port numbers, they are implemented by higher level
// protocols like udp(7) and tcp(7).  On raw sockets sin_port is set
// to the IP protocol.
struct C.sockaddr_in {
	// address family: AF_INET
	sin_family u16
	// port in network byte order
	sin_port u16
	// internet address
	sin_addr C.in_addr
}

// Helper for client connections (for testing)
pub fn connect_to_server(port int) !int {
	println('[client] Creating client socket...')
	// The unix body lives in `$else`: comptime early-return alone doesn't stop
	// the checker, and on Windows C.socket/C.accept return u64 (SOCKET), so
	// the unix int-typed code must not be typechecked there.
	$if windows {
		return connect_to_server_on_windows(port)
	} $else {
		client_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
		if client_fd < 0 {
			println('[client] Failed to create client socket')
			return error('Failed to create client socket')
		}
		mut addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   C.in_addr{u32(C.INADDR_ANY)} // 0.0.0.0
		}
		println('[client] Connecting to server on port ${port} (0.0.0.0)...')
		// Cast to voidptr for OS compatibility
		if C.connect(client_fd, voidptr(&addr), sizeof(addr)) < 0 {
			println('[client] Failed to connect to server')
			C.close(client_fd)
			return error('Failed to connect to server')
		}
		println('[client] Connected to server, fd=${client_fd}')
		return client_fd
	}
}

// Setup and teardown for server sockets.

pub fn set_blocking(fd int, blocking bool) {
	$if windows {
		mut mode := u32(if blocking { 0 } else { 1 })
		if C.ioctlsocket(u64(fd), 0x8004667E, &mode) != 0 // FIONBIO
		  {
			eprintln(@LOCATION + ' ioctlsocket failed: ${C.WSAGetLastError()}')
		}
	} $else {
		flags := C.fcntl(fd, C.F_GETFL, 0)
		if flags == -1 {
			eprintln(@LOCATION)
			return
		}
		new_flags := if blocking { flags & ~C.O_NONBLOCK } else { flags | C.O_NONBLOCK }
		C.fcntl(fd, C.F_SETFL, new_flags)
	}
}

// set_tcp_nodelay disables Nagle's algorithm so small responses go out
// immediately instead of waiting to coalesce. Standard for request/response
// HTTP servers; the win shows on real networks (negligible on loopback).
pub fn set_tcp_nodelay(fd int) {
	$if !windows {
		opt := 1
		C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &opt, sizeof(opt))
	}
}

// set_nosigpipe stops send() to a dead peer from raising SIGPIPE on
// macOS/BSD, where there is no MSG_NOSIGNAL send flag — the suppression is a
// per-socket option instead. No-op elsewhere.
pub fn set_nosigpipe(fd int) {
	$if darwin {
		opt := 1
		C.setsockopt(fd, C.SOL_SOCKET, C.SO_NOSIGPIPE, &opt, sizeof(opt))
	}
}

// accept_client accepts a connection and returns a NON-BLOCKING client fd
// (or <0). On Linux this is a single accept4() syscall; elsewhere it falls
// back to accept() + fcntl (+ SO_NOSIGPIPE on darwin).
pub fn accept_client(server_fd int) int {
	$if linux {
		return C.accept4(server_fd, C.NULL, C.NULL, C.SOCK_NONBLOCK)
	} $else $if windows {
		// Winsock SOCKET is u64; kernel handles are 32-bit-significant, so the
		// int fd convention holds (INVALID_SOCKET truncates to -1).
		fd := int(C.accept(u64(server_fd), C.NULL, C.NULL))
		if fd >= 0 {
			set_blocking(fd, false)
		}
		return fd
	} $else {
		fd := C.accept(server_fd, C.NULL, C.NULL)
		if fd >= 0 {
			set_blocking(fd, false)
			set_nosigpipe(fd)
		}
		return fd
	}
}

// peer_addr returns the remote IPv4 address of a connected socket (e.g.
// "203.0.113.7"), or '' on error. Call it from a handler only when you need the
// client IP (rate limiting, proxy trust) — it costs one getpeername syscall and
// nothing otherwise, keeping the `fn ([]u8, int)` handler contract intact.
pub fn peer_addr(fd int) string {
	$if windows {
		return ''
	} $else {
		mut a := C.sockaddr_in{}
		mut l := u32(sizeof(a))
		if C.getpeername(fd, voidptr(&a), &l) != 0 {
			return ''
		}
		mut buf := [46]u8{} // INET6_ADDRSTRLEN
		if C.inet_ntop(C.AF_INET, voidptr(&a.sin_addr), &char(&buf[0]), 46) == 0 {
			return ''
		}
		return unsafe { cstring_to_vstring(&char(&buf[0])) }
	}
}

pub fn close_socket(fd int) {
	$if windows {
		C.closesocket(u64(fd))
	} $else {
		C.close(fd)
	}
}

// shutdown_socket stops a listening socket and closes it. On Linux/Unix it first
// calls shutdown(SHUT_RDWR): unlike close(), that terminates an io_uring multishot
// accept armed on the socket (the ring holds its own file reference, so close()
// alone would not cancel the accept). Used by Server.shutdown() to stop every
// per-worker listener at once. SHUT_RDWR is 2 on every platform.
pub fn shutdown_socket(fd int) {
	$if !windows {
		C.shutdown(fd, 2) // SHUT_RDWR
	}
	close_socket(fd)
}

pub fn create_server_socket(port int) int {
	// Unix body in `$else` — see connect_to_server for why.
	$if windows {
		return create_server_socket_on_windows(port)
	} $else {
		server_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
		if server_fd < 0 {
			eprintln(@LOCATION)
			C.perror(c'Socket creation failed')
			exit(1)
		}

		set_blocking(server_fd, false)

		opt := 1
		// On Linux, also set SO_REUSEPORT for load balancing between threads
		$if linux {
			// On Linux/other Unix, use SO_REUSEPORT for socket sharding/load balancing
			// SO_REUSEPORT allows multiple workers to bind() and accept() independently
			if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
				eprintln(@LOCATION)
				C.perror(c'setsockopt SO_REUSEPORT failed')
				close_socket(server_fd)
				exit(1)
			}

			eprintln('[socket] SO_REUSEPORT enabled for load balancing')
		} $else {
			if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) < 0 {
				eprintln(@LOCATION)
				C.perror(c'setsockopt SO_REUSEADDR failed')
				close_socket(server_fd)
				exit(1)
			}
		}

		// Bind to INADDR_ANY (0.0.0.0)
		println('[socket] Binding to 0.0.0.0:${port}')
		server_addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   C.in_addr{u32(C.INADDR_ANY)} // 0.0.0.0
		}

		// Cast to voidptr to fix the type mismatch
		if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) < 0 {
			eprintln(@LOCATION)
			C.perror(c'Bind failed')
			close_socket(server_fd)
			exit(1)
		}

		if C.listen(server_fd, listen_backlog) < 0 {
			eprintln(@LOCATION)
			C.perror(c'Listen failed')
			close_socket(server_fd)
			exit(1)
		}

		return server_fd
	}
}
