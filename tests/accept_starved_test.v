// vtest build: linux
// Out of fds, accept() fails with EMFILE until one is freed. Every Linux
// backend must then pause accepting rather than retry at once (issue #256).
// Before, the epoll acceptor spun at 100% CPU and wrote two stderr lines per
// attempt, io_uring spun the worker that owned the connection's listener, and
// poll spun every worker, all until an fd was freed.
//
// Each check lowers RLIMIT_NOFILE, fills the fd table with /dev/null, and
// asserts the server stays near idle in two states:
//   1. the server's own accept took the last free fd. On a full table Linux
//      fails accept4() with EMFILE before it looks at the backlog, so the next
//      accept fails with nothing pending;
//   2. a client waits in the backlog that the server can't accept.
// Then it frees an fd, and the waiting client must be served. Last, it shuts
// the server down during a pause, which must not re-arm an accept or spin.
//
// The limit is lowered BEFORE new_server: io_uring copies RLIMIT_NOFILE into
// each accept SQE when it prepares it, so a limit lowered later would not
// reach the accept already armed.
import server
import core
import sync.stdatomic
import testkit
import time
import transport
import vtest

#include <sys/resource.h>
#include <fcntl.h>

struct C.rlimit {
mut:
	rlim_cur u64
	rlim_max u64
}

fn C.getrlimit(resource int, rlim &C.rlimit) int
fn C.setrlimit(resource int, rlim &C.rlimit) int
fn C.clock() i64 // this process's CPU time, in CLOCKS_PER_SEC (1e6 on POSIX) units
fn C.open(path &char, flags int) int
fn C.close(fd int) int

const as_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
const as_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const as_workers = 2

// Workers that have reached make_state. An io_uring worker creates its ring
// (an fd) on its own thread after run() reports the server started, and only
// then calls make_state: the fd table may be filled once all have.
const as_ready = &core.Counter{}

fn as_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	core.append_str(mut out, as_ok)
	return .done
}

fn as_make_state() voidptr {
	stdatomic.add_i64(&as_ready.n, 1)
	return unsafe { nil }
}

fn lowest_free_fd() int {
	fd := C.open(c'/dev/null', C.O_RDONLY)
	C.close(fd)
	return fd
}

// as_dial connects to the server; the connection completes from the listen
// backlog whether or not the server can accept it.
fn as_dial(port int) !int {
	fd := transport.dial_tcp('127.0.0.1', port)!
	if !testkit.fd_wait_writable(fd, 2000) {
		transport.close_fd(fd)
		return error('connect to ${port} did not complete')
	}
	return fd
}

// round_trip sends one request on `fd` and returns what came back within 2 s.
fn round_trip(fd int) string {
	if !testkit.fd_write_all(fd, as_req.bytes(), 2000) {
		return 'the request could not be written'
	}
	return testkit.fd_read_until(fd, as_ok, 2000)
}

// cpu_us_while_idle is the CPU time the whole process used over `ms`, while
// the test thread itself sleeps.
fn cpu_us_while_idle(ms int) i64 {
	cpu0 := C.clock()
	time.sleep(time.Duration(ms) * time.millisecond)
	return C.clock() - cpu0
}

fn check_accept_pauses_when_out_of_fds(backend server.IOBackend) ! {
	mut saved := C.rlimit{}
	assert C.getrlimit(C.RLIMIT_NOFILE, &saved) == 0
	// Room for the server's own fds (listeners, epoll, eventfd and ring fds).
	mut capped := saved
	capped.rlim_cur = u64(lowest_free_fd() + 64)
	assert C.setrlimit(C.RLIMIT_NOFILE, &capped) == 0
	defer {
		C.setrlimit(C.RLIMIT_NOFILE, &saved)
	}
	mut fillers := []int{}
	mut clients := []int{}
	defer {
		for fd in clients {
			transport.close_fd(fd)
		}
		for fd in fillers {
			C.close(fd)
		}
	}
	stdatomic.store_i64(&as_ready.n, 0)
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         as_handler
		make_state:      as_make_state
		workers:         as_workers
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	for stdatomic.load_i64(&as_ready.n) < as_workers && sw.elapsed() < 10 * time.second {
		time.sleep(time.millisecond)
	}
	assert stdatomic.load_i64(&as_ready.n) == as_workers, '${backend}: the workers did not start'
	for {
		fd := C.open(c'/dev/null', C.O_RDONLY)
		if fd < 0 {
			break
		}
		fillers << fd
	}

	// 1. Two free fds: client A takes one, the server's accept of A the other.
	C.close(fillers.pop())
	C.close(fillers.pop())
	clients << as_dial(h.port())!
	reply_a := round_trip(clients[0])
	assert reply_a == as_ok, '${backend}: client A was not served: ${reply_a}'
	assert lowest_free_fd() < 0, '${backend}: the fd table should be full'
	cpu_full := cpu_us_while_idle(300)
	assert cpu_full < 60_000, '${backend}: spun with the fd table full and nothing pending: ${cpu_full} us of CPU in 300 ms'

	// 2. One free fd: client B's socket takes it, so the server can't accept B.
	C.close(fillers.pop())
	clients << as_dial(h.port())!
	cpu_waiting := cpu_us_while_idle(500)
	assert cpu_waiting < 100_000, '${backend}: spun on EMFILE with a client waiting: ${cpu_waiting} us of CPU in 500 ms'

	// One fd frees up: the paused accept takes B within a pause, and B is served.
	C.close(fillers.pop())
	reply_b := round_trip(clients[1])
	assert reply_b == as_ok, '${backend}: the waiting client was not served once an fd was free: ${reply_b}'

	// 3. Shut down while paused (client C waits, as B did): the pause must end
	// without re-arming an accept or spinning.
	C.close(fillers.pop())
	clients << as_dial(h.port())!
	cpu_paused := cpu_us_while_idle(200)
	assert cpu_paused < 40_000, '${backend}: spun on EMFILE with client C waiting: ${cpu_paused} us of CPU in 200 ms'
	h.stop()
	cpu_stopped := cpu_us_while_idle(300)
	assert cpu_stopped < 60_000, '${backend}: spun after a shutdown during an accept pause: ${cpu_stopped} us of CPU in 300 ms'
}

fn test_iouring_accept_pauses_when_out_of_fds() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
		return
	}
	check_accept_pauses_when_out_of_fds(.io_uring)!
}

fn test_poll_accept_pauses_when_out_of_fds() ! {
	$if vanilla_poll ? {
		check_accept_pauses_when_out_of_fds(.poll)!
	}
}

fn test_epoll_accept_pauses_when_out_of_fds() ! {
	check_accept_pauses_when_out_of_fds(.epoll)!
}
