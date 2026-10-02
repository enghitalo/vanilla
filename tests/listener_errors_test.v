// new_server returns listener failures to its caller instead of exit(1)-ing
// the process from inside the library (issue #188): this binary surviving to
// run its asserts is half of each test. The other half is that a failed
// new_server leaves nothing open behind it. Bind-level only: no run(), no
// traffic.
import os
import net
import server
import core
import socket

$if linux {
	#include <sys/resource.h>
}

struct C.rlimit {
mut:
	rlim_cur u64
	rlim_max u64
}

fn C.getrlimit(resource int, rlim &C.rlimit) int
fn C.setrlimit(resource int, rlim &C.rlimit) int

fn noop_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	return .close
}

// lowest_free_fd is the number the kernel gives the next new fd. The same
// value before and after a failed new_server means it closed what it opened.
fn lowest_free_fd() !int {
	mut f := os.open('/dev/null')!
	fd := f.fd
	f.close()
	return fd
}

// A port held by a plain (non-SO_REUSEPORT) listener makes bind fail with
// EADDRINUSE. The error names the step and carries errno as its code.
fn test_port_in_use_is_returned_not_exited() ! {
	mut holder := net.listen_tcp(.ip, '0.0.0.0:0')!
	defer {
		holder.close() or {}
	}
	port := int(holder.addr()!.port()!)
	before := lowest_free_fd()!
	srv := server.new_server(server.ServerConfig{
		port:    port
		handler: noop_handler
	}) or {
		assert err.code() == C.EADDRINUSE, err.msg()
		assert err.msg().starts_with('bind 0.0.0.0:${port}: '), err.msg()
		assert lowest_free_fd()! == before, 'the listener whose bind failed was not closed'
		return
	}
	for fd in srv.listener_fds {
		socket.close_socket(fd)
	}
	assert false, 'new_server bound port ${port}, which is already in use'
}

// io_uring opens one SO_REUSEPORT listener per worker. When a later one
// fails, the ones already open must be closed too: a leaked listener stays in
// the port's group, takes a share of its connections and never accepts them.
// RLIMIT_NOFILE is lowered so exactly one more fd fits: the first listener
// opens, the second fails with EMFILE.
fn test_failed_worker_listener_closes_the_open_ones() ! {
	$if linux {
		before := lowest_free_fd()!
		mut saved := C.rlimit{}
		assert C.getrlimit(C.RLIMIT_NOFILE, &saved) == 0
		mut one_more := saved
		one_more.rlim_cur = u64(before + 1)
		assert C.setrlimit(C.RLIMIT_NOFILE, &one_more) == 0
		srv := server.new_server(server.ServerConfig{
			port:            0
			io_multiplexing: .io_uring
			handler:         noop_handler
			workers:         4
		}) or {
			C.setrlimit(C.RLIMIT_NOFILE, &saved)
			assert err.code() == C.EMFILE, err.msg()
			assert lowest_free_fd()! == before, 'the first worker listener was not closed'
			return
		}
		C.setrlimit(C.RLIMIT_NOFILE, &saved)
		for fd in srv.listener_fds {
			socket.close_socket(fd)
		}
		assert false, 'new_server opened ${srv.listener_fds.len} listeners with room for one'
	}
}
