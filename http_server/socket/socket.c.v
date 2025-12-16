module socket

pub const max_connection_size = 1024

#include <fcntl.h>

$if !windows {
	#include <netinet/in.h>
}

fn C.socket(socket_family int, socket_type int, protocol int) int
fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int
fn C.setsockopt(__fd int, __level int, __optname int, __optval voidptr, __optlen u32) int
fn C.listen(__fd int, __n int) int
fn C.perror(s &u8)
fn C.close(fd int) int
fn C.accept(sockfd int, address &C.sockaddr_in, addrlen &u32) int
fn C.htons(__hostshort u16) u16
fn C.fcntl(fd int, cmd int, arg int) int
fn C.connect(sockfd int, addr &C.sockaddr_in, addrlen u32) int

struct C.in_addr {
	s_addr u32
}

struct C.sockaddr_in {
	sin_family u16
	sin_port   u16
	sin_addr   C.in_addr
	sin_zero   [8]u8
}

// Helper for client connections (for testing)
pub fn connect_to_server(port int) !int {
	println('[client] Creating client socket...')
	client_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if client_fd < 0 {
		println('[client] Failed to create client socket')
		return error('Failed to create client socket')
	}
	muts := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   C.in_addr{u32(0)} // 0.0.0.0
		sin_zero:   [8]u8{}
	}
	println('[client] Connecting to server on port ${port} (0.0.0.0)...')
	if C.connect(client_fd, &muts, sizeof(muts)) < 0 {
		println('[client] Failed to connect to server')
		C.close(client_fd)
		return error('Failed to connect to server')
	}
	println('[client] Connected to server, fd=${client_fd}')
	return client_fd
}

// Setup and teardown for server sockets.

pub fn set_blocking(fd int, blocking bool) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags == -1 {
		eprintln(@LOCATION)
		return
	}
	new_flags := if blocking { flags & ~C.O_NONBLOCK } else { flags | C.O_NONBLOCK }
	C.fcntl(fd, C.F_SETFL, new_flags)
}

pub fn close_socket(fd int) {
	C.close(fd)
}

pub fn create_server_socket(port int) int {
	server_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if server_fd < 0 {
		eprintln(@LOCATION)
		C.perror(c'Socket creation failed')
		exit(1)
	}

	set_blocking(server_fd, false)

	opt := 1

	// On macOS, also set SO_REUSEPORT to allow quick restarts and multiple listeners
	// On Linux/other Unix, use SO_REUSEPORT for socket sharding/load balancing
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
		eprintln(@LOCATION)
		C.perror(c'setsockopt SO_REUSEPORT failed')
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

	if C.bind(server_fd, &server_addr, sizeof(server_addr)) < 0 {
		eprintln(@LOCATION)
		C.perror(c'Bind failed')
		close_socket(server_fd)
		exit(1)
	}

	if C.listen(server_fd, max_connection_size) < 0 {
		eprintln(@LOCATION)
		C.perror(c'Listen failed')
		close_socket(server_fd)
		exit(1)
	}

	return server_fd
}
