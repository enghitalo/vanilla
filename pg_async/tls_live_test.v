// vtest build: !windows
module pg_async

import os
import time

// The TLS client against a live, TLS-only PostgreSQL. Runs when PGHOST is set
// and PGSSLMODE asks for TLS (the tls lane of pg_async.yml: verify-full with
// the test CA in PGSSLROOTCERT; locally `PG_TLS=1 throwaway_pg.sh start`),
// built with -d vanilla_tls. The other live suites run over TLS in that lane
// too: they read the same PGSSLMODE / PGSSLROOTCERT.

fn tls_live_cfg() ?ConnConfig {
	$if !vanilla_tls ? {
		return none
	}
	host := os.getenv('PGHOST')
	mode := SslMode.from_string(os.getenv('PGSSLMODE').replace('-', '_')) or { SslMode.disable }
	if host == '' || mode == .disable {
		eprintln('pg_async: skipping live TLS tests (set PGHOST and PGSSLMODE, build with -d vanilla_tls)')
		return none
	}
	port_env := os.getenv('PGPORT')
	return ConnConfig{
		host:          host
		port:          if port_env != '' { port_env.int() } else { 5432 }
		user:          os.getenv('PGUSER')
		password:      os.getenv('PGPASSWORD')
		database:      os.getenv('PGDATABASE')
		ssl_mode:      mode
		ssl_root_cert: os.getenv('PGSSLROOTCERT')
	}
}

fn live_pump(mut c PgConn, query string) !Result {
	assert c.async_submit(query, []?[]u8{})
	deadline := time.sys_mono_now() + 30 * u64(time.second)
	for c.async_wants_write() {
		c.async_flush()!
	}
	for time.sys_mono_now() < deadline {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		C.pg_async_wait(c.fd, C.POLLIN, 100)
	}
	return error('query did not complete')
}

// The server's view of the session: TLS 1.3, over the connection we hold.
fn test_live_tls_session_is_tls13() {
	cfg := tls_live_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	assert c.tls.active()
	res := c.query('select ssl, version from pg_stat_ssl where pid = pg_backend_pid()', []?[]u8{})!
	mut it := res.rows()
	row := it.next() or { panic('no pg_stat_ssl row') }
	assert row.boolean(0)!
	assert row.text(1)!.bytestr() == 'TLSv1.3'
}

// A host name the certificate does not carry, on the same server: 127.0.0.2
// reaches the loopback listener, the certificate names localhost, 127.0.0.1
// and ::1 (gen_test_ca.sh). Only meaningful against a local server.
fn test_live_tls_hostname_mismatch() {
	cfg := tls_live_cfg() or { return }
	if cfg.ssl_mode != .verify_full || cfg.host !in ['127.0.0.1', 'localhost'] {
		return
	}
	other := ConnConfig{
		...cfg
		host: '127.0.0.2'
	}
	if _ := PgConn.connect(other) {
		assert false, 'verify_full accepted a host outside the certificate'
	} else {
		assert err.msg().contains('does not match the host name'), err.msg()
	}
}

// A CA that did not sign the server's certificate (PG_TEST_CERTS: the
// directory gen_test_ca.sh wrote) fails verification.
fn test_live_tls_wrong_ca() {
	cfg := tls_live_cfg() or { return }
	certs := os.getenv('PG_TEST_CERTS')
	if certs == '' {
		return
	}
	for mode in [SslMode.verify_ca, .verify_full] {
		wrong := ConnConfig{
			...cfg
			ssl_mode:      mode
			ssl_root_cert: os.join_path(certs, 'other_ca.crt')
		}
		if _ := PgConn.connect(wrong) {
			assert false, '${mode} accepted a certificate from another CA'
		} else {
			assert err.msg().contains('not trusted'), err.msg()
		}
	}
}

// A ~2.4 MB result arrives as many TLS records; the async pump must drain
// the TLS layer on every call, and the connection stays usable after it.
fn test_live_tls_large_async_result() {
	cfg := tls_live_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	c.set_nonblocking()!
	res := live_pump(mut c, "select g, repeat('x', 100) from generate_series(1, 20000) g")!
	mut it := res.rows()
	mut n := 0
	for {
		row := it.next() or { break }
		n++
		assert row.int4(0)! == n
		assert row.text(1)!.len == 100
	}
	assert n == 20000
	one := live_pump(mut c, 'select 1::int4')!
	mut it1 := one.rows()
	assert (it1.next() or { panic('row') }).int4(0)! == 1
}

// pg_terminate_backend on a pooled TLS connection: its next query fails with
// 57P01, and the pool re-dials it over TLS without blocking (SSLRequest, TLS
// handshake, SCRAM: one step per acquire) — a new backend, on TLS again.
fn test_live_tls_redial_after_terminate_backend() {
	cfg := tls_live_cfg() or { return }
	mut pool := PgPool.connect(cfg, 2)!
	defer {
		pool.close()
	}
	mut admin := PgConn.connect(cfg)!
	defer {
		admin.close()
	}
	a := pool.acquire() or { panic('acquire') }
	mut ca := pool.conn(a)
	pid_res := live_pump(mut ca, 'select pg_backend_pid()')!
	mut pit := pid_res.rows()
	pid := (pit.next() or { panic('row') }).int4(0)!
	pool.release(a)
	admin.query(r'select pg_terminate_backend($1::int4)', [?[]u8(pid.str().bytes())])!
	time.sleep(200 * time.millisecond)
	lost := pool.acquire() or { panic('acquire') }
	assert lost == a
	mut cl := pool.conn(lost)
	if _ := live_pump(mut cl, 'select 1') {
		assert false, 'the terminated backend answered'
	} else {
		assert err is PgError, err.msg()
		if err is PgError {
			assert err.sqlstate == '57P01'
		}
	}
	assert cl.is_broken()
	pool.release(lost)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 10_000 {
		i := pool.acquire() or {
			time.sleep(2 * time.millisecond)
			continue
		}
		mut ci := pool.conn(i)
		res := live_pump(mut ci, 'select pg_backend_pid(), ssl from pg_stat_ssl where pid = pg_backend_pid()')!
		pool.release(i)
		if i != lost {
			time.sleep(2 * time.millisecond)
			continue
		}
		mut it := res.rows()
		row := it.next() or { panic('row') }
		assert row.int4(0)! != pid, 'the re-dialed slot must be a new backend'
		assert row.boolean(1)!, 'the re-dialed slot must be on TLS'
		assert ci.tls.active()
		return
	}
	assert false, 'the terminated TLS slot was not re-dialed'
}
