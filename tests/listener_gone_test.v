// vtest build: linux
// Once its listener is gone, an acceptor must stop, not retry (#163).
// Server.shutdown() shuts the listener down, then closes it, from another
// thread. The epoll acceptor retried every accept() error at once except
// EAGAIN and the out-of-fds ones, so when the close landed between its wake
// and its accept() it spun for the rest of the process: on EBADF, then on
// ENOTSOCK or EINVAL once the number was reused, two stderr lines per turn
// (2.5M "Accept failed: Socket operation on non-socket" in one test process,
// CI run 38019823587). Before the close, a shut-down listener reports EPOLLHUP
// (and EPOLLIN, on AF_UNIX) on every wait, which spun it through epoll_wait.
//
// Each check builds one of those states on purpose, then asserts that the
// process stays near idle:
//   - the listener is shut down but not closed yet (TCP and AF_UNIX);
//   - the listener's number is closed (EBADF), or names a file (ENOTSOCK) or
//     a socket that is not listening (EINVAL), while the listening socket stays
//     open under another number: epoll watches the socket, not the number, so a
//     client still wakes the acceptor, whose accept() then fails. That is the
//     close landing between the wake and the accept(), every time.
// The poll reactor polls the number itself: a file or a socket that took it
// can poll readable for good, and its accept() fails the same way. io_uring
// stopped re-arming its accept only once Server.shutdown() had set the
// draining flag: a listener shut down without it spun the worker.
import os
import server
import core
import testkit
import time
import transport
import vtest

#include <fcntl.h>
#include <sys/socket.h>

fn C.clock() i64 // this process's CPU time, in CLOCKS_PER_SEC (1e6 on POSIX) units
fn C.open(path &char, flags int) int
fn C.close(fd int) int
fn C.dup(fd int) int
fn C.dup2(oldfd int, newfd int) int
fn C.shutdown(fd int, how int) int
fn C.socket(domain int, typ int, protocol int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.connect(fd int, addr voidptr, len u32) int

const lg_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
const lg_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

fn lg_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	core.append_str(mut out, lg_ok)
	return .done
}

// What took the listener's number.
enum Lost {
	closed // nothing: accept() fails with EBADF
	file   // /dev/null, readable for good: ENOTSOCK
	socket // a connected socket with a byte to read: EINVAL
}

fn lg_start(backend server.IOBackend, path string) !&vtest.Harness {
	return vtest.start(server.ServerConfig{
		io_multiplexing:  backend
		unix_socket_path: path
		handler:          lg_handler
		workers:          2
	})!
}

// lg_serves proves the acceptor is up: one request, one response.
fn lg_serves(h &vtest.Harness, path string) ! {
	fd := if path != '' {
		transport.dial_unix(path)!
	} else {
		transport.dial_tcp('127.0.0.1', h.port())!
	}
	defer {
		transport.close_fd(fd)
	}
	assert testkit.fd_write_all(fd, lg_req.bytes(), 2000)
	got := testkit.fd_read_until(fd, lg_ok, 2000)
	assert got == lg_ok, 'the server did not answer: ${got}'
}

// cpu_us_while_idle is the CPU time the whole process used over `ms`, while
// the test thread itself sleeps.
fn cpu_us_while_idle(ms int) i64 {
	cpu0 := C.clock()
	time.sleep(time.Duration(ms) * time.millisecond)
	return C.clock() - cpu0
}

// check_listener_shut_down does what Server.shutdown() does first, without
// the close that follows it.
fn check_listener_shut_down(backend server.IOBackend, uds bool) ! {
	path := if uds { os.join_path(os.temp_dir(), 'vanilla_lg_${os.getpid()}.sock') } else { '' }
	mut h := lg_start(backend, path)!
	defer {
		h.stop()
	}
	lg_serves(h, path)!
	assert C.shutdown(h.server_ref().socket_fd, C.SHUT_RDWR) == 0
	cpu := cpu_us_while_idle(300)
	assert cpu < 60_000, '${backend}, uds ${uds}: spun on a shut-down listener: ${cpu} us of CPU in 300 ms'
}

// check_listener_number_lost has `lost` take the listener's number while the
// socket stays open as `keep`, then connects a client.
fn check_listener_number_lost(backend server.IOBackend, lost Lost) ! {
	mut h := lg_start(backend, '')!
	defer {
		h.stop()
	}
	lg_serves(h, '')!
	lfd := h.server_ref().socket_fd
	keep := C.dup(lfd)
	assert keep >= 0
	// Made before the number is freed, so the client can't take it.
	client := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	assert client >= 0
	mut other := [i32(-1), -1]! // C ints
	match lost {
		.closed {
			C.close(lfd)
		}
		.file {
			other[0] = i32(C.open(c'/dev/null', C.O_RDONLY))
			assert other[0] >= 0
			assert C.dup2(other[0], lfd) == lfd
		}
		.socket {
			assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &other[0]) == 0
			assert testkit.fd_write_all(other[1], [u8(`x`)], 2000)
			assert C.dup2(other[0], lfd) == lfd
		}
	}
	addr := transport.ip_addr('127.0.0.1', h.port()) or { return error('no address') }
	connected := C.connect(client, voidptr(&addr.data[0]), addr.len) == 0
	cpu := cpu_us_while_idle(300)
	// Put the listener back on its number for h.stop() (dup2 closes what took
	// it), then drop the rest.
	C.dup2(keep, lfd)
	C.close(keep)
	C.close(client)
	for fd in other {
		if fd >= 0 {
			C.close(fd)
		}
	}
	assert connected, '${backend}, ${lost}: the client could not connect'
	assert cpu < 60_000, '${backend}, ${lost}: spun once the listener number was lost: ${cpu} us of CPU in 300 ms'
}

fn test_epoll_acceptor_stops_on_shut_down_listener() ! {
	check_listener_shut_down(.epoll, false)!
	check_listener_shut_down(.epoll, true)!
}

fn test_epoll_acceptor_stops_when_listener_number_is_lost() ! {
	check_listener_number_lost(.epoll, .closed)!
	check_listener_number_lost(.epoll, .file)!
	check_listener_number_lost(.epoll, .socket)!
}

// TCP only, one server (an io_uring server's rings outlive it, #153): the
// AF_UNIX shutdown(2) completes no accept on io_uring (see Server.shutdown),
// and an armed accept holds the listening socket itself, not its number.
fn test_iouring_acceptor_stops_on_shut_down_listener() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
		return
	}
	check_listener_shut_down(.io_uring, false)!
}

fn test_poll_acceptor_stops_on_shut_down_listener() ! {
	$if vanilla_poll ? {
		check_listener_shut_down(.poll, false)!
		check_listener_shut_down(.poll, true)!
	}
}

fn test_poll_acceptor_stops_when_listener_number_is_lost() ! {
	$if vanilla_poll ? {
		check_listener_number_lost(.poll, .closed)!
		check_listener_number_lost(.poll, .file)!
		check_listener_number_lost(.poll, .socket)!
	}
}
