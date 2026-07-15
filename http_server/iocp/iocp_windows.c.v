module iocp

// Thin Win32 I/O-completion-port wrapper — the Windows counterpart of the
// `epoll` / `kqueue` helper modules: just the typed syscall surface the
// backend needs, no policy. The connection state machine lives in
// http_server_windows.c.v.

#flag windows -lws2_32
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

// Field names must match the Win32 definitions EXACTLY (V emits C struct
// member access verbatim) — same declarations vlib/fasthttp uses.
@[typedef]
pub struct C.OVERLAPPED {
pub mut:
	Internal     usize
	InternalHigh usize
	Offset       u32
	OffsetHigh   u32
	hEvent       voidptr
}

@[typedef]
pub struct C.WSABUF {
pub mut:
	len u32
	buf &char = unsafe { nil }
}

// CloseHandle and WSAGetLastError are NOT redeclared here — builtin declares
// both (i32-typed), and V registers C signatures program-wide (vlang/v#27791),
// so an incompatible duplicate would break other modules' call sites.
fn C.CreateIoCompletionPort(file_handle voidptr, existing_completion_port voidptr, completion_key usize, number_of_concurrent_threads u32) voidptr
fn C.GetQueuedCompletionStatus(completion_port voidptr, lp_number_of_bytes_transferred &u32, lp_completion_key &usize, lp_overlapped &&C.OVERLAPPED, dw_milliseconds u32) bool
fn C.PostQueuedCompletionStatus(completion_port voidptr, dw_number_of_bytes_transferred u32, dw_completion_key usize, lp_overlapped &C.OVERLAPPED) bool
fn C.WSARecv(s u64, lp_buffers &C.WSABUF, dw_buffer_count u32, lp_number_of_bytes_recvd &u32, lp_flags &u32, lp_overlapped &C.OVERLAPPED, lp_completion_routine voidptr) int
fn C.WSASend(s u64, lp_buffers &C.WSABUF, dw_buffer_count u32, lp_number_of_bytes_sent &u32, dw_flags u32, lp_overlapped &C.OVERLAPPED, lp_completion_routine voidptr) int

pub const infinite = u32(0xFFFFFFFF)

// wsa_io_pending is WSA_IO_PENDING: an overlapped op was queued successfully
// and will complete through the port — the NON-error "error" every post gets.
pub const wsa_io_pending = 997

// create_iocp creates a completion port that wakes at most
// `max_concurrent_threads` threads at once (1 for a single-worker port).
pub fn create_iocp(max_concurrent_threads u32) !voidptr {
	handle := C.CreateIoCompletionPort(C.INVALID_HANDLE_VALUE, unsafe { nil }, 0,
		max_concurrent_threads)
	if handle == unsafe { nil } {
		return error('CreateIoCompletionPort failed: WSA ${C.WSAGetLastError()}')
	}
	return handle
}

// associate associates a socket with a port; every overlapped completion on
// that socket is then delivered to the port along with `completion_key`.
pub fn associate(iocp_handle voidptr, socket_fd int, completion_key usize) bool {
	return C.CreateIoCompletionPort(voidptr(u64(socket_fd)), iocp_handle, completion_key, 0) != unsafe { nil }
}

// post delivers a manual completion (overlapped may be nil) — used for the
// accept→worker connection hand-off and for shutdown wake-ups.
pub fn post(iocp_handle voidptr, bytes u32, completion_key usize, overlapped &C.OVERLAPPED) bool {
	return C.PostQueuedCompletionStatus(iocp_handle, bytes, completion_key, overlapped)
}

// wait dequeues ONE completion (or times out). Returns false on a failed /
// aborted completion AND on timeout; timeout is the case where `overlapped`
// stays nil.
pub fn wait(iocp_handle voidptr, bytes &u32, completion_key &usize, overlapped &&C.OVERLAPPED, timeout_ms u32) bool {
	return C.GetQueuedCompletionStatus(iocp_handle, bytes, completion_key, overlapped, timeout_ms)
}

// post_recv starts an overlapped receive. Returns true when the op is in
// flight (its completion WILL arrive at the port — including immediate
// success) and false on a hard post failure (nothing was queued).
pub fn post_recv(socket_fd int, wsabuf &C.WSABUF, overlapped &C.OVERLAPPED) bool {
	mut flags := u32(0)
	mut recvd := u32(0)
	if C.WSARecv(u64(socket_fd), wsabuf, 1, &recvd, &flags, overlapped, unsafe { nil }) != 0 {
		return C.WSAGetLastError() == wsa_io_pending
	}
	return true
}

// post_send starts an overlapped send. Same in-flight/failure contract as
// post_recv.
pub fn post_send(socket_fd int, wsabuf &C.WSABUF, overlapped &C.OVERLAPPED) bool {
	mut sent := u32(0)
	if C.WSASend(u64(socket_fd), wsabuf, 1, &sent, 0, overlapped, unsafe { nil }) != 0 {
		return C.WSAGetLastError() == wsa_io_pending
	}
	return true
}

pub fn close_handle(handle voidptr) bool {
	return C.CloseHandle(handle) != 0
}
