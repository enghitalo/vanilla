module socket

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

type SOCKET = u64

pub const invalid_socket = u64(~u64(0))
pub const socket_error = -1

fn C.WSAStartup(wVersionRequired u16, lpWSAData voidptr) int
fn C.WSACleanup() int
fn C.WSAGetLastError() int
fn C.closesocket(s u64) int
fn C.ioctlsocket(s u64, cmd int, argptr &u32) int
fn C.WSAIoctl(s u64, dwIoControlCode u32, lpvInBuffer voidptr, cbInBuffer u32,
	lpvOutBuffer voidptr, cbOutBuffer u32, lpcbBytesReturned &u32,
	lpOverlapped voidptr, lpCompletionRoutine voidptr) int
fn C.accept(s u64, addr voidptr, addrlen &int) u64
fn C.bind(s u64, name voidptr, namelen int) int
fn C.connect(s u64, name voidptr, namelen int) int
fn C.listen(s u64, backlog int) int
fn C.socket(socket_family int, socket_type int, protocol int) u64
fn C.setsockopt(s u64, level int, optname int, optval voidptr, optlen int) int
fn C.htons(hostshort u16) u16
fn C.htonl(hostlong u32) u32
fn C.ntohs(netshort u16) u16
fn C.ntohl(netlong u32) u32
fn C.getaddrinfo(nodename &char, servname &char, hints voidptr, res &&voidptr) int
fn C.freeaddrinfo(res voidptr)
fn C.getnameinfo(sa voidptr, salen int, host &char, hostlen int,
	serv &char, servlen int, flags int) int
fn C.inet_pton(af int, src &char, dst voidptr) int
fn C.inet_ntop(af int, src voidptr, dst &char, size int) &char

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
	client_fd := int(C.socket(C.AF_INET, C.SOCK_STREAM, 0))
	if client_fd == int(invalid_socket) {
		println('[client] Failed to create client socket')
		return error('Failed to create client socket')
	}

	// sin_zero padding is left out of the literal: the shared C.sockaddr_in
	// decl doesn't name it, and C zero-inits unspecified fields anyway.
	mut addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   C.in_addr{u32(0)} // 0.0.0.0
	}

	println('[client] Connecting to server on port ${port} (0.0.0.0)...')
	if C.connect(u64(client_fd), voidptr(&addr), sizeof(addr)) == socket_error {
		println('[client] Failed to connect to server: error=${C.WSAGetLastError()}')
		C.closesocket(u64(client_fd))
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

	server_fd := int(C.socket(C.AF_INET, C.SOCK_STREAM, 0))
	if server_fd == int(invalid_socket) {
		eprintln(@LOCATION + ' Socket creation failed: ${C.WSAGetLastError()}')
		exit(1)
	}

	set_blocking(server_fd, false)

	opt := 1
	if C.setsockopt(u64(server_fd), C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) == socket_error {
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

	if C.bind(u64(server_fd), voidptr(&server_addr), sizeof(server_addr)) == socket_error {
		eprintln(@LOCATION + ' Bind failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	if C.listen(u64(server_fd), listen_backlog) == socket_error {
		eprintln(@LOCATION + ' Listen failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	return server_fd
}
