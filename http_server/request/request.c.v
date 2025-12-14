module request

#include <errno.h>

fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int

// Request reading and handling.

pub fn read_request(client_fd int) ![]u8 {
	mut request_buffer := []u8{}
	defer {
		if unsafe { request_buffer.len == 0 } {
			unsafe { request_buffer.free() }
		}
	}
	mut temp_buffer := [140]u8{}

	for {
		bytes_read := C.recv(client_fd, &temp_buffer[0], temp_buffer.len, 0)
		if bytes_read < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break
			}
			return error('recv failed')
		}
		if bytes_read == 0 {
			return error('client closed connection')
		}
		unsafe { request_buffer.push_many(&temp_buffer[0], bytes_read) }
		if bytes_read < temp_buffer.len {
			break
		}
	}

	if request_buffer.len == 0 {
		return error('empty request')
	}

	return request_buffer
}
