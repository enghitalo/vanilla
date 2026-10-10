// vtest build: !windows
module pg_async

import core
import os
import testkit
import time
import transport

// cancel() (vanilla#200): BackendKeyData kept at bring-up, then a
// CancelRequest on its own connection, driven as a background watch. Against
// pg_async/testdata/fake_pg.py, whose `select pg_sleep(S)` a matching
// CancelRequest interrupts with 57014, plain and (with -d vanilla_tls) over
// TLS; and against a live server when PGHOST is set. The background watch
// runs on CtLoop below, a stand-in for the epoll plain worker's clientless
// watches; the e2e on the real reactor is tests/pg_async_cancel_test.v.

// CtLoop runs one clientless watch at a time, as the epoll plain worker does:
// a continuation that re-arms its fd keeps it, .done closes the fd.
struct CtLoop {
mut:
	fd       int = -1
	interest core.WatchInterest
	cont     core.WakeFn = unsafe { nil }
	payload  voidptr
	runs     int
	refuse   bool // act as a worker without clientless watches
}

fn ct_register(mut w core.EventLoop, fd int, interest core.WatchInterest, cont core.WakeFn, payload voidptr) {
	mut l := unsafe { &CtLoop(w.reactor) }
	if w.client_fd >= 0 || l.refuse {
		w.last_watched = -1 // only clientless watches here
		return
	}
	l.fd = fd
	l.interest = interest
	l.cont = cont
	l.payload = payload
	w.last_watched = fd
}

// ct_loop is the event loop a handler or continuation would hand cancel():
// one for a request (client_fd 7), on the CtLoop.
fn ct_loop(l &CtLoop) core.EventLoop {
	return core.EventLoop{
		client_fd: 7
		reactor:   voidptr(l)
		register:  ct_register
	}
}

// run drives the armed watch until its continuation is done (true), or `ms`
// pass (false).
fn (mut l CtLoop) run(ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * u64(time.millisecond)
	mut scratch := []u8{}
	for l.fd >= 0 && time.sys_mono_now() < deadline {
		events := if l.interest == .readable { C.POLLIN } else { C.POLLOUT }
		r := C.pg_async_wait(l.fd, events, 10)
		if r == 0 {
			continue
		}
		fd := l.fd
		l.fd = -1
		mut el := core.EventLoop{
			client_fd: -1
			reactor:   voidptr(l)
			register:  ct_register
		}
		l.runs++
		step := l.cont(mut scratch, fd, r < 0 || r & (C.POLLERR | C.POLLHUP) != 0, l.payload,
			unsafe { nil }, mut el)
		if step == .suspend && el.last_watched == fd {
			continue
		}
		C.close(fd)
	}
	return l.fd < 0
}

fn ct_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// ct_submit submits a query and sends it.
fn ct_submit(mut c PgConn, query_text string) ! {
	if !c.async_submit(query_text, []?[]u8{}) {
		return error('submit refused')
	}
	for !c.async_flush()! {
		C.pg_async_wait(c.fd, C.POLLOUT, 10)
	}
}

// ct_wait pumps the front query's reply for at most `ms`.
fn ct_wait(mut c PgConn, ms int) !Result {
	deadline := time.sys_mono_now() + u64(ms) * u64(time.millisecond)
	for time.sys_mono_now() < deadline {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		if c.async_wants_write() {
			c.async_flush()!
		}
		C.pg_async_wait(c.fd, C.POLLIN, 10)
	}
	return error('no reply in ${ms} ms')
}

fn ct_sqlstate(err IError) string {
	if err is PgError {
		return err.sqlstate
	}
	return ''
}

fn ct_int(res Result) int {
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	return int(row.int4(0) or { panic(err) })
}

// ct_check_cancel is the issue's scenario on one connection: a 10 s sleep,
// cancelled after ~100 ms, fails with 57014 well before it would end, and the
// next query on the connection succeeds. An error says what did not hold
// (the callers assert, in the frame that owns their defers).
fn ct_check_cancel(mut c PgConn) ! {
	c.set_nonblocking()!
	ct_submit(mut c, 'select pg_sleep(10)')!
	time.sleep(100 * time.millisecond)
	sw := time.new_stopwatch()
	mut l := CtLoop{}
	mut el := ct_loop(&l)
	c.cancel(mut el)!
	if !l.run(3000) {
		return error('the CancelRequest did not complete')
	}
	if _ := ct_wait(mut c, 3000) {
		return error('the cancelled query succeeded')
	} else {
		if ct_sqlstate(err) != '57014' {
			return error('want 57014, got: ${err.msg()}')
		}
	}
	took := sw.elapsed().milliseconds()
	if took >= 1000 {
		return error('the cancel took ${took} ms to fail the query')
	}
	if c.is_broken() {
		return error('a cancelled query must leave the connection usable')
	}
	ct_submit(mut c, 'select 5')!
	if ct_int(ct_wait(mut c, 3000)!) != 5 {
		return error('the next query got a wrong result')
	}
}

fn test_fake_backend_key_data_is_kept() ! {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping fake-server cancel tests (no python3)')
		return
	}
	for key_len in [4, 32] {
		mut fake := testkit.start_fake_pg(['--key-len', key_len.str()])!
		mut c := PgConn.connect(ct_cfg(fake.port))!
		assert c.backend_pid() == 1000 // the fake's first session
		assert c.cancel_key.len == key_len // as bytes: protocol 3.2 allows up to 256
		c.close()
		fake.stop()
	}
}

fn test_fake_cancel_interrupts_the_running_query() ! {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(ct_cfg(fake.port))!
	defer {
		c.close()
	}
	ct_check_cancel(mut c)!
	assert fake.stat('cancel_requests') == 1
	assert fake.stat('cancels_honored') == 1
	assert fake.stat('cancelled') == 1
	assert c.cancel.phase == .idle && c.cancel.fd == -1
}

// A protocol 3.2 server's longer key goes out whole.
fn test_fake_cancel_with_a_long_key() ! {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--key-len', '32'])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(ct_cfg(fake.port))!
	defer {
		c.close()
	}
	ct_check_cancel(mut c)!
	assert fake.stat('cancels_honored') == 1
}

// The server checks the key: a wrong one cancels nothing (the query ends on
// its own), and the request still completes on the client side.
fn test_fake_cancel_with_a_wrong_key_is_ignored() ! {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut c := PgConn.connect(ct_cfg(fake.port))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	c.cancel_key[0] ^= 0xff
	ct_submit(mut c, 'select pg_sleep(0.5)')!
	time.sleep(50 * time.millisecond)
	mut l := CtLoop{}
	mut el := ct_loop(&l)
	c.cancel(mut el)!
	assert l.run(3000)
	ct_wait(mut c, 3000)! // the sleep's own result
	assert fake.stat('cancels_ignored') == 1
	assert fake.stat('cancelled') == 0
}

fn C.bind(fd int, addr voidptr, len u32) int
fn C.listen(fd int, backlog int) int
fn C.getsockname(fd int, addr voidptr, len &u32) int
fn C.accept(fd int, addr voidptr, len voidptr) int
fn C.read(fd int, buf voidptr, count usize) int

// CtListener is a loopback listener with an accept queue of one, plus a
// connection to it that stands in for a session with the server. While that
// connection sits unaccepted the queue is full: the kernel drops the SYN of
// any other connect, which stays in progress until the client retransmits it
// (~1 s), so a cancel() to this address has to wait for its connect.
struct CtListener {
	lfd     int
	session int
}

fn ct_listener() !CtListener {
	lfd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	local := transport.ip_addr('127.0.0.1', 0) or { return error('ip_addr') }
	if C.bind(lfd, voidptr(&local.data[0]), local.len) != 0 || C.listen(lfd, 0) != 0 {
		C.close(lfd)
		return error('listen failed (errno ${C.errno})')
	}
	mut sa := [128]u8{}
	mut sl := u32(128)
	C.getsockname(lfd, voidptr(&sa[0]), &sl)
	to := transport.ip_addr('127.0.0.1', (int(sa[2]) << 8) | int(sa[3])) or { return error('ip_addr') }
	session := transport.dial_addr(&to, transport.TcpOpts{})
	if session < 0 || C.pg_async_wait(session, C.POLLOUT, 2000) <= 0 {
		C.close(lfd)
		return error('connect failed')
	}
	return CtListener{
		lfd:     lfd
		session: session
	}
}

// A CancelRequest whose connect is still in progress waits for it on a
// background watch, then goes out as protocol 3.0 lays it out. Where no
// background watch can run (every worker but the epoll plain one) cancel()
// fails and leaves nothing behind; while one is in flight a second cancel()
// is a no-op; without BackendKeyData there is nothing to send.
fn test_cancel_waits_for_its_connect_on_a_background_watch() ! {
	ls := ct_listener()!
	defer {
		C.close(ls.session)
		C.close(ls.lfd)
	}
	mut c := PgConn{
		state: .ready
		fd:    ls.session
	}
	if _ := c.cancel(mut ct_loop(&CtLoop{})) {
		assert false, 'cancel without BackendKeyData must fail'
	}
	c.set_backend_key([u8(0), 0, 0, 42, 1, 2, 3, 4]) // pid 42, a 4-byte key
	assert c.backend_pid() == 42
	mut refusing := CtLoop{
		refuse: true
	}
	if _ := c.cancel(mut ct_loop(&refusing)) {
		assert false, 'cancel must fail where no background watch runs'
	} else {
		assert err.msg().contains('background watches'), err.msg()
	}
	assert c.cancel.phase == .idle && c.cancel.fd == -1
	mut l := CtLoop{}
	mut el := ct_loop(&l)
	c.cancel(mut el)!
	assert l.fd >= 0 && l.interest == .writable, 'the request did not wait for its connect'
	assert c.cancel.phase == .sending && c.cancel.off == 0
	in_flight := l.fd
	c.cancel(mut el)! // one is on its way: no second connection
	assert l.fd == in_flight
	// Accepting the session frees the queue: the retransmitted SYN gets in.
	server_side := C.accept(ls.lfd, unsafe { nil }, unsafe { nil })
	defer {
		C.close(server_side)
	}
	assert l.run(5000), 'the CancelRequest did not go out'
	assert c.cancel.phase == .idle && c.cancel.fd == -1
	cancel_side := C.accept(ls.lfd, unsafe { nil }, unsafe { nil })
	defer {
		C.close(cancel_side)
	}
	mut got := [16]u8{}
	assert C.pg_async_wait(cancel_side, C.POLLIN, 2000) > 0
	assert C.read(cancel_side, &got[0], 16) == 16
	// Int32(16) Int32(80877102) Int32(42) and the key.
	assert got == [u8(0), 0, 0, 16, 0x04, 0xd2, 0x16, 0x2e, 0, 0, 0, 42, 1, 2, 3, 4]!
}

fn test_tls_cancel_over_tls() ! {
	$if vanilla_tls ? {
		if !testkit.fake_pg_available() || !testkit.test_certs_available() {
			eprintln('pg_async: skipping the TLS cancel test (no python3 or openssl)')
			return
		}
		certs := testkit.test_certs() or { panic(err) }
		defer {
			os.rmdir_all(certs) or {}
		}
		mut fake := testkit.start_fake_pg(['--ssl', 'tls', '--require-ssl', '--cert',
			os.join_path(certs, 'server.crt'), '--key', os.join_path(certs, 'server.key')])!
		defer {
			fake.stop()
		}
		mut c := PgConn.connect(ConnConfig{
			...ct_cfg(fake.port)
			host:          'localhost'
			ssl_mode:      .verify_full
			ssl_root_cert: os.join_path(certs, 'ca.crt')
		})!
		defer {
			c.close()
		}
		ct_check_cancel(mut c)!
		// The session's handshake, then the cancel connection's.
		assert fake.stat('tls_handshakes') == 2
		assert fake.stat('cancels_honored') == 1
		// A second cancel re-arms the same TLS session.
		ct_check_cancel(mut c)!
		assert fake.stat('tls_handshakes') == 3
		assert fake.stat('cancels_honored') == 2
	}
}

// Live: `select pg_sleep(10)` cancelled after ~100 ms fails with 57014 within
// ~200 ms (well under 1 s here), and the next query on the connection
// succeeds. Skipped unless PGHOST is set.
fn test_live_cancel_interrupts_pg_sleep() ! {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping the live cancel test (no PGHOST)')
		return
	}
	port_env := os.getenv('PGPORT')
	mut c := PgConn.connect(ConnConfig{
		host:          host
		port:          if port_env != '' { port_env.int() } else { 5432 }
		user:          os.getenv('PGUSER')
		password:      os.getenv('PGPASSWORD')
		database:      os.getenv('PGDATABASE')
		ssl_mode:      SslMode.from_string(os.getenv('PGSSLMODE').replace('-', '_')) or {
			SslMode.disable
		}
		ssl_root_cert: os.getenv('PGSSLROOTCERT')
	})!
	defer {
		c.close()
	}
	assert c.backend_pid() > 0
	ct_check_cancel(mut c)!
}
