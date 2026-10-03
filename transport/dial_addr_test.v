// vtest build: !windows
module transport

// dial_addr (#229 phase 2): IPv4 and IPv6, close-on-exec, tuned, and no
// allocation on a failed dial.
#include <netinet/tcp.h>
#include <poll.h>

fn C.bind(fd int, addr voidptr, len u32) int
fn C.listen(fd int, backlog int) int
fn C.getsockname(fd int, addr voidptr, len &u32) int
fn C.getsockopt(fd int, level int, name int, val voidptr, len &u32) int
fn C.poll(fds voidptr, n u64, timeout int) int

// listener binds a blocking listener on `ip` port 0 and returns its fd and the
// Addr to dial it; none where the family is unavailable (no IPv6).
fn listener(ip string) ?(int, Addr) {
	mut a := ip_addr(ip, 0) or { return none }
	fd := C.socket(a.family, C.SOCK_STREAM, 0)
	if fd < 0 {
		return none
	}
	if C.bind(fd, voidptr(&a.data[0]), a.len) != 0 || C.listen(fd, 8) != 0 {
		C.close(fd)
		return none
	}
	mut l := u32(a.data.len)
	C.getsockname(fd, voidptr(&a.data[0]), &l)
	return fd, a
}

fn opt(fd int, level int, name int) int {
	mut v := 0
	mut l := u32(4)
	if C.getsockopt(fd, level, name, voidptr(&v), &l) != 0 {
		return -1
	}
	return v
}

// wait_writable polls fd for POLLOUT (a connect completing) up to 2 s.
fn wait_writable(fd int) bool {
	mut p := [2]i32{} // struct pollfd: int fd; short events, revents
	p[0] = i32(fd)
	p[1] = i32(C.POLLOUT)
	return C.poll(voidptr(&p[0]), 1, 2000) == 1
}

fn test_dial_addr_ipv4_and_ipv6() {
	for ip in ['127.0.0.1', '::1'] {
		lfd, a := listener(ip) or {
			eprintln('transport: no ${ip} listener here; skipping it')
			continue
		}
		defer {
			C.close(lfd)
		}
		assert a.family == if ip == '::1' { C.AF_INET6 } else { C.AF_INET }
		fd := dial_addr(&a, TcpOpts{})
		assert fd >= 0, '${ip}: errno ${-fd}'
		assert wait_writable(fd), ip
		assert socket_error(fd) == 0, ip
		// Non-blocking, close-on-exec, and tuned per the TcpOpts defaults.
		assert C.fcntl(fd, C.F_GETFL, 0) & C.O_NONBLOCK != 0, ip
		assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0, ip
		assert opt(fd, C.IPPROTO_TCP, C.TCP_NODELAY) != 0, ip
		assert opt(fd, C.SOL_SOCKET, C.SO_KEEPALIVE) != 0, ip
		$if linux {
			assert opt(fd, C.IPPROTO_TCP, C.TCP_KEEPIDLE) == 30, ip
			assert opt(fd, C.IPPROTO_TCP, C.TCP_KEEPINTVL) == 10, ip
			assert opt(fd, C.IPPROTO_TCP, C.TCP_KEEPCNT) == 3, ip
			assert opt(fd, C.IPPROTO_TCP, C.TCP_USER_TIMEOUT) == 30_000, ip
		}
		close_fd(fd)
		// 0 leaves an option at the OS default.
		fd2 := dial_addr(&a, TcpOpts{
			nodelay:          false
			keepalive_idle_s: 0
			user_timeout_ms:  0
		})
		assert fd2 >= 0
		assert opt(fd2, C.IPPROTO_TCP, C.TCP_NODELAY) == 0
		assert opt(fd2, C.SOL_SOCKET, C.SO_KEEPALIVE) == 0
		$if linux {
			assert opt(fd2, C.IPPROTO_TCP, C.TCP_USER_TIMEOUT) == 0
		}
		close_fd(fd2)
	}
}

// A refused connect is reported either by dial_addr (-ECONNREFUSED) or, once
// the socket is writable, by socket_error.
fn test_dial_addr_refused() {
	lfd, a := listener('127.0.0.1') or { return }
	C.close(lfd) // nothing listens on that port now
	fd := dial_addr(&a, TcpOpts{})
	if fd < 0 {
		assert -fd == C.ECONNREFUSED
		return
	}
	assert wait_writable(fd)
	assert socket_error(fd) == C.ECONNREFUSED
	close_fd(fd)
}

fn test_ip_addr() {
	v4 := ip_addr('10.1.2.3', 443) or { panic('no v4') }
	assert v4.family == C.AF_INET
	assert v4.len == sizeof(C.transport_sockaddr_in)
	assert v4.data[2] == 1 && v4.data[3] == 0xbb // sin_port 443, network order
	assert v4.data[4] == 10 && v4.data[7] == 3
	v6 := ip_addr('2001:db8::1', 8443) or { panic('no v6') }
	assert v6.family == C.AF_INET6
	assert v6.data[2] == 0x20 && v6.data[3] == 0xfb
	// The literal may be a view into a longer string.
	s := '127.0.0.1:80'
	assert ip_addr(unsafe { tos(s.str, 9) }, 80) or { panic('view') }.family == C.AF_INET
	for bad in ['', 'localhost', 'api.example.com', '[::1]', '127.0.0.1:80', '1.2.3', '::1%lo',
		'x'.repeat(80)] {
		if _ := ip_addr(bad, 80) {
			assert false, bad
		}
	}
}

#include <malloc.h>

struct C.mallinfo2 {
	uordblks usize
	hblkhd   usize
}

fn C.mallinfo2() C.mallinfo2

// A failed dial allocates nothing (an error string per failed dial would leak
// under -gc none): 10,000 failed dials leave the heap where it was. Run with
// -gc none; the default GC and the sanitizers' allocators are invisible to
// mallinfo2.
fn test_failed_dial_allocates_nothing() {
	$if gcboehm ? {
		return
	}
	$if race ? {
		return
	}
	$if !linux {
		return
	}
	// sin_family AF_INET (little-endian sa_family_t), but too short for a
	// sockaddr_in: the connect fails with EINVAL at once, after socket() and
	// the tuning succeeded — the path that closes the fd and returns -errno.
	mut bad := Addr{
		family: C.AF_INET
		len:    3
	}
	bad.data[0] = u8(C.AF_INET)
	assert dial_addr(&bad, TcpOpts{}) == -C.EINVAL
	mi0 := C.mallinfo2()
	heap0 := i64(mi0.uordblks) + i64(mi0.hblkhd)
	if heap0 == 0 {
		return
	}
	for _ in 0 .. 10_000 {
		if dial_addr(&bad, TcpOpts{}) >= 0 {
			assert false
		}
		if _ := ip_addr('not-an-ip', 80) {
			assert false
		}
	}
	mi1 := C.mallinfo2()
	growth := i64(mi1.uordblks) + i64(mi1.hblkhd) - heap0
	assert growth < 1024, 'the heap grew ${growth} bytes over 10000 failed dials'
}
