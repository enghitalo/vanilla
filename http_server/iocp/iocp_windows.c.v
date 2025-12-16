module iocp

#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

@[typedef]
pub struct C.OVERLAPPED {
pub mut:
	internal      u64
	internal_high u64
	offset        u64
	offset_high   u64
	h_event       voidptr
}

pub struct CompletionKey {
pub:
	socket_handle int
	operation     IOOperation
	callback      fn (int, IOOperation, []u8) // socket_fd, operation, data
}

pub enum IOOperation {
	accept
	read
	write
	close
}

pub struct IOData {
pub mut:
	overlapped        C.OVERLAPPED
	operation         IOOperation
	socket_fd         int
	wsabuf            C.WSABUF
	buffer            []u8
	bytes_transferred u32
}

@[typedef]
pub struct C.WSABUF {
pub mut:
	len u32
	buf &u8
}

fn C.CreateIoCompletionPort(file_handle voidptr, existing_completion_port voidptr,
	completion_key u64, number_of_concurrent_threads u32) voidptr

fn C.GetQueuedCompletionStatus(completion_port voidptr, lp_number_of_bytes_transferred &u32,
	lp_completion_key &u64, lp_overlapped &&C.OVERLAPPED, dw_milliseconds u32) bool

fn C.PostQueuedCompletionStatus(completion_port voidptr, dw_number_of_bytes_transferred u32,
	dw_completion_key u64, lp_overlapped &C.OVERLAPPED) bool

fn C.CloseHandle(h_object voidptr) bool

fn C.WSARecv(s SOCKET, lp_buffers &C.WSABUF, dw_buffer_count u32, lp_number_of_bytes_recvd &u32,
	lp_flags &u32, lp_overlapped &C.OVERLAPPED, lp_completion_routine voidptr) int

fn C.WSASend(s SOCKET, lp_buffers &C.WSABUF, dw_buffer_count u32, lp_number_of_bytes_sent &u32,
	dw_flags u32, lp_overlapped &C.OVERLAPPED, lp_completion_routine voidptr) int

fn C.AcceptEx(s_listen_socket SOCKET, s_accept_socket SOCKET, lp_output_buffer voidptr,
	dw_receive_data_length u32, dw_local_address_length u32, dw_remote_address_length u32,
	lpdw_bytes_received &u32, lp_overlapped &C.OVERLAPPED) bool

fn C.GetAcceptExSockaddrs(lp_output_buffer voidptr, dw_receive_data_length u32,
	dw_local_address_length u32, dw_remote_address_length u32,
	local_sockaddr &&voidptr, local_sockaddr_length &int,
	remote_sockaddr &&voidptr, remote_sockaddr_length &int)

fn C.CreateEventA(lp_event_attributes voidptr, b_manual_reset bool, b_initial_state bool,
	lp_name &u16) voidptr

fn C.SetEvent(h_event voidptr) bool

fn C.WaitForSingleObject(h_handle voidptr, dw_milliseconds u32) u32

const infinity = 0xFFFFFFFF

pub struct IOCP {
pub mut:
	handle          voidptr
	worker_threads  []thread
	shutdown_signal voidptr
}

pub fn create_iocp(max_concurrent_threads u32) !voidptr {
	handle := C.CreateIoCompletionPort(unsafe { nil }, unsafe { nil }, 0, max_concurrent_threads)
	if handle == unsafe { nil } {
		return error('Failed to create IOCP port')
	}
	return handle
}

pub fn associate_handle_with_iocp(iocp_handle voidptr, socket_handle int, completion_key u64) ! {
	handle := C.CreateIoCompletionPort(voidptr(socket_handle), iocp_handle, completion_key,
		0)
	if handle == unsafe { nil } {
		return error('Failed to associate socket with IOCP')
	}
}

pub fn post_iocp_status(iocp_handle voidptr, bytes_transferred u32, completion_key u64,
	overlapped &C.OVERLAPPED) bool {
	return C.PostQueuedCompletionStatus(iocp_handle, bytes_transferred, completion_key,
		overlapped)
}

pub fn get_queued_completion_status(iocp_handle voidptr, bytes_transferred &u32,
	completion_key &u64, overlapped &&C.OVERLAPPED, timeout_ms u32) bool {
	return C.GetQueuedCompletionStatus(iocp_handle, bytes_transferred, completion_key,
		overlapped, timeout_ms)
}

pub fn create_event() voidptr {
	return C.CreateEventA(unsafe { nil }, false, false, unsafe { nil })
}

pub fn wait_for_single_object(handle voidptr, timeout_ms u32) u32 {
	return C.WaitForSingleObject(handle, timeout_ms)
}

pub fn set_event(handle voidptr) bool {
	return C.SetEvent(handle)
}

pub fn close_handle(handle voidptr) bool {
	return C.CloseHandle(handle)
}

pub fn start_accept_ex(listen_socket int, accept_socket int, overlapped &C.OVERLAPPED) bool {
	return C.AcceptEx(SOCKET(listen_socket), SOCKET(accept_socket), unsafe { nil }, 0,
		sizeof(C.sockaddr_in) + 16, sizeof(C.sockaddr_in) + 16, unsafe { nil }, overlapped)
}

pub fn post_recv(socket_fd int, buffers &C.WSABUF, buffer_count u32, flags &u32,
	overlapped &C.OVERLAPPED) int {
	return C.WSARecv(SOCKET(socket_fd), buffers, buffer_count, unsafe { nil }, flags,
		overlapped, unsafe { nil })
}

pub fn post_send(socket_fd int, buffers &C.WSABUF, buffer_count u32, flags u32,
	overlapped &C.OVERLAPPED) int {
	return C.WSASend(SOCKET(socket_fd), buffers, buffer_count, unsafe { nil }, flags,
		overlapped, unsafe { nil })
}

pub fn create_io_data(socket_fd int, operation IOOperation, buffer_size int) &IOData {
	mut io_data := &IOData{
		socket_fd: socket_fd
		operation: operation
		buffer:    []u8{len: buffer_size}
	}
	io_data.wsabuf.len = u32(buffer_size)
	io_data.wsabuf.buf = &io_data.buffer[0]
	return io_data
}

pub fn free_io_data(io_data &IOData) {
	unsafe {
		io_data.buffer.free()
		free(io_data)
	}
}
