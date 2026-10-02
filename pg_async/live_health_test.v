// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import os
import time

// Connection health (#191) against a live PostgreSQL. Skipped unless PGHOST is
// set (pg_async.yml runs it against PostgreSQL 16 and 18):
//   - a pooled backend killed with pg_terminate_backend fails at most the one
//     query that meets it, with SQLSTATE 57P01; the pool keeps serving on its
//     other connection and maintain() re-dials the dead one;
//   - idle_session_timeout's FATAL is found by maintain()'s idle probe, before
//     any query meets it;
//   - SQLSTATE is machine-readable: 22012, and a real 40001 serialization
//     failure under SERIALIZABLE.

fn live_cfg() ?ConnConfig {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping live health test (no PGHOST)')
		return none
	}
	port_env := os.getenv('PGPORT')
	return ConnConfig{
		host:              host
		port:              if port_env != '' { port_env.int() } else { 5432 }
		user:              os.getenv('PGUSER')
		password:          os.getenv('PGPASSWORD')
		database:          os.getenv('PGDATABASE')
		redial_backoff_ms: 20
	}
}

// live_run runs one query on pooled connection idx through the async pump.
fn live_run(mut p PgPool, idx int, query string) !Result {
	mut c := p.conn(idx)
	if !c.submit(query, []?[]u8{})! {
		return error('shed')
	}
	c.async_flush() or {}
	for _ in 0 .. 20000 {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
		C.pg_async_wait(c.fd, C.POLLIN, 5)
	}
	return error('no outcome')
}

fn live_int(res Result) i64 {
	mut it := res.rows()
	row := it.next() or { return -1 }
	return row.int4(0) or { return row.int8(0) or { -2 } }
}

fn test_live_a_terminated_backend_costs_one_query_and_is_redialed() {
	cfg := live_cfg() or { return }
	mut p := PgPool.connect(cfg, 2)!
	defer {
		p.close()
	}
	pid := live_int(live_run(mut p, 0, 'select pg_backend_pid()')!)
	assert pid > 0
	mut admin := PgConn.connect(cfg)!
	defer {
		admin.close()
	}
	admin.query(r'select pg_terminate_backend($1::int4)', [?[]u8('${pid}'.bytes())])!
	time.sleep(100 * time.millisecond) // the FATAL and the close reach slot 0

	// The query that meets the dead backend: SQLSTATE 57P01, not a generic close.
	if _ := live_run(mut p, 0, 'select 1') {
		assert false, 'slot 0 was terminated'
	} else {
		assert err is PgError
		if err is PgError {
			assert err.kind == .unknown, err.msg()
			assert err.sqlstate == '57P01', err.msg()
		}
	}
	assert p.is_broken(0)
	// The other connection serves right away; acquire skips the dead one.
	assert live_int(live_run(mut p, 1, 'select 2')!) == 2
	for _ in 0 .. 4 {
		i := p.acquire() or { panic('slot 1 is free') }
		assert i == 1
		p.release(i)
	}
	// maintain() re-dials slot 0: a new backend.
	for _ in 0 .. 2000 {
		p.maintain()
		if !p.is_broken(0) {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	assert !p.is_broken(0), 'slot 0 was not re-dialed'
	new_pid := live_int(live_run(mut p, 0, 'select pg_backend_pid()')!)
	assert new_pid > 0 && new_pid != pid
}

fn test_live_an_idle_session_timeout_is_found_by_the_idle_probe() {
	cfg := live_cfg() or { return }
	mut p := PgPool.connect(cfg, 1)!
	defer {
		p.close()
	}
	pid := live_int(live_run(mut p, 0, 'select pg_backend_pid()')!)
	live_run(mut p, 0, "select set_config('idle_session_timeout', '100ms', false)")!
	time.sleep(400 * time.millisecond) // the server ends the idle session (FATAL 57P05)
	assert !p.is_broken(0), 'nothing has looked at the connection yet'
	p.next_probe = 0
	p.maintain() // the probe finds the FATAL and the close; the re-dial starts
	assert p.is_broken(0), 'the idle probe missed the closed session'
	for _ in 0 .. 2000 {
		p.maintain()
		if !p.is_broken(0) {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	assert !p.is_broken(0), 'not re-dialed'
	// A new session, with the default timeout again: it answers.
	new_pid := live_int(live_run(mut p, 0, 'select pg_backend_pid()')!)
	assert new_pid > 0 && new_pid != pid
}

fn test_live_sqlstate_is_machine_readable() {
	cfg := live_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	if _ := c.query('select 1/0', []?[]u8{}) {
		assert false
	} else {
		if err is PgError {
			assert err.kind == .server
			assert err.sqlstate == '22012'
			assert err.msg() == 'pg: query failed: division by zero (SQLSTATE 22012)'
		} else {
			assert false, 'not a PgError'
		}
	}

	// A serialization failure: two SERIALIZABLE transactions that each read
	// what the other writes (write skew). The second commit fails with 40001.
	c.query('drop table if exists pg_async_ssi', []?[]u8{})!
	c.query('create table pg_async_ssi (k int4, v int4)', []?[]u8{})!
	c.query('insert into pg_async_ssi values (1, 10), (2, 20)', []?[]u8{})!
	mut a := PgConn.connect(cfg)!
	defer {
		a.close()
	}
	mut b := PgConn.connect(cfg)!
	defer {
		b.close()
	}
	a.query('begin isolation level serializable', []?[]u8{})!
	b.query('begin isolation level serializable', []?[]u8{})!
	a.query('select sum(v) from pg_async_ssi where k = 2', []?[]u8{})!
	b.query('select sum(v) from pg_async_ssi where k = 1', []?[]u8{})!
	a.query('insert into pg_async_ssi values (1, 100)', []?[]u8{})!
	b.query('insert into pg_async_ssi values (2, 200)', []?[]u8{})!
	a.query('commit', []?[]u8{})!
	// The conflict surfaces at b's commit (or earlier, at its last write).
	mut saw := ''
	b.query('commit', []?[]u8{}) or {
		if err is PgError {
			saw = err.sqlstate.clone()
			assert err.kind == .server
		}
	}
	assert saw == '40001', 'expected a serialization failure, got "${saw}"'
	c.query('drop table if exists pg_async_ssi', []?[]u8{})!
}
