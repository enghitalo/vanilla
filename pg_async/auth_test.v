// vtest build: !windows
module pg_async

import os
import time
import testkit

// Authentication beyond the static SCRAM password (vanilla#197), against
// pg_async/testdata/fake_pg.py: AuthenticationCleartextPassword, answered
// only when allowed_auth lists it and only over TLS; a credential provider
// asked once per connection attempt (password_fn); the StartupMessage's
// run-time parameters. The cleartext logins need the `-d vanilla_tls` build;
// the refusals run in every build. Skipped without python3 (and openssl, for
// TLS) unless VANILLA_REQUIRE_FAKE_PG is set (CI).

// Calls counts password_fn calls; on the heap, so a closure can hold it.
@[heap]
struct Calls {
mut:
	n int
}

// counting_password is a password_fn answering `password`, counted in calls.
fn counting_password(mut calls Calls, password string) PasswordFn {
	return fn [mut calls, password] () !string {
		calls.n++
		return password
	}
}

fn auth_cfg(port int) ConnConfig {
	return ConnConfig{
		host:     '127.0.0.1'
		port:     port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
}

// auth_pump flushes, then pumps readable until the front query completes.
fn auth_pump(mut c PgConn) !Result {
	deadline := time.sys_mono_now() + 5 * u64(time.second)
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
	return error('query did not complete')
}

// show asks the server for a setting, on a pooled (non-blocking) connection.
fn show(mut c PgConn, name string) !string {
	if !c.async_submit('show ${name}', []?[]u8{}) {
		return error('submit refused')
	}
	mut it := auth_pump(mut c)!.rows()
	row := it.next() or { return error('no row') }
	return row.text(0)!.bytestr()
}

// redial_by_maintenance runs maintain() as its timer would until connection
// `idx`, found closed, is ready again.
fn redial_by_maintenance(mut pool PgPool, idx int) {
	sw := time.new_stopwatch()
	pool.maintain()
	for sw.elapsed().milliseconds() < 5000 && pool.conns[idx].state != .ready {
		time.sleep(i64(pool.maintain()) * time.millisecond)
	}
	assert pool.conns[idx].state == .ready, 'the closed connection was not re-dialed'
}

fn connect_error(cfg ConnConfig) string {
	mut c := PgConn.connect(cfg) or { return err.msg() }
	c.close()
	return ''
}

// auth_tls_certs makes the test CA when the TLS cases can run here.
fn auth_tls_certs() ?string {
	$if vanilla_tls ? {
		if !testkit.fake_pg_available() || !testkit.test_certs_available() {
			eprintln('pg_async: skipping TLS auth tests (no python3 or openssl)')
			return none
		}
		return testkit.test_certs() or { panic(err) }
	} $else {
		return none
	}
}

// cleartext_tls_server is fake_pg asking for a cleartext password, TLS only.
fn cleartext_tls_server(certs string, extra []string) !testkit.FakePg {
	mut args := ['--auth', 'cleartext', '--ssl', 'tls', '--require-ssl', '--cert',
		os.join_path(certs, 'server.crt'), '--key', os.join_path(certs, 'server.key')]
	args << extra
	return testkit.start_fake_pg(args)
}

// cleartext_tls_cfg is token authentication's config: verify_full (by IP SAN:
// a re-dial to `localhost` would try ::1 first, where nothing listens, and
// spend one password_fn call on that attempt), cleartext only, password_fn.
fn cleartext_tls_cfg(port int, certs string, mut calls Calls, password string) ConnConfig {
	return ConnConfig{
		...auth_cfg(port)
		password:      ''
		password_fn:   counting_password(mut calls, password)
		allowed_auth:  [.cleartext_password]
		ssl_mode:      .verify_full
		ssl_root_cert: os.join_path(certs, 'ca.crt')
	}
}

// Token authentication's shape: the server asks for a cleartext password over
// TLS, password_fn answers it once per connection — for a standalone
// connection, for each connection a pool brings up — and a wrong one is the
// server's 28P01.
fn test_cleartext_password_over_tls_from_password_fn() {
	certs := auth_tls_certs() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut fake := cleartext_tls_server(certs, [])!
	defer {
		fake.stop()
	}
	mut calls := &Calls{}
	cfg := cleartext_tls_cfg(fake.port, certs, mut calls, 'secret')
	mut c := PgConn.connect(cfg)!
	assert c.tls.active()
	res := c.query('select 7', []?[]u8{})!
	mut it := res.rows()
	assert (it.next() or { panic('row') }).int4(0)! == 7
	c.close()
	assert calls.n == 1
	assert fake.stat('password_messages') == 1
	mut pool := PgPool.connect(cfg, 3)!
	assert calls.n == 4, 'one password_fn call per pooled connection'
	assert fake.stat('authenticated') == 4
	i := pool.acquire() or { panic('acquire') }
	mut pc := pool.conn(i)
	assert pc.async_submit('select 8', []?[]u8{})
	mut pit := auth_pump(mut pc)!.rows()
	assert (pit.next() or { panic('row') }).int4(0)! == 8
	pool.release(i)
	pool.close()
	mut wrong := &Calls{}
	msg := connect_error(cleartext_tls_cfg(fake.port, certs, mut wrong, 'expired-token'))
	assert msg.contains('28P01'), msg
	assert wrong.n == 1
	assert fake.stat('authenticated') == 4
	// A NUL would cut the password short: refused, not sent.
	nul := connect_error(cleartext_tls_cfg(fake.port, certs, mut wrong, 'tok\0en'))
	assert nul.contains('NUL'), nul
	assert fake.stat('password_messages') == 5
}

// A re-dial over TLS answers the cleartext request with a fresh password_fn
// credential, from the non-blocking path (maintain(): no request, no wait).
fn test_cleartext_redial_asks_password_fn_again() {
	certs := auth_tls_certs() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut fake := cleartext_tls_server(certs, ['--close', 'delayed'])!
	defer {
		fake.stop()
	}
	mut calls := &Calls{}
	mut pool := PgPool.connect(cleartext_tls_cfg(fake.port, certs, mut calls, 'secret'),
		1)!
	defer {
		pool.close()
	}
	mut c := pool.conn(0)
	assert c.async_submit('select 1', []?[]u8{})
	auth_pump(mut c)!
	time.sleep(150 * time.millisecond) // closed 50 ms after the reply
	redial_by_maintenance(mut pool, 0)
	assert fake.stat('authenticated') == 2
	assert pool.conns[0].tls.active()
	assert calls.n == 2, 'the re-dial asks password_fn again'
	assert fake.stat('password_messages') == 2
}

// Over plaintext the password is never sent, even with .cleartext_password
// allowed: a server (or a man in the middle) asking for it gets a refusal.
fn test_cleartext_refused_over_plaintext() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping auth fake-server tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg(['--auth', 'cleartext'])!
	defer {
		fake.stop()
	}
	mut calls := &Calls{}
	cfg := ConnConfig{
		...auth_cfg(fake.port)
		password_fn:  counting_password(mut calls, 'secret')
		allowed_auth: [.cleartext_password]
	}
	msg := connect_error(cfg)
	assert msg.contains('unencrypted connection'), msg
	if _ := PgPool.connect(cfg, 2) {
		assert false, 'a pool sent a cleartext password over plaintext'
	} else {
		assert err.msg().contains('unencrypted connection'), err.msg()
	}
	assert fake.stat('password_messages') == 0
	assert fake.stat('authenticated') == 0
}

// Without .cleartext_password in allowed_auth (the default is [.sasl]) a
// cleartext request is refused, over plaintext and over TLS alike.
fn test_cleartext_refused_unless_allowed() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--auth', 'cleartext'])!
	defer {
		fake.stop()
	}
	msg := connect_error(auth_cfg(fake.port))
	assert msg.contains('allowed_auth does not allow'), msg
	assert fake.stat('password_messages') == 0
	certs := auth_tls_certs() or { return }
	defer {
		os.rmdir_all(certs) or {}
	}
	mut tls_fake := cleartext_tls_server(certs, [])!
	defer {
		tls_fake.stop()
	}
	tls_msg := connect_error(ConnConfig{
		...auth_cfg(tls_fake.port)
		host:          'localhost'
		ssl_mode:      .verify_full
		ssl_root_cert: os.join_path(certs, 'ca.crt')
	})
	assert tls_msg.contains('allowed_auth does not allow'), tls_msg
	assert tls_fake.stat('tls_handshakes') == 1
	assert tls_fake.stat('password_messages') == 0
}

// An explicit allowed_auth is exact: a cleartext-only config refuses SCRAM.
// What connects today still connects with the default: SCRAM, and a server
// that asks for nothing (trust), which any list accepts.
fn test_allowed_auth_default_and_explicit() {
	if !testkit.fake_pg_available() {
		return
	}
	mut scram := testkit.start_fake_pg([])!
	defer {
		scram.stop()
	}
	msg := connect_error(ConnConfig{
		...auth_cfg(scram.port)
		allowed_auth: [.cleartext_password]
	})
	assert msg.contains('SASL'), msg
	assert scram.stat('authenticated') == 0
	assert connect_error(auth_cfg(scram.port)) == ''
	assert scram.stat('authenticated') == 1
	mut trust := testkit.start_fake_pg(['--auth', 'trust'])!
	defer {
		trust.stop()
	}
	assert connect_error(auth_cfg(trust.port)) == ''
	assert connect_error(ConnConfig{ ...auth_cfg(trust.port), allowed_auth: [.cleartext_password] }) == ''
	assert trust.stat('authenticated') == 2
}

// password_fn replaces the static password for SCRAM too, once per attempt;
// its error fails the attempt before anything is dialed.
fn test_password_fn_with_scram_and_its_errors() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut calls := &Calls{}
	mut pool := PgPool.connect(ConnConfig{
		...auth_cfg(fake.port)
		password:    'stale'
		password_fn: counting_password(mut calls, 'secret')
	}, 2)!
	pool.close()
	assert calls.n == 2
	assert fake.stat('authenticated') == 2
	failing := fn () !string {
		return error('token service unreachable')
	}
	msg := connect_error(ConnConfig{ ...auth_cfg(fake.port), password_fn: failing })
	assert msg.contains('password_fn failed: token service unreachable'), msg
	assert fake.stat('accepted') == 2, 'a failing password_fn must not dial'
}

// The run-time parameters reach the server in the StartupMessage, on the
// blocking bring-up and on a re-dial; one it cannot carry fails before dialing.
fn test_startup_params_reach_the_server() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'delayed', '--close-after', '2'])!
	defer {
		fake.stop()
	}
	cfg := ConnConfig{
		...auth_cfg(fake.port)
		params: {
			'application_name': 'pg_async_test'
			'search_path':      'app'
		}
	}
	mut pool := PgPool.connect(cfg, 1)!
	defer {
		pool.close()
	}
	mut c := pool.conn(0)
	assert show(mut c, 'application_name')! == 'pg_async_test'
	assert show(mut c, 'search_path')! == 'app' // the fake closes the connection 50 ms after this one
	time.sleep(150 * time.millisecond)
	redial_by_maintenance(mut pool, 0)
	assert fake.stat('authenticated') == 2
	assert show(mut c, 'application_name')! == 'pg_async_test', 're-dialed without the params'
	for bad in [{
		'application_name': 'a\0b'
	}, {
		'user': 'admin'
	}] {
		bad_cfg := ConnConfig{
			...auth_cfg(fake.port)
			params: bad
		}
		assert connect_error(bad_cfg) != ''
		if _ := PgPool.connect(bad_cfg, 1) {
			assert false, 'a pool came up with startup params ${bad}'
		}
	}
	assert fake.stat('accepted') == 2, 'a bad startup parameter must not dial'
}
