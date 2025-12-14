module http_server

import runtime
import epoll
import socket
import request
import response

const max_thread_pool_size = runtime.nr_cpus()

#include <errno.h>

$if !windows {
	#include <sys/epoll.h>
}

fn C.perror(s &u8)

pub struct Server {
pub:
	port int = 3000
pub mut:
	socket_fd       int
	threads         []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	request_handler fn ([]u8, int) ![]u8 @[required]
}

// Socket and epoll helpers moved to dedicated files: socket.v, epoll.v, response.v, request.v

// Handles readable client connection: recv, route, and send response.
// Extracted to simplify the event loop.
fn handle_readable_fd(request_handler fn ([]u8, int) ![]u8, epoll_fd int, client_conn_fd int) {
	request_buffer := request.read_request(client_conn_fd) or {
		eprintln('Error reading request: ${err}')
		response.send_status_444_response(client_conn_fd)
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}

	defer {
		unsafe { request_buffer.free() }
	}

	response_buffer := request_handler(request_buffer, client_conn_fd) or {
		eprintln('Error handling request: ${err}')
		response.send_bad_request_response(client_conn_fd)
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}

	response.send_response(client_conn_fd, response_buffer.data, response_buffer.len) or {
		epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
		return
	}
}

fn handle_accept_loop(socket_fd int, main_epoll_fd int, epoll_fds []int) {
	mut next_worker := 0
	mut event := C.epoll_event{}

	for {
		num_events := C.epoll_wait(main_epoll_fd, &event, 1, -1)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}

		if num_events > 1 {
			eprintln('More than one event in epoll_wait, this should not happen.')
			continue
		}

		if event.events & u32(C.EPOLLIN) != 0 {
			for {
				client_conn_fd := C.accept(socket_fd, C.NULL, C.NULL)
				if client_conn_fd < 0 {
					// Check for EAGAIN or EWOULDBLOCK, usually represented by errno 11.
					if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
						break // No more incoming connections; exit loop.
					}
					eprintln(@LOCATION)
					C.perror(c'Accept failed')
					continue
				}
				socket.set_blocking(client_conn_fd, false)
				// Load balance the client connection to the worker threads.
				// this is a simple round-robin approach.
				epoll_fd := epoll_fds[next_worker]
				next_worker = (next_worker + 1) % max_thread_pool_size
				if epoll.add_fd_to_epoll(epoll_fd, client_conn_fd, u32(C.EPOLLIN | C.EPOLLET)) < 0 {
					socket.close_socket(client_conn_fd)
					continue
				}
			}
		}
	}
}

@[direct_array_access; manualfree]
fn process_events(event_callbacks epoll.EpollEventCallbacks, epoll_fd int) {
	mut events := [socket.max_connection_size]C.epoll_event{}

	for {
		num_events := C.epoll_wait(epoll_fd, &events[0], socket.max_connection_size, -1)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			eprintln(@LOCATION)
			C.perror(c'epoll_wait')
			break
		}

		for i in 0 .. num_events {
			client_conn_fd := unsafe { events[i].data.fd }
			if events[i].events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				epoll.remove_fd_from_epoll(epoll_fd, client_conn_fd)
				continue
			}

			if events[i].events & u32(C.EPOLLIN) != 0 {
				event_callbacks.on_read(client_conn_fd)
			}

			if events[i].events & u32(C.EPOLLOUT) != 0 {
				event_callbacks.on_write(client_conn_fd)
			}
		}
	}
}

pub fn (mut server Server) run() {
	$if windows {
		eprintln('Windows is not supported yet. Please, use WSL or Linux.')
		exit(1)
	}

	server.socket_fd = socket.create_server_socket(server.port)
	if server.socket_fd < 0 {
		return
	}

	main_epoll_fd := epoll.create_epoll_fd()
	if main_epoll_fd < 0 {
		socket.close_socket(server.socket_fd)
		exit(1)
	}

	if epoll.add_fd_to_epoll(main_epoll_fd, server.socket_fd, u32(C.EPOLLIN)) < 0 {
		socket.close_socket(server.socket_fd)
		socket.close_socket(main_epoll_fd)
		exit(1)
	}

	mut epoll_fds := []int{len: max_thread_pool_size, cap: max_thread_pool_size}
	unsafe { epoll_fds.flags.set(.noslices | .noshrink | .nogrow) }
	for i in 0 .. max_thread_pool_size {
		epoll_fds[i] = epoll.create_epoll_fd()
		if epoll_fds[i] < 0 {
			C.perror(c'epoll_create1')
			for j in 0 .. i {
				socket.close_socket(epoll_fds[j])
			}
			socket.close_socket(main_epoll_fd)
			socket.close_socket(server.socket_fd)
			exit(1)
		}

		// Build per-thread callbacks: default to handle_readable_fd; write is a no-op.
		epfd := epoll_fds[i]
		handler := server.request_handler
		callbacks := epoll.EpollEventCallbacks{
			on_read:  fn [handler, epfd] (fd int) {
				handle_readable_fd(handler, epfd, fd)
			}
			on_write: fn (_ int) {}
		}
		server.threads[i] = spawn process_events(callbacks, epoll_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	handle_accept_loop(server.socket_fd, main_epoll_fd, epoll_fds)
}
