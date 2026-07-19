module transport

// Client-side dialing — Windows side. The consumer that made it land (per the
// "dial_windows lands with a consumer" note in transport_nix.c.v) is vtest:
// every end-to-end suite now dials through transport on all three OSes, and
// the Windows CI matrix runs the vtest-driven tests against the IOCP backend.
// Same contract as the unix side: hand back a NON-BLOCKING int fd (the
// program-wide int-fd convention socket/ documents); SCOPE GUARD unchanged —
// bytes + non-blocking fds ONLY.
//
// One deliberate divergence: the connect itself is SYNCHRONOUS here, and the
// fd switches to non-blocking right after. WSAPoll cannot report a failed
// non-blocking connect on Windows builds before the 10/2004 POLLERR fix, so a
// synchronous connect is the only shape that surfaces refusal deterministically
// — and loopback connects (the test consumer's case) complete in microseconds
// either way.

#flag windows -lws2_32
#include <winsock2.h>
#include <ws2tcpip.h>
#include "@VMODROOT/transport/transport_shim.h"

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

// Empty decl names the C struct tag (defined by winsock2.h) so WSAStartup has
// real storage — same form as socket/socket_windows.c.v.
struct C.WSAData {}

// Signatures match socket/'s decls exactly (V registers C fn signatures
// program-wide, vlang/v#27791).
fn C.WSAStartup(wVersionRequired u16, lpWSAData voidptr) int

fn C.WSAGetLastError() int

fn C.closesocket(s int) int

fn C.ioctlsocket(s int, cmd int, argptr &u32) int

fn C.socket(int, int, int) int

fn C.connect(int, voidptr, u32) int

fn C.htons(u16) u16

fn C.inet_pton(int, &char, voidptr) int

fn C.memset(voidptr, int, usize) voidptr

// max_unix_path mirrors the unix side so cross-platform config validation
// stays uniform even where dial_unix itself is unsupported.
pub const max_unix_path = 103

// dial_tcp connects to ipv4:port and returns a NON-BLOCKING socket. See the
// module header for why the connect itself is synchronous on Windows.
pub fn dial_tcp(ipv4 string, port int) !int {
	mut wsa := C.WSAData{}
	if C.WSAStartup(0x202, &wsa) != 0 {
		return error('dial_tcp: WSAStartup failed')
	}
	mut addr := C.transport_sockaddr_in{}
	C.memset(voidptr(&addr), 0, sizeof(C.transport_sockaddr_in))
	addr.sin_family = u16(C.AF_INET)
	addr.sin_port = C.htons(u16(port))
	if C.inet_pton(C.AF_INET, &char(ipv4.str), voidptr(&addr.sin_addr)) != 1 {
		return error('dial_tcp: invalid IPv4 address ${ipv4}')
	}
	fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if fd < 0 {
		return error('dial_tcp: socket creation failed (WSA ${C.WSAGetLastError()})')
	}
	if C.connect(fd, voidptr(&addr), sizeof(C.transport_sockaddr_in)) != 0 {
		e := C.WSAGetLastError()
		C.closesocket(fd)
		return error('dial_tcp: connect to ${ipv4}:${port} failed (WSA ${e})')
	}
	mut nb := u32(1)
	C.ioctlsocket(fd, int(C.FIONBIO), &nb)
	return fd
}

// dial_unix: AF_UNIX dialing is not wired on Windows (the engine rejects UDS
// listeners there too) — fail loudly rather than half-support it.
pub fn dial_unix(path string) !int {
	return error('dial_unix: AF_UNIX dialing is not supported on Windows (unix:${path})')
}

// close_fd closes a dialed fd — here so callers need no C declarations.
pub fn close_fd(fd int) {
	C.closesocket(fd)
}
