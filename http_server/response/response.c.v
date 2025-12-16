module response

#include <errno.h>

fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.perror(s &u8)

pub const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const status_444_response = 'HTTP/1.1 444 No Response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

// HTTP response helpers.

pub fn send_response(fd int, buffer_ptr &u8, buffer_len int) ! {
	flags := $if linux {
		C.MSG_NOSIGNAL | C.MSG_ZEROCOPY
	} $else {
		C.MSG_NOSIGNAL
	}
	sent := C.send(fd, buffer_ptr, buffer_len, flags)
	if sent < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
		eprintln(@LOCATION)
		C.perror(c'send')
		return error('send failed')
	}
}

pub fn send_bad_request_response(fd int) {
	C.send(fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
}

pub fn send_status_444_response(fd int) {
	C.send(fd, status_444_response.data, status_444_response.len, 0)
}
