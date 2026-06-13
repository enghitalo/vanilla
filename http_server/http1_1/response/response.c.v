module response

#include <errno.h>

fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.perror(s &u8)

pub const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const status_444_response = 'HTTP/1.1 444 No Response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
// 413/431 are pub so the epoll backend can APPEND them to a batched write
// buffer (sending them raw would jump the queue of already-batched responses).
pub const status_413_response = 'HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
pub const status_431_response = 'HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const status_408_response = 'HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

// HTTP response helpers.

// send_response writes the full response, looping over partial writes.
//
// MSG_NOSIGNAL prevents SIGPIPE on a dead peer. MSG_ZEROCOPY was REMOVED: it
// requires the buffer to stay valid until the kernel signals completion on
// MSG_ERRQUEUE (which we never drained) — a use-after-free, since the caller
// frees the response right after — and it's a net loss below ~10 KB anyway.
//
// Partial writes are now handled instead of silently dropped: `send` may accept
// fewer bytes than offered, so we advance until everything is sent.
//
// REMAINDER (Phase 1b): true backpressure for a full socket buffer needs
// EPOLLOUT + a per-fd pending-write queue. Until then, EAGAIN mid-response is
// reported as an error (the caller closes the fd) rather than silently
// truncating — loud beats wrong. Small responses (the hot path) send in one go.
pub fn send_response(fd int, buffer_ptr &u8, buffer_len int) ! {
	// MSG_NOSIGNAL exists only on Linux; on macOS/BSD SIGPIPE suppression is
	// per-socket via SO_NOSIGPIPE (set at accept — see socket.set_nosigpipe).
	mut flags := 0
	$if linux {
		flags = C.MSG_NOSIGNAL
	}
	mut total_sent := 0
	for total_sent < buffer_len {
		sent := C.send(fd, unsafe { buffer_ptr + total_sent }, usize(buffer_len - total_sent),
			flags)
		if sent > 0 {
			total_sent += sent
			continue
		}
		if sent < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return error('send would block after ${total_sent}/${buffer_len} bytes (EPOLLOUT backpressure not yet implemented)')
		}
		C.perror(c'send')
		return error('send failed after ${total_sent}/${buffer_len} bytes')
	}
}

pub fn send_bad_request_response(fd int) {
	C.send(fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
}

pub fn send_status_444_response(fd int) {
	C.send(fd, status_444_response.data, status_444_response.len, 0)
}

pub fn send_status_413_response(fd int) {
	C.send(fd, status_413_response.data, status_413_response.len, 0)
}

pub fn send_status_431_response(fd int) {
	C.send(fd, status_431_response.data, status_431_response.len, 0)
}

pub fn send_status_408_response(fd int) {
	C.send(fd, status_408_response.data, status_408_response.len, 0)
}
