// vtest build: !windows
module pg_async

import os
import tls
import time
import testkit

// The TLS client (vanilla#196) against pg_async/testdata/fake_pg.py in its TLS
// modes, with a test CA generated at run time (gen_test_ca.sh). The TLS cases
// need the `-d vanilla_tls` build (Mbed TLS 4); without it, the one test that
// runs checks that asking for TLS fails loudly instead of falling back to
// plaintext. Skipped without python3/openssl unless VANILLA_REQUIRE_FAKE_PG is
// set (CI).

// TlsFixture is one fake server plus the certificates it was started with.
struct TlsFixture {
mut:
	fake  testkit.FakePg
	certs string
}

fn tls_fixture(certs string, args []string) !TlsFixture {
	return TlsFixture{
		fake:  testkit.start_fake_pg(args)!
		certs: certs
	}
}

fn (mut f TlsFixture) stop() {
	f.fake.stop()
}

fn (f &TlsFixture) cfg(mode SslMode, host string) ConnConfig {
	return ConnConfig{
		host:          host
		port:          f.fake.port
		user:          'vanilla'
		password:      'secret'
		database:      'vanilla'
		ssl_mode:      mode
		ssl_root_cert: os.join_path(f.certs, 'ca.crt')
	}
}

// tls_ready reports whether the TLS fake-server tests can run, and makes the
// test CA when they can.
fn tls_ready() ?string {
	$if vanilla_tls ? {
		if !testkit.fake_pg_available() || !testkit.test_certs_available() {
			eprintln('pg_async: skipping TLS fake-server tests (no python3 or openssl)')
			return none
		}
		return testkit.test_certs() or { panic(err) }
	} $else {
		return none
	}
}

fn server_args(certs string, cert string, extra []string) []string {
	mut a := ['--ssl', 'tls', '--require-ssl', '--cert', os.join_path(certs, '${cert}.crt'), '--key',
		os.join_path(certs, '${cert}.key')]
	a << extra
	return a
}

// pump flushes what is pending, then pumps readable until the front query
// completes or fails, giving up after `ms` milliseconds.
fn pump(mut c PgConn, ms int) !Result {
	deadline := time.sys_mono_now() + u64(ms) * u64(time.millisecond)
	for c.async_wants_write() {
		c.async_flush()!
		if time.sys_mono_now() > deadline {
			return error('flush did not complete')
		}
	}
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
	return error('query did not complete in ${ms} ms')
}

fn int_of(res Result) int {
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	return int(row.int4(0) or { panic(err) })
}

fn expect_connect_error(cfg ConnConfig, want string) {
	if _ := PgConn.connect(cfg) {
		assert false, 'connect succeeded; want an error containing "${want}"'
	} else {
		assert err.msg().contains(want), err.msg()
	}
}

// Without -d vanilla_tls there is no TLS: asking for it is an error before
// anything is dialed, never a silent plaintext connection.
fn test_tls_without_the_build_flag_fails_loudly() {
	$if !vanilla_tls ? {
		for mode in [SslMode.require, .verify_ca, .verify_full] {
			// Port 1: nothing listens there, and nothing must be dialed.
			cfg := ConnConfig{
				host:     '127.0.0.1'
				port:     1
				ssl_mode: mode
			}
			expect_connect_error(cfg, '-d vanilla_tls')
			if _ := PgPool.connect(cfg, 1) {
				assert false, 'pool connect succeeded without TLS support'
			} else {
				assert err.msg().contains('-d vanilla_tls'), err.msg()
			}
		}
	}
}

// What main did against a hostssl-only server: plaintext only, refused.
fn test_tls_only_server_refuses_plaintext() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', []))!
	defer {
		f.stop()
	}
	expect_connect_error(f.cfg(.disable, '127.0.0.1'), 'no encryption')
	assert f.fake.stat('ssl_requests') == 0
}

// verify_full against the test CA, by host name and by IP SAN: SSLRequest,
// the TLS 1.3 handshake, SCRAM over it, then blocking and pipelined queries.
fn test_tls_verify_full_blocking_and_pipelined_queries() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', []))!
	defer {
		f.stop()
	}
	for host in ['localhost', '127.0.0.1'] {
		mut c := PgConn.connect(f.cfg(.verify_full, host))!
		assert c.tls.active()
		res := c.query(r'select $1::int4, $2::text', [?[]u8('42'.bytes()), ?[]u8('hi'.bytes())])!
		mut it := res.rows()
		row := it.next() or { panic('expected a row') }
		assert row.int4(0)! == 42
		assert row.text(1)!.bytestr() == 'hi'
		c.set_nonblocking()!
		for v in [10, 20, 30] {
			assert c.async_submit(r'select $1::int4', [?[]u8(v.str().bytes())])
		}
		for v in [10, 20, 30] {
			assert int_of(pump(mut c, 5000)!) == v
		}
		assert !c.is_busy()
		c.close()
	}
	assert f.fake.stat('tls_handshakes') == 2
	assert f.fake.stat('authenticated') == 2
	// SNI went out for localhost only: an IP literal is never a server_name
	// (RFC 6066 §3), and is checked against the iPAddress SANs instead (#233).
	assert f.fake.stat('sni') == 1
}

// A certificate for another name: verify_full refuses it; verify_ca (chain
// only) and require (no verification) accept it.
fn test_tls_hostname_mismatch_fails_verify_full_only() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'wronghost', []))!
	defer {
		f.stop()
	}
	expect_connect_error(f.cfg(.verify_full, 'localhost'), 'does not match')
	expect_connect_error(f.cfg(.verify_full, '127.0.0.1'), 'does not match')
	assert f.fake.stat('authenticated') == 0
	for mode in [SslMode.verify_ca, .require] {
		mut c := PgConn.connect(f.cfg(mode, 'localhost'))!
		assert int_of(c.query('select 5', []?[]u8{})!) == 5
		c.close()
	}
}

// A CA that did not sign the server's certificate: verify_ca and verify_full
// refuse it, and so does require once a root certificate is given (libpq's
// rule); require without one does not verify at all.
fn test_tls_wrong_ca_is_refused() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', []))!
	defer {
		f.stop()
	}
	for mode in [SslMode.verify_ca, .verify_full, .require] {
		cfg := ConnConfig{
			...f.cfg(mode, 'localhost')
			ssl_root_cert: os.join_path(certs, 'other_ca.crt')
		}
		expect_connect_error(cfg, 'not trusted')
	}
	assert f.fake.stat('authenticated') == 0
	mut c := PgConn.connect(ConnConfig{ ...f.cfg(.require, 'localhost'), ssl_root_cert: '' })!
	assert int_of(c.query('select 6', []?[]u8{})!) == 6
	c.close()
	// A root certificate file that does not exist is an error, not "no CA".
	expect_connect_error(ConnConfig{
		...f.cfg(.verify_full, 'localhost')
		ssl_root_cert: os.join_path(certs, 'missing.crt')
	}, 'missing.crt')
}

// A server without TLS answers SSLRequest with 'N': every ssl_mode but
// disable fails, before any credential is sent.
fn test_tls_n_answer_fails_require() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, [])!
	defer {
		f.stop()
	}
	for mode in [SslMode.require, .verify_ca, .verify_full] {
		expect_connect_error(f.cfg(mode, 'localhost'), "answered 'N'")
	}
	assert f.fake.stat('ssl_requests') == 3
	assert f.fake.stat('authenticated') == 0
	if _ := PgPool.connect(f.cfg(.require, 'localhost'), 2) {
		assert false, 'a pool came up without TLS'
	}
}

// Bytes behind the 'S' arrived before any TLS session existed: nothing
// authenticates them, so they are refused before the handshake
// (CVE-2021-23222), never read as the server's first replies.
fn test_tls_plaintext_after_s_is_refused() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, ['--ssl', 'garbage'])!
	defer {
		f.stop()
	}
	expect_connect_error(f.cfg(.require, 'localhost'), 'unencrypted data after')
	assert f.fake.stat('authenticated') == 0
}

// A server that accepts the TCP connection but never answers SSLRequest:
// connect_timeout_ms bounds the TLS bring-up.
fn test_tls_bring_up_is_bounded_by_connect_timeout() {
	$if vanilla_tls ? {
		addrs := resolve('127.0.0.1', 0)!
		lfd := C.socket(addrs[0].family, C.SOCK_STREAM, 0)
		assert C.bind(lfd, voidptr(&addrs[0].data[0]), addrs[0].len) == 0
		assert C.listen(lfd, 4) == 0
		defer {
			C.close(lfd)
		}
		mut sa := [128]u8{}
		mut sl := u32(128)
		assert C.getsockname(lfd, voidptr(&sa[0]), &sl) == 0
		cfg := ConnConfig{
			host:               '127.0.0.1'
			port:               (int(sa[2]) << 8) | int(sa[3])
			ssl_mode:           .require
			connect_timeout_ms: 300
		}
		sw := time.new_stopwatch()
		expect_connect_error(cfg, 'timed out')
		assert sw.elapsed().milliseconds() < 3000
	}
}

fn C.bind(fd int, addr voidptr, len u32) int
fn C.listen(fd int, backlog int) int
fn C.getsockname(fd int, addr voidptr, len &u32) int

// TLS 1.3 NewSessionTicket messages may come at any time after the handshake;
// here two arrive right before every reply, in the same burst. Mbed TLS
// reports each one (and the record before it as a "want read") — the client
// must read on, not fail the connection or stop short of the reply.
fn test_tls_session_tickets_mid_query() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', ['--tickets-per-query', '2']))!
	defer {
		f.stop()
	}
	mut c := PgConn.connect(f.cfg(.verify_full, 'localhost'))!
	defer {
		c.close()
	}
	assert int_of(c.query('select 1', []?[]u8{})!) == 1
	c.set_nonblocking()!
	for round in 0 .. 3 {
		for k in 0 .. 4 {
			assert c.async_submit(r'select $1::int4', [?[]u8((round * 10 + k).str().bytes())])
		}
		for k in 0 .. 4 {
			assert int_of(pump(mut c, 5000)!) == round * 10 + k
		}
	}
	assert !c.is_broken()
	assert f.fake.stat('tickets') == 2 * 13
}

// 20000 rows (~300 KB) arrive as many TLS records: async_on_readable must
// drain the TLS layer, not stop at the first record.
fn test_tls_large_result_spans_many_records() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', []))!
	defer {
		f.stop()
	}
	mut c := PgConn.connect(f.cfg(.verify_full, 'localhost'))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	for _ in 0 .. 2 {
		assert c.async_submit('select g from generate_series(1, 20000) g', []?[]u8{})
		res := pump(mut c, 10000)!
		mut it := res.rows()
		mut n := 0
		for {
			row := it.next() or { break }
			n++
			assert row.int4(0)! == n
		}
		assert n == 20000
	}
	big := c.query('select g from generate_series(1, 20000) g', []?[]u8{}) or { panic(err) }
	assert big.rows_affected == 20000
}

// The server ends the session (FATAL 57P01, then close) after one query: the
// pooled TLS connection breaks like a plaintext one, its next query fails with
// the FATAL, and the pool re-dials it over TLS without blocking: SSLRequest,
// the handshake and SCRAM, one non-blocking step per acquire().
fn test_tls_pool_redials_a_lost_connection() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', ['--close', 'fatal']))!
	defer {
		f.stop()
	}
	mut pool := PgPool.connect(f.cfg(.verify_full, 'localhost'), 1)!
	defer {
		pool.close()
	}
	i := pool.acquire() or { panic('acquire') }
	mut c := pool.conn(i)
	assert c.async_submit('select 1', []?[]u8{})
	assert int_of(pump(mut c, 5000)!) == 1
	pool.release(i)
	time.sleep(200 * time.millisecond) // the FATAL comes 50 ms after the reply
	j := pool.acquire() or { panic('acquire') }
	assert j == i
	assert c.async_submit('select 2', []?[]u8{})
	if _ := pump(mut c, 5000) {
		assert false, 'the server ended the session; the query must fail'
	} else {
		assert err is PgError, err.msg()
		if err is PgError {
			assert err.sqlstate == '57P01'
		}
	}
	assert c.is_broken()
	pool.release(j)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 {
		k := pool.acquire() or {
			time.sleep(2 * time.millisecond)
			continue
		}
		mut ck := pool.conn(k)
		assert ck.tls.active()
		assert ck.async_submit('select 3', []?[]u8{})
		assert int_of(pump(mut ck, 5000)!) == 3
		pool.release(k)
		assert f.fake.stat('tls_handshakes') == 2
		assert f.fake.stat('authenticated') == 2
		assert pool.scram.derived == 1, "the TLS re-dial must reuse the pool's SCRAM key (ScramCache)"
		return
	}
	assert false, 'the lost TLS connection was not re-dialed'
}

// Pool maintenance over TLS: a FATAL the server sends while the connection
// sits idle is an encrypted record, so probe_idle must read it through the
// session (never raw into recv_buf) to find it, and maintain() then re-dials
// over TLS with no query and no acquire().
fn test_tls_maintain_finds_a_fatal_sent_while_idle() {
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', ['--close', 'fatal']))!
	defer {
		f.stop()
	}
	mut pool := PgPool.connect(f.cfg(.verify_full, 'localhost'), 1)!
	defer {
		pool.close()
	}
	mut c := pool.conn(0)
	assert c.async_submit('select 1', []?[]u8{})
	assert int_of(pump(mut c, 5000)!) == 1
	time.sleep(200 * time.millisecond) // the FATAL comes 50 ms after the reply
	pool.conns[0].probe_idle()
	assert pool.conns[0].state == .broken
	assert pool.conns[0].fatal.sqlstate == '57P01', 'the FATAL must be decrypted, not lost'
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 && pool.conns[0].state != .ready {
		time.sleep(i64(pool.maintain()) * time.millisecond)
	}
	assert pool.conns[0].state == .ready, 'maintain() did not re-dial over TLS'
	assert pool.conns[0].tls.active()
	assert f.fake.stat('tls_handshakes') == 2
	mut c2 := pool.conn(0)
	assert c2.async_submit('select 2', []?[]u8{})
	assert int_of(pump(mut c2, 5000)!) == 2
}

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// A query record the socket cannot take whole stays encrypted inside Mbed
// TLS, which must be called again with the same length. Queries submitted
// meanwhile lengthen the unsent tail (and append_send compacts it): retrying
// with that longer length would count bytes as sent that were never
// encrypted. In process, against tls/'s server side over a socketpair whose
// send buffer is too small for one record; the server checks every byte.
fn test_tls_partial_record_writes_resume_with_the_same_length() {
	$if vanilla_tls ? {
		srv_cfg := tls.new_self_signed()!
		defer {
			srv_cfg.free()
		}
		ca := os.join_path(os.temp_dir(), 'pg_async_tls_ca_${os.getpid()}.pem')
		os.write_file(ca, srv_cfg.cert_pem())!
		defer {
			os.rm(ca) or {}
		}
		mut sv := [2]i32{}
		assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
		srv_fd, cli_fd := int(sv[0]), int(sv[1])
		small := i32(4096)
		C.setsockopt(i32(cli_fd), C.SOL_SOCKET, C.SO_SNDBUF, &small, sizeof(small))
		C.setsockopt(i32(srv_fd), C.SOL_SOCKET, C.SO_RCVBUF, &small, sizeof(small))
		srv := srv_cfg.new_session(srv_fd) or { panic('server session') }
		cfg := ConnConfig{
			host:          'localhost'
			ssl_mode:      .verify_full
			ssl_root_cert: ca
		}
		mut c := PgConn{
			fd:       cli_fd
			recv_buf: []u8{cap: 16 * 1024}
			tls_cfg:  new_tls_config(&cfg)!
			owns_tls: true
		}
		defer {
			c.teardown()
			srv.free()
			C.close(srv_fd)
		}
		c.set_nonblocking()!
		C.fcntl(srv_fd, C.F_SETFL, C.fcntl(srv_fd, C.F_GETFL, 0) | C.O_NONBLOCK)
		c.tls_attach(&cfg)!
		mut done := false
		for _ in 0 .. 1000 {
			done = c.tls_step(&cfg)!
			srv.mark_readable()
			srv.handshake()
			if done {
				break
			}
		}
		assert done
		// A 10 KB query: one record, more than the socket takes while the
		// server reads nothing.
		pad := 'x'.repeat(10_000)
		mut expected := []u8{}
		assert c.async_submit(r'select $1::text', [?[]u8(pad.bytes())])
		expected << c.submit_scratch
		assert !c.async_flush()!, 'the record should not fit the socket'
		pending := c.tls_wlen
		assert pending > 0 && pending == c.send_len - c.send_off
		// More queries behind it: the unsent tail grows past the record.
		for _ in 0 .. 2 {
			assert c.async_submit(r'select $1::text', [?[]u8(pad.bytes())])
			expected << c.submit_scratch
		}
		assert c.send_len - c.send_off > pending
		mut got := []u8{}
		mut buf := []u8{len: 64 * 1024}
		for _ in 0 .. 100_000 {
			flushed := c.async_flush()!
			srv.mark_readable()
			for {
				n := srv.read_into(buf.data, buf.len)
				if n <= 0 {
					break
				}
				got << buf[..n]
			}
			if flushed && got.len >= expected.len {
				break
			}
		}
		assert got.len == expected.len
		assert got == expected
	}
}

#include <malloc.h>

// glibc's malloc statistics: only the fields heap_bytes reads.
struct C.mallinfo2 {
	uordblks usize // bytes in chunks in use, over every arena
	hblkhd   usize // bytes in chunks mmapped on their own
}

fn C.mallinfo2() C.mallinfo2

// heap_bytes is how many bytes malloc has handed out and not had back. Under
// -gc none every V allocation is a malloc that is never freed; Mbed TLS's
// own (its PSA core copies buffers and sets up a cipher context per record)
// are freed before each call returns.
fn heap_bytes() i64 {
	mi := C.mallinfo2()
	return i64(mi.uordblks) + i64(mi.hblkhd)
}

// No allocation per query over TLS: under -gc none (nothing is ever freed)
// 4000 pipelined queries, every reply a TLS record behind another, leave the
// heap where 200 warm-up queries left it. Run with -gc none (pg_async.yml);
// the default GC frees, ThreadSanitizer and AddressSanitizer replace malloc.
fn test_tls_queries_do_not_grow_the_heap() {
	$if gcboehm ? {
		return
	}
	$if race ? {
		return
	}
	certs := tls_ready() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut f := tls_fixture(certs, server_args(certs, 'server', []))!
	defer {
		f.stop()
	}
	mut c := PgConn.connect(f.cfg(.verify_full, 'localhost'))!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	no_params := []?[]u8{}
	run := fn [no_params] (mut c PgConn, n int) {
		for _ in 0 .. n / 8 {
			for _ in 0 .. 8 {
				assert c.async_submit('select 7', no_params)
			}
			for _ in 0 .. 8 {
				res := pump(mut c, 5000) or { panic(err) }
				assert int_of(res) == 7
			}
		}
	}
	run(mut c, 200)
	heap0 := heap_bytes()
	if heap0 == 0 {
		return // a sanitizer's allocator: glibc's statistics see none of it
	}
	run(mut c, 4000)
	growth := heap_bytes() - heap0
	assert growth < 4096, 'the heap grew ${growth} bytes over 4000 queries over TLS'
}
