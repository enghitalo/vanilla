module socket

#flag windows -lws2_32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

// Windows-specific socket helpers

// struct WSAData is fully defined by the included winsock2.h; the empty V
// decl just names the C struct tag (same form as vlib/net) so WSAStartup has
// real storage to write into.
struct C.WSAData {}

pub fn init_winsock() ! {
	mut wsa_data := C.WSAData{}
	if C.WSAStartup(0x202, &wsa_data) != 0 {
		return error('WSAStartup failed')
	}
}

pub fn cleanup_winsock() {
	C.WSACleanup()
}

pub const socket_error = -1

// C declarations follow the int-fd convention everywhere (Windows SOCKET
// handles are 32-bit-significant, INVALID_SOCKET truncates to -1) — and they
// MUST: V registers C function signatures program-wide (vlang/v#27791), so a
// u64-typed duplicate of a function vlib also declares int-typed (vlib/net,
// builtin) breaks vlib's own call sites in any program importing both.
// Functions already declared by socket_tcp.c.v (bind/connect/listen/
// setsockopt/htons/getpeername/inet_ntop/socket/accept) are NOT redeclared
// here.
fn C.WSAStartup(wVersionRequired u16, lpWSAData voidptr) int
fn C.WSACleanup() int
fn C.WSAGetLastError() int
fn C.closesocket(s int) int
fn C.ioctlsocket(s int, cmd int, argptr &u32) int
fn C.htonl(hostlong u32) u32

// struct C.in_addr {
// 	s_addr u32
// }

// struct C.sockaddr_in {
// 	sin_family u16
// 	sin_port   u16
// 	sin_addr   C.in_addr
// 	sin_zero   [8]u8
// }

// Helper for client connections (for testing)
pub fn connect_to_server_on_windows(port int) !int {
	init_winsock() or {
		println('[client] Failed to initialize Winsock: ${err}')
		return err
	}

	println('[client] Creating client socket...')
	client_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if client_fd < 0 {
		println('[client] Failed to create client socket')
		return error('Failed to create client socket')
	}

	// sin_zero padding is left out of the literal: the shared C.sockaddr_in
	// decl doesn't name it, and C zero-inits unspecified fields anyway.
	// 127.0.0.1, not 0.0.0.0: unlike Linux, Winsock rejects INADDR_ANY as a
	// connect() destination with WSAEADDRNOTAVAIL.
	mut addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   C.in_addr{C.htonl(u32(0x7f000001))} // 127.0.0.1
	}

	println('[client] Connecting to server on port ${port} (127.0.0.1)...')
	if C.connect(client_fd, voidptr(&addr), sizeof(addr)) == socket_error {
		println('[client] Failed to connect to server: error=${C.WSAGetLastError()}')
		C.closesocket(client_fd)
		return error('Failed to connect to server')
	}

	println('[client] Connected to server, fd=${client_fd}')
	return client_fd
}

pub fn create_server_socket_on_windows(port int) int {
	init_winsock() or {
		eprintln('Failed to initialize Winsock: ${err}')
		exit(1)
	}

	server_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if server_fd < 0 {
		eprintln(@LOCATION + ' Socket creation failed: ${C.WSAGetLastError()}')
		exit(1)
	}

	// The listening socket stays BLOCKING on purpose: the IOCP backend accepts
	// from a plain blocking accept() loop (no readiness reactor exists to poll
	// it), and closesocket() on shutdown unblocks that loop with an error.

	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) == socket_error {
		eprintln(@LOCATION + ' setsockopt SO_REUSEADDR failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	// Bind to INADDR_ANY (0.0.0.0)
	println('[server] Binding to 0.0.0.0:${port}')
	server_addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   C.in_addr{u32(C.INADDR_ANY)}
	}

	if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) == socket_error {
		eprintln(@LOCATION + ' Bind failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	if C.listen(server_fd, listen_backlog) == socket_error {
		eprintln(@LOCATION + ' Listen failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	return server_fd
}
