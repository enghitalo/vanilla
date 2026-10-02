// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import os
import time
import testkit
import transport

// Connection health (#191), deterministic, against
// pg_async/testdata/fake_pg.py: a server that closes a connection right after
// a reply, sends FATAL 57P01 first, desyncs, or never answers; structured
// errors; the dialer's address list, timeouts and TCP options. (Each _test.v
// compiles alone, so the helpers are local.)

fn health_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// wait_readable waits until the socket has bytes (or EOF) to read, then a
// little longer, so what the server sent together is all buffered.
fn wait_readable(c &PgConn) {
	C.pg_async_wait(c.fd, C.POLLIN, 2000)
	time.sleep(30 * time.millisecond)
}

fn flush_all(mut c PgConn) {
	for _ in 0 .. 1000 {
		if c.async_flush() or { return } {
			return
		}
		time.sleep(time.millisecond)
	}
}

// poll_outcome pumps async_on_readable until the front query has an outcome.
fn poll_outcome(mut c PgConn) !Result {
	for _ in 0 .. 2000 {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		C.pg_async_wait(c.fd, C.POLLIN, 5)
	}
	return error('no outcome')
}

fn first_int4(res Result) int {
	mut it := res.rows()
	row := it.next() or { return -1 }
	return row.int4(0) or { -2 }
}

fn test_a_complete_result_followed_by_eof_is_a_success() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping connection-health tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'immediate'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	assert c.submit('select 1', []?[]u8{})!
	flush_all(mut c)
	wait_readable(c) // the reply and the server's FIN are both buffered now
	res := poll_outcome(mut c) or {
		assert false, 'the statement completed (ReadyForQuery arrived), yet: ${err.msg()}'
		return
	}
	assert first_int4(res) == 1
	// Only now, with the reply consumed, does the close count: nothing is in
	// flight, and a broken connection fails a call instead of answering
	// not-ready.
	assert c.is_broken()
	if poll := c.async_on_readable() {
		assert false, 'a broken connection answered ready=${poll.ready}'
	} else {
		assert err.msg() == 'pg: connection closed by server'
	}
	if _ := c.submit('select 2', []?[]u8{}) {
		assert false, 'a broken connection must refuse a query'
	} else {
		assert err is PgError
		if err is PgError {
			assert err.kind == .broken
		}
	}
	assert !c.async_submit('select 2', []?[]u8{})
}

fn test_the_servers_fatal_reaches_the_query_in_flight() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'fatal'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	assert c.submit('select 1', []?[]u8{})!
	flush_all(mut c)
	assert first_int4(poll_outcome(mut c)!) == 1
	// The server now sends FATAL 57P01 and closes; the next query meets it.
	time.sleep(200 * time.millisecond)
	assert c.submit('select 2', []?[]u8{})!
	flush_all(mut c)
	wait_readable(c)
	if _ := poll_outcome(mut c) {
		assert false, 'the connection was terminated'
	} else {
		assert err is PgError
		if err is PgError {
			assert err.kind == .unknown
			assert err.sqlstate == '57P01'
			assert err.severity == 'FATAL'
			assert err.message == 'terminating connection due to administrator command'
			assert err.msg() == 'pg: connection closed by server: terminating connection due to administrator command (SQLSTATE 57P01)'
		}
	}
	assert c.is_broken()
	assert c.inflight_count() == 0
}

fn test_queries_in_flight_on_a_dying_connection_end_once_each_in_order() {
	if !testkit.fake_pg_available() {
		return
	}
	// Answers the first query, then closes: the next two were sent and lost.
	mut fake := testkit.start_fake_pg(['--close', 'immediate'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	assert c.submit('select 1', []?[]u8{})!
	assert c.submit('select 2', []?[]u8{})!
	assert c.submit('select 3', []?[]u8{})!
	flush_all(mut c)
	wait_readable(c)
	assert first_int4(poll_outcome(mut c)!) == 1
	mut unknown := 0
	for _ in 0 .. 2 {
		poll := c.async_on_readable() or {
			if err is PgError {
				assert err.kind == .unknown
				assert err.msg() == 'pg: connection closed by server'
			}
			unknown++
			continue
		}
		assert false, 'query got an outcome it cannot have: ready=${poll.ready}'
	}
	assert unknown == 2
	assert c.inflight_count() == 0
	// Nothing left in flight: no Result is invented, and a broken connection
	// never answers not-ready (a stray caller must not re-arm a dead socket).
	if poll := c.async_on_readable() {
		assert false, 'a broken connection answered ready=${poll.ready}'
	} else {
		if err is PgError {
			assert err.kind == .unknown
		} else {
			assert false, 'not a PgError: ${err.msg()}'
		}
	}
}

fn test_a_reply_that_cannot_be_framed_breaks_the_connection() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--desync-after', '2'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	assert c.submit('select 1', []?[]u8{})!
	assert c.submit('select 2', []?[]u8{})!
	flush_all(mut c)
	assert first_int4(poll_outcome(mut c)!) == 1
	wait_readable(c)
	if _ := poll_outcome(mut c) {
		assert false, 'a garbage reply cannot complete a query'
	} else {
		if err is PgError {
			assert err.kind == .unknown
			assert err.msg() == 'pg: protocol desync: bad message length'
		} else {
			assert false, 'not a PgError: ${err.msg()}'
		}
	}
	assert c.is_broken()
}

fn test_a_failed_statement_is_a_structured_error_and_the_connection_survives() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	for round in 0 .. 3 {
		assert c.submit('select 1/0', []?[]u8{})!
		flush_all(mut c)
		if _ := poll_outcome(mut c) {
			assert false, 'division by zero must fail'
		} else {
			assert err is PgError
			if err is PgError {
				assert err.kind == .server
				assert err.sqlstate == '22012'
				assert err.severity == 'ERROR'
				assert err.message == 'division by zero'
				assert err.msg() == 'pg: query failed: division by zero (SQLSTATE 22012)'
				assert err.code() == int(PgErrorKind.server)
			}
		}
		assert !c.is_broken(), 'round ${round}'
	}
	// The blocking path reports the same.
	if _ := c.query('select 1/0', []?[]u8{}) {
		assert false
	} else {
		if err is PgError {
			assert err.kind == .server
			assert err.sqlstate == '22012'
		} else {
			assert false, 'blocking query: not a PgError'
		}
	}
	assert first_int4(c.query('select 7', []?[]u8{})!) == 7
}

fn test_dial_tries_every_address() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	// Nothing listens on 127.0.0.2 (the fake binds 127.0.0.1): the first
	// address is refused, the second answers.
	mut addrs := resolve('127.0.0.2', fake.port)!
	addrs << resolve('127.0.0.1', fake.port)!
	mut c := new_conn()
	mut cache := ScramCache{}
	cfg := health_cfg(fake.port)
	c.dial_blocking(addrs, &cfg, mut cache)!
	defer {
		c.close()
	}
	assert !c.is_broken()
	assert first_int4(c.query('select 3', []?[]u8{})!) == 3
}

fn test_a_server_that_never_answers_times_out() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--mute'])!
	defer {
		fake.stop()
	}
	cfg := ConnConfig{
		...health_cfg(fake.port)
		connect_timeout_ms: 300
	}
	sw := time.new_stopwatch()
	if _ := PgConn.connect(cfg) {
		assert false, 'a mute server cannot complete a handshake'
	} else {
		assert err.msg() == 'pg: startup timed out', err.msg()
		if err is PgError {
			assert err.kind == .connect
		}
	}
	el := sw.elapsed().milliseconds()
	assert el >= 250 && el < 2000, 'took ${el} ms'
}

fn test_connect_to_a_full_backlog_times_out() {
	$if !linux {
		return
	}
	// A listener that never accepts, its accept queue full: the kernel drops
	// further SYNs, so a connect just hangs — until connect_timeout_ms.
	lfd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	assert lfd >= 0
	defer {
		C.close(lfd)
	}
	mut probe := resolve('127.0.0.1', 0)!
	assert C.bind(lfd, voidptr(&probe[0].data[0]), probe[0].len) == 0
	assert C.listen(lfd, 0) == 0
	port := local_port(lfd)
	mut fillers := []int{}
	for _ in 0 .. 3 {
		a := resolve('127.0.0.1', port)!
		fillers << transport.dial_addr(voidptr(&a[0].data[0]), a[0].len)
	}
	defer {
		for f in fillers {
			C.close(f)
		}
	}
	time.sleep(50 * time.millisecond)
	cfg := ConnConfig{
		...health_cfg(port)
		connect_timeout_ms: 300
	}
	sw := time.new_stopwatch()
	if _ := PgConn.connect(cfg) {
		assert false, 'nothing accepts this connection'
	} else {
		assert err.msg() == 'pg: connect timed out', err.msg()
	}
	el := sw.elapsed().milliseconds()
	assert el >= 250 && el < 2000, 'took ${el} ms'
}

fn test_the_socket_is_tuned() {
	$if !linux {
		return
	}
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(health_cfg(fake.port))!
	defer {
		c.close()
	}
	assert c.tcp_option(C.TCP_NODELAY) == 1
	assert c.socket_option(C.SO_KEEPALIVE) == 1
	assert c.tcp_option(C.TCP_KEEPIDLE) == 30
	assert c.tcp_option(C.TCP_KEEPINTVL) == 10
	assert c.tcp_option(C.TCP_KEEPCNT) == 3
	assert c.tcp_option(C.TCP_USER_TIMEOUT) == 30_000
	assert C.fcntl(c.fd, C.F_GETFL, 0) & C.O_NONBLOCK != 0
}

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// pg_msg is one backend message: the type byte, the length, the payload.
fn pg_msg(typ u8, payload []u8) []u8 {
	mut m := [typ]
	n := u32(payload.len + 4)
	m << u8(n >> 24)
	m << u8(n >> 16)
	m << u8(n >> 8)
	m << u8(n)
	m << payload
	return m
}

fn test_bytes_after_the_startup_ready_for_query_stay_in_the_stream() {
	// The test plays the server, over a socketpair.
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	server := int(sv[1])
	defer {
		C.close(server)
	}
	mut c := new_conn()
	c.fd = int(sv[0])
	defer {
		c.close()
	}
	c.set_nonblocking()!
	cfg := ConnConfig{
		user:     'vanilla'
		database: 'vanilla'
	}
	mut cache := ScramCache{}
	c.begin_startup(&cfg, time.sys_mono_now())
	// AuthenticationOk, ReadyForQuery, then the first 3 bytes of a notice: a
	// notice can follow ReadyForQuery at any time, and arrive in pieces.
	mut fields := 'SNOTICE'.bytes()
	fields << 0
	fields << 'Mhello'.bytes()
	fields << 0
	fields << 0
	notice := pg_msg(`N`, fields)
	mut first := pg_msg(`R`, [u8(0), 0, 0, 0])
	first << pg_msg(`Z`, [u8(`I`)])
	first << notice[..3]
	C.write(server, first.data, usize(first.len))
	mut ready := false
	for _ in 0 .. 100 {
		if c.dial_step(&cfg, mut cache, time.sys_mono_now())! == .done {
			ready = true
			break
		}
		C.pg_async_wait(c.fd, C.POLLIN, 10)
	}
	assert ready
	// The rest of the notice, then the reply to `select 1`.
	assert c.submit('select 1', []?[]u8{})!
	flush_all(mut c)
	mut tag := 'SELECT 1'.bytes()
	tag << 0
	mut rest := notice[3..].clone()
	rest << pg_msg(`1`, []u8{})
	rest << pg_msg(`2`, []u8{})
	rest << pg_msg(`D`, [u8(0), 1, 0, 0, 0, 4, 0, 0, 0, 1])
	rest << pg_msg(`C`, tag)
	rest << pg_msg(`Z`, [u8(`I`)])
	C.write(server, rest.data, usize(rest.len))
	assert first_int4(poll_outcome(mut c)!) == 1
	assert !c.is_broken()
}

// fd_count is the number of open fds of this process.
fn fd_count() int {
	return (os.ls('/proc/self/fd') or { []string{} }).len
}

fn C.bind(sockfd int, addr voidptr, addrlen u32) int
fn C.listen(sockfd int, backlog int) int
fn C.getsockname(sockfd int, addr voidptr, addrlen &u32) int

// local_port is the port an IPv4 socket is bound to.
fn local_port(fd int) int {
	mut buf := [128]u8{}
	mut len := u32(128)
	C.getsockname(fd, voidptr(&buf[0]), &len)
	return int(u32(buf[2]) << 8 | u32(buf[3]))
}
