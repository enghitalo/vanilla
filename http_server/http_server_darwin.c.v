// http_server_darwin.c.v
// Darwin (macOS)-specific HTTP server entry point or helpers

module http_server

import kqueue
import socket
import response
import request

pub fn run(mut server Server) {
	match server.io_multiplexing {
		.kqueue_backend {
			server.run_kqueue()
		}
		else {
			eprintln('Selected io_multiplexing is not supported on Darwin/macOS.')
			exit(1)
		}
	}
}

fn (mut server Server) run_kqueue() {
	server.socket_fd = socket.create_server_socket(server.port)
	if server.socket_fd < 0 {
		return
	}

	kq_fd := kqueue.create_kqueue_fd()
	if kq_fd < 0 {
		socket.close_socket(server.socket_fd)
		eprintln('Failed to create kqueue fd')
		exit(1)
	}

	if kqueue.add_fd_to_kqueue(kq_fd, server.socket_fd, -1) < 0 { // -1 = EVFILT_READ
		socket.close_socket(server.socket_fd)
		C.close(kq_fd)
		eprintln('Failed to add server socket to kqueue')
		exit(1)
	}

	mut callbacks := kqueue.KqueueEventCallbacks{
		on_read: fn [handler := server.request_handler, kq_fd] (fd int) {
			// Accept new connection
			mut addr := socket.C.sockaddr_in{}
			mut addrlen := u32(sizeof(socket.C.sockaddr_in))
			client_fd := C.accept(fd, &addr, &addrlen)
			if client_fd < 0 {
				C.perror(c'accept')
				return
			}
			// Set non-blocking
			socket.set_blocking(client_fd, false)
			// Register client fd for read events
			kqueue.add_fd_to_kqueue(kq_fd, client_fd, -1)
		},
		on_write: fn (_ int) {},
	}

	for i in 0 .. max_thread_pool_size {
		server.threads[i] = spawn kqueue.process_kqueue_events(callbacks, kq_fd)
	}

	println('listening on http://localhost:${server.port}/ (kqueue)')

	// Keep main thread alive
	for {
		C.sleep(1)
	}
}
