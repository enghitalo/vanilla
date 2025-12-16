module http_server

import socket
import runtime
import iocp
import response
import request

#include <winsock2.h>
#include <windows.h>

$if windows {
	#include <mswsock.h>
}

const acceptex_guid = C.WSAID_ACCEPTEX
const max_iocp_workers = runtime.nr_cpus()
const buffer_size = 8192

struct WorkerContext {
pub mut:
	iocp_handle voidptr
	handler     fn ([]u8, int) ![]u8
	running     bool
	thread_id   u32
}

struct AcceptContext {
pub mut:
	listen_socket int
	iocp_handle   voidptr
	accept_socket int
	overlapped    C.OVERLAPPED
	local_addr    [sizeof(C.sockaddr_in) + 16]u8
	remote_addr   [sizeof(C.sockaddr_in) + 16]u8
}

fn get_system_error() string {
	error_code := C.WSAGetLastError()
	mut buffer := [256]u16{}
	C.FormatMessageW(C.FORMAT_MESSAGE_FROM_SYSTEM | C.FORMAT_MESSAGE_IGNORE_INSERTS, unsafe { nil },
		error_code, 0, &buffer[0], 256, unsafe { nil })
	return string_from_wide(&buffer[0])
}

fn worker_thread(mut ctx WorkerContext) {
	println('[iocp-worker] Worker thread started')

	for ctx.running {
		mut bytes_transferred := u32(0)
		mut completion_key := u64(0)
		mut overlapped := &C.OVERLAPPED(unsafe { nil })

		success := iocp.get_queued_completion_status(ctx.iocp_handle, &bytes_transferred,
			&completion_key, &overlapped, iocp.infinity)

		if !success {
			// Check if it's a shutdown signal
			if overlapped == unsafe { nil } && bytes_transferred == 0 && completion_key == 0 {
				println('[iocp-worker] Received shutdown signal')
				break
			}
			error_code := C.WSAGetLastError()
			if error_code == 64 { // WAIT_TIMEOUT
				continue
			}
			eprintln('[iocp-worker] GetQueuedCompletionStatus failed: ${get_system_error()}')
			continue
		}

		// Handle shutdown signal
		if bytes_transferred == 0 && completion_key == 0 && overlapped == unsafe { nil } {
			println('[iocp-worker] Received shutdown signal')
			break
		}

		// Cast overlapped back to IOData
		io_data := unsafe { &iocp.IOData(overlapped) }

		match io_data.operation {
			.accept {
				handle_accept_completion(io_data, ctx.handler, mut ctx)
			}
			.read {
				handle_read_completion(io_data, ctx.handler, mut ctx)
			}
			.write {
				handle_write_completion(io_data, mut ctx)
			}
			.close {
				socket.close_socket(io_data.socket_fd)
				iocp.free_io_data(io_data)
			}
		}
	}

	println('[iocp-worker] Worker thread exiting')
}

fn handle_accept_completion(io_data &iocp.IOData, handler fn ([]u8, int) ![]u8,
	mut ctx WorkerContext) {
	socket_fd := io_data.socket_fd

	// Set socket options for accepted connection
	opt := 1
	C.setsockopt(SOCKET(socket_fd), C.SOL_SOCKET, C.SO_UPDATE_ACCEPT_CONTEXT, &socket_fd,
		sizeof(socket_fd))

	// Associate the accepted socket with IOCP
	iocp.associate_handle_with_iocp(ctx.iocp_handle, socket_fd, u64(socket_fd)) or {
		eprintln('[iocp-worker] Failed to associate accepted socket: ${err}')
		socket.close_socket(socket_fd)
		return
	}

	// Post a read operation on the new socket
	post_read_operation(socket_fd, ctx.iocp_handle)

	// Post another accept on the listening socket
	// (We need to get the listening socket from somewhere - stored in context)
}

fn handle_read_completion(io_data &iocp.IOData, handler fn ([]u8, int) ![]u8,
	mut ctx WorkerContext) {
	socket_fd := io_data.socket_fd
	bytes_read := io_data.bytes_transferred

	if bytes_read == 0 {
		// Connection closed
		socket.close_socket(socket_fd)
		iocp.free_io_data(io_data)
		return
	}

	// Process the request
	request_data := io_data.buffer[..bytes_read]
	response_data := handler(request_data, socket_fd) or {
		response.send_bad_request_response(socket_fd)
		socket.close_socket(socket_fd)
		iocp.free_io_data(io_data)
		return
	}

	// Prepare write operation
	write_io_data := iocp.create_io_data(socket_fd, .write, response_data.len)
	unsafe {
		C.memcpy(&write_io_data.buffer[0], response_data.data, response_data.len)
	}
	write_io_data.wsabuf.len = u32(response_data.len)

	// Post write operation
	flags := u32(0)
	result := iocp.post_send(socket_fd, &write_io_data.wsabuf, 1, flags, &write_io_data.overlapped)

	if result == socket.socket_error {
		error_code := C.WSAGetLastError()
		if error_code != 997 { // ERROR_IO_PENDING
			eprintln('[iocp-worker] WSASend failed: ${get_system_error()}')
			socket.close_socket(socket_fd)
			iocp.free_io_data(write_io_data)
		}
	}

	// Free read IO data
	iocp.free_io_data(io_data)

	// Prepare for next read (keep-alive)
	// In a real implementation, we'd parse the request to determine if keep-alive
	// For simplicity, we always post another read
	post_read_operation(socket_fd, ctx.iocp_handle)
}

fn handle_write_completion(io_data &iocp.IOData, mut ctx WorkerContext) {
	socket_fd := io_data.socket_fd

	// Check if all data was sent
	if io_data.bytes_transferred < io_data.wsabuf.len {
		// Partial write, adjust buffer and repost
		remaining := io_data.wsabuf.len - io_data.bytes_transferred
		unsafe {
			C.memmove(&io_data.buffer[0], &io_data.buffer[io_data.bytes_transferred],
				remaining)
		}
		io_data.wsabuf.len = remaining

		flags := u32(0)
		result := iocp.post_send(socket_fd, &io_data.wsabuf, 1, flags, &io_data.overlapped)

		if result == socket.socket_error {
			error_code := C.WSAGetLastError()
			if error_code != 997 { // ERROR_IO_PENDING
				socket.close_socket(socket_fd)
				iocp.free_io_data(io_data)
			}
		}
	} else {
		// Write completed
		iocp.free_io_data(io_data)
		// Note: We don't close the socket here to allow keep-alive
		// The next read operation was already posted in handle_read_completion
	}
}

fn post_read_operation(socket_fd int, iocp_handle voidptr) {
	read_io_data := iocp.create_io_data(socket_fd, .read, buffer_size)

	flags := u32(0)
	result := iocp.post_recv(socket_fd, &read_io_data.wsabuf, 1, &flags, &read_io_data.overlapped)

	if result == socket.socket_error {
		error_code := C.WSAGetLastError()
		if error_code != 997 { // ERROR_IO_PENDING
			eprintln('[iocp-worker] WSARecv failed: ${get_system_error()}')
			socket.close_socket(socket_fd)
			iocp.free_io_data(read_io_data)
		}
	}
}

fn accept_thread(listen_socket int, iocp_handle voidptr) {
	println('[iocp-accept] Accept thread started')

	for {
		// Create a new socket for the incoming connection
		accept_socket := int(C.socket(C.AF_INET, C.SOCK_STREAM, 0))
		if accept_socket == int(socket.invalid_socket) {
			eprintln('[iocp-accept] Failed to create accept socket')
			C.sleep(100)
			continue
		}

		// Prepare accept IO data
		accept_io_data := iocp.create_io_data(accept_socket, .accept, 0)

		// Start asynchronous accept
		if !iocp.start_accept_ex(listen_socket, accept_socket, &accept_io_data.overlapped) {
			error_code := C.WSAGetLastError()
			if error_code != 997 { // ERROR_IO_PENDING
				eprintln('[iocp-accept] AcceptEx failed: ${get_system_error()}')
				socket.close_socket(accept_socket)
				iocp.free_io_data(accept_io_data)
				C.sleep(100)
				continue
			}
		}

		// Wait for accept completion
		// In a real implementation, we'd use IOCP for accepts too
		// For simplicity, we're using AcceptEx synchronously here
		// A better implementation would post multiple AcceptEx operations
		result := C.WaitForSingleObject(voidptr(accept_io_data.overlapped.h_event), iocp.infinity)

		if result == 0 { // WAIT_OBJECT_0
			bytes_received := u32(0)
			C.GetOverlappedResult(voidptr(listen_socket), &accept_io_data.overlapped,
				&bytes_received, false)

			// Associate with IOCP and post read
			iocp.associate_handle_with_iocp(iocp_handle, accept_socket, u64(accept_socket)) or {
				eprintln('[iocp-accept] Failed to associate accepted socket: ${err}')
				socket.close_socket(accept_socket)
				iocp.free_io_data(accept_io_data)
				continue
			}

			post_read_operation(accept_socket, iocp_handle)
			iocp.free_io_data(accept_io_data)
		} else {
			socket.close_socket(accept_socket)
			iocp.free_io_data(accept_io_data)
		}
	}

	println('[iocp-accept] Accept thread exiting')
}

pub fn run_iocp_backend(socket_fd int, handler fn ([]u8, int) ![]u8, port int, mut threads []thread) {
	println('[iocp] Starting IOCP backend on port ${port}')

	// Create IOCP handle
	iocp_handle := iocp.create_iocp(max_iocp_workers) or {
		eprintln('[iocp] Failed to create IOCP: ${err}')
		return
	}

	// Associate listening socket with IOCP
	iocp.associate_handle_with_iocp(iocp_handle, socket_fd, u64(socket_fd)) or {
		eprintln('[iocp] Failed to associate listening socket: ${err}')
		return
	}

	// Create worker threads
	mut worker_contexts := []&WorkerContext{cap: max_iocp_workers}
	for i in 0 .. max_iocp_workers {
		mut ctx := &WorkerContext{
			iocp_handle: iocp_handle
			handler:     handler
			running:     true
		}
		worker_contexts << ctx
		threads[i] = spawn worker_thread(mut ctx)
		println('[iocp] Started worker thread ${i}')
	}

	// Start accept thread
	accept_thread_id := spawn accept_thread(socket_fd, iocp_handle)

	println('listening on http://localhost:${port}/ (IOCP)')

	// Wait for shutdown signal (in real implementation, this would be controlled)
	mut dummy := 0
	C.scanf('%d', &dummy)

	// Shutdown all workers
	for mut ctx in worker_contexts {
		ctx.running = false
		iocp.post_iocp_status(iocp_handle, 0, 0, unsafe { nil })
	}

	// Wait for workers to finish
	for i in 0 .. max_iocp_workers {
		threads[i].wait()
	}

	// Close IOCP handle
	C.CloseHandle(iocp_handle)

	println('[iocp] Server stopped')
}

pub fn (mut server Server) run() {
	$if windows {
		run_iocp_backend(server.socket_fd, server.request_handler, server.port, mut server.threads)
	} $else {
		eprintln('Windows IOCP backend only works on Windows')
		exit(1)
	}
}
