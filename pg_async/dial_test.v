// vtest build: !windows
module pg_async

import time
import testkit

#include <netinet/tcp.h>

// Dial hardening (#191 fix 5): every resolved address is tried in turn, each
// connect is bounded by connect_timeout_ms, and every socket is tuned with
// TCP_NODELAY, keepalive and TCP_USER_TIMEOUT. Runs against the fake server
// (pg_async/testdata/fake_pg.py); skipped without python3 unless
// VANILLA_REQUIRE_FAKE_PG is set.

fn dial_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// closed_port returns a loopback port nothing listens on (bound, then closed).
fn closed_port() int {
	addrs := resolve('127.0.0.1', 0) or { panic(err) }
	fd := C.socket(addrs[0].family, C.SOCK_STREAM, 0)
	assert fd >= 0
	assert C.bind(fd, voidptr(&addrs[0].data[0]), addrs[0].len) == 0
	mut sa := [128]u8{}
	mut sl := u32(128)
	assert C.getsockname(fd, voidptr(&sa[0]), &sl) == 0
	port := (int(sa[2]) << 8) | int(sa[3]) // sockaddr_in.sin_port, network order
	C.close(fd)
	return port
}

fn C.bind(fd int, addr voidptr, len u32) int
fn C.getsockname(fd int, addr voidptr, len &u32) int

fn assert_tuned(fd int) {
	assert C.pg_async_getsockopt_int(fd, C.IPPROTO_TCP, C.TCP_NODELAY) != 0, 'TCP_NODELAY not set'
	assert C.pg_async_getsockopt_int(fd, C.SOL_SOCKET, C.SO_KEEPALIVE) != 0, 'SO_KEEPALIVE not set'
	$if linux {
		assert C.pg_async_getsockopt_int(fd, C.IPPROTO_TCP, C.TCP_KEEPIDLE) == 30
		assert C.pg_async_getsockopt_int(fd, C.IPPROTO_TCP, C.TCP_KEEPINTVL) == 10
		assert C.pg_async_getsockopt_int(fd, C.IPPROTO_TCP, C.TCP_KEEPCNT) == 3
		assert C.pg_async_getsockopt_int(fd, C.IPPROTO_TCP, C.TCP_USER_TIMEOUT) == 30_000
	}
}

fn test_every_connection_is_tuned() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping dial tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(dial_cfg(fake.port))!
	assert_tuned(c.fd)
	c.close()
	// The pool's connections come from the same dial.
	mut pool := new_pool(dial_cfg(fake.port), 2)!
	for i in 0 .. pool.size() {
		assert_tuned(pool.fd(i))
	}
	pool.close()
	// Opting out leaves Nagle on, and keepalive 0 leaves keepalive off.
	mut c2 := PgConn.connect(ConnConfig{
		...dial_cfg(fake.port)
		tcp_nodelay:          false
		tcp_keepalive_idle_s: 0
	})!
	assert C.pg_async_getsockopt_int(c2.fd, C.IPPROTO_TCP, C.TCP_NODELAY) == 0
	assert C.pg_async_getsockopt_int(c2.fd, C.SOL_SOCKET, C.SO_KEEPALIVE) == 0
	c2.close()
}

fn test_dial_falls_over_to_the_next_address() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	dead := resolve('127.0.0.1', closed_port())!
	live := resolve('127.0.0.1', fake.port)!
	addrs := [dead[0], live[0]]
	cfg := dial_cfg(fake.port)
	// Blocking (bring-up): the refused first address is skipped.
	fd := dial_addrs(addrs, &cfg, false, 0)!
	assert_tuned(fd)
	C.close(fd)
	// Non-blocking (re-dial): a refused loopback connect fails asynchronously,
	// so the attempt fails later and redial_failed moves addr_cursor on; the
	// next attempt then starts at the live address.
	fd2 := dial_addrs(addrs, &cfg, true, 1)!
	assert C.pg_async_wait(fd2, C.POLLOUT, 2000) > 0
	assert C.pg_async_getsockopt_int(fd2, C.SOL_SOCKET, C.SO_ERROR) == 0
	C.close(fd2)
	// Every address failing is one error naming the count.
	if _ := dial_addrs([dead[0], dead[0]], &cfg, false, 0) {
		assert false, 'expected every address to be refused'
	} else {
		assert err.msg().contains('failed on all 2 address(es)'), err.msg()
	}
}

fn test_redial_failure_moves_to_the_next_address() {
	mut c := PgConn{}
	assert c.addr_cursor == 0
	c.redial_failed(time.sys_mono_now())
	c.redial_failed(time.sys_mono_now())
	assert c.addr_cursor == 2
	assert c.state == .broken
}

fn test_connect_timeout_bounds_an_unreachable_address() {
	// 10.255.255.1 is not routed on a normal host: a SYN to it is dropped, so
	// the connect would wait for the kernel's ~2 min retry budget. Some hosts
	// answer ENETUNREACH right away instead; either way it fails fast.
	unroutable := resolve('10.255.255.1', 5432)!
	cfg := ConnConfig{
		connect_timeout_ms: 300
	}
	sw := time.new_stopwatch()
	if _ := dial_addrs(unroutable, &cfg, false, 0) {
		assert false, 'expected an unroutable address to fail'
	}
	assert sw.elapsed().milliseconds() < 2000, 'connect_timeout_ms did not bound the connect'
}

fn test_localhost_reaches_an_ipv4_only_server() {
	if !testkit.fake_pg_available() {
		return
	}
	addrs := resolve('localhost', 5432) or { return }
	if addrs.len < 2 || addrs[0].family != C.AF_INET6 {
		eprintln('pg_async: localhost does not resolve to ::1 first here; skipping the IPv6-first case')
		return
	}
	// The fake listens on 127.0.0.1 only: the first address (::1) is refused,
	// and the old single-address dial failed here.
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(ConnConfig{ ...dial_cfg(fake.port), host: 'localhost' })!
	res := c.query('select 5', []?[]u8{})!
	mut it := res.rows()
	assert (it.next() or { panic('expected a row') }).int4(0)! == 5
	c.close()
}
