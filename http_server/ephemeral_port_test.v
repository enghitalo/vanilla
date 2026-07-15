module http_server

// port: 0 = ephemeral bind. new_server must resolve the kernel-assigned port ONCE
// and use it everywhere: Server.port carries the real port, and (io_uring) every
// per-worker listener binds that SAME port so the SO_REUSEPORT group actually
// forms — with a raw config.port each listener would get a DIFFERENT ephemeral
// port and no load balancing would happen. Bind-level assertions only: no run(),
// so the listeners are closed by hand at the end.
import http_server.socket
import http_server.core

fn ep_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	return .done
}

fn test_port_zero_resolves_to_real_port() ! {
	mut server := new_server(ServerConfig{
		port:    0
		handler: ep_handler
	})!
	assert server.port > 0, 'Server.port must carry the kernel-assigned port'
	assert socket.local_port(server.socket_fd) == server.port
	for fd in server.listener_fds {
		socket.close_socket(fd)
	}
}

fn test_port_zero_io_uring_listeners_share_one_port() ! {
	$if linux {
		mut server := new_server(ServerConfig{
			port:            0
			io_multiplexing: .io_uring
			handler:         ep_handler
			workers:         4
		})!
		assert server.port > 0
		assert server.listener_fds.len == 4
		for fd in server.listener_fds {
			assert socket.local_port(fd) == server.port, 'every SO_REUSEPORT listener must hold the SAME resolved port'
		}
		for fd in server.listener_fds {
			socket.close_socket(fd)
		}
	}
}

fn test_explicit_port_is_untouched() ! {
	mut server := new_server(ServerConfig{
		port:    18990
		handler: ep_handler
	})!
	assert server.port == 18990
	assert socket.local_port(server.socket_fd) == 18990
	for fd in server.listener_fds {
		socket.close_socket(fd)
	}
}
