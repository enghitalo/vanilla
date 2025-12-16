module socket

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

// Windows-specific socket helpers

pub fn init_winsock() ! {
	mut wsa_data := WSAData{}
	if WSAStartup(0x202, &wsa_data) != 0 {
		return error('WSAStartup failed')
	}
}

pub fn cleanup_winsock() {
	WSACleanup()
}

type SOCKET = u64

const invalid_socket = SOCKET(~u64(0))
const socket_error = -1

fn C.WSAStartup(wVersionRequired u16, lpWSAData voidptr) int
fn C.WSACleanup() int
fn C.WSAGetLastError() int
fn C.closesocket(s SOCKET) int
fn C.ioctlsocket(s SOCKET, cmd int, argptr &u32) int
fn C.WSAIoctl(s SOCKET, dwIoControlCode u32, lpvInBuffer voidptr, cbInBuffer u32,
lpvOutBuffer voidptr, cbOutBuffer u32, lpcbBytesReturned &u32,
lpOverlapped voidptr, lpCompletionRoutine voidptr) int
fn C.accept(s SOCKET, addr voidptr, addrlen &int) SOCKET
fn C.bind(s SOCKET, name voidptr, namelen int) int
fn C.connect(s SOCKET, name voidptr, namelen int) int
fn C.listen(s SOCKET, backlog int) int
fn C.socket(af int, type int, protocol int) SOCKET
fn C.setsockopt(s SOCKET, level int, optname int, optval voidptr, optlen int) int
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

	mut addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   C.in_addr{u32(0)} // 0.0.0.0
		sin_zero:   [8]u8{}
	}

	println('[client] Connecting to server on port ${port} (0.0.0.0)...')
	if C.connect(SOCKET(client_fd), voidptr(&addr), sizeof(addr)) == socket_error {
		println('[client] Failed to connect to server: error=${C.WSAGetLastError()}')
		C.closesocket(SOCKET(client_fd))
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
	if C.setsockopt(SOCKET(server_fd), C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) == socket_error {
		eprintln(@LOCATION + ' setsockopt SO_REUSEADDR failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	// Bind to INADDR_ANY (0.0.0.0)
	println('[server] Binding to 0.0.0.0:${port}')
	server_addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(port)
		sin_addr:   C.in_addr{u32(C.INADDR_ANY)}
		sin_zero:   [8]u8{}
	}

	if C.bind(SOCKET(server_fd), voidptr(&server_addr), sizeof(server_addr)) == socket_error {
		eprintln(@LOCATION + ' Bind failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	if C.listen(SOCKET(server_fd), max_connection_size) == socket_error {
		eprintln(@LOCATION + ' Listen failed: ${C.WSAGetLastError()}')
		close_socket(server_fd)
		exit(1)
	}

	return server_fd
}
