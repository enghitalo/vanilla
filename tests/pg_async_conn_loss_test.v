// vtest build: !windows
// pg_async when the server closes a connection (vanilla#191): a reply that
// arrives together with the FIN is still delivered, a FATAL ErrorResponse
// surfaces with its SQLSTATE, every server error is a typed pg_async.PgError,
// and a pool skips a lost connection and re-dials it without blocking — so a
// dead connection costs at most the query that was on it.
//
// The server side is tests/testdata/fake_pg.py (python3, stdlib only: real
// SCRAM-SHA-256, replies chosen by the SQL text — see its header), which makes
// every server-side close deterministic. Each test skips when python3 is
// absent. The same situations come from a real PostgreSQL via
// pg_terminate_backend(), idle_session_timeout, or a restart.
import os
import strconv
import time
import core
import server
import pg_async
import vtest

struct FakePg {
mut:
	proc &os.Process = unsafe { nil }
	port int
}

// start_fake_pg launches the fake server on an ephemeral port, or returns none
// (the test then skips) when python3 is not installed.
fn start_fake_pg() ?FakePg {
	python := os.find_abs_path_of_executable('python3') or {
		eprintln('pg_async conn-loss test: python3 not found, skipping')
		return none
	}
	script := os.join_path(os.dir(@FILE), 'testdata', 'fake_pg.py')
	port_file := os.join_path(os.vtmp_dir(), 'vanilla_fake_pg_${os.getpid()}_${time.sys_mono_now()}.port')
	mut p := os.new_process(python)
	p.set_args([script, port_file, '120'])
	p.run()
	for _ in 0 .. 1000 {
		if os.exists(port_file) {
			port := (os.read_file(port_file) or { '' }).trim_space().int()
			os.rm(port_file) or {}
			if port > 0 {
				return FakePg{
					proc: p
					port: port
				}
			}
		}
		if !p.is_alive() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	p.signal_kill()
	p.wait()
	panic('fake_pg.py did not start')
}

fn (mut f FakePg) stop() {
	f.proc.signal_kill()
	f.proc.wait()
	f.proc.close()
}

fn (f &FakePg) cfg() pg_async.ConnConfig {
	return pg_async.ConnConfig{
		host:     '127.0.0.1'
		port:     f.port
		user:     'u'
		password: 'secret'
		database: 'd'
	}
}

fn connect_nonblocking(f &FakePg) !pg_async.PgConn {
	mut c := pg_async.PgConn.connect(f.cfg())!
	c.set_nonblocking()!
	return c
}

// submit queues one query and sends it.
fn submit(mut c pg_async.PgConn, query string) ! {
	assert c.async_submit(query, []?[]u8{})
	assert c.async_flush()!
}

// value pumps the front query to completion — the readiness loop the HTTP
// worker drives with epoll, here a poll with a short sleep — and returns its
// single int4 column, or the query's error.
fn value(mut c pg_async.PgConn) !int {
	for _ in 0 .. 5000 {
		poll := c.async_on_readable()!
		if poll.ready {
			mut it := poll.result.rows()
			row := it.next() or { return error('no row') }
			return int(row.int4(0)!)
		}
		time.sleep(time.millisecond)
	}
	return error('query did not complete')
}

fn query_value(mut c pg_async.PgConn, query string) !int {
	submit(mut c, query)!
	return value(mut c)
}

// sqlstate is the SQLSTATE of a typed server error, '' for any other error.
fn sqlstate(err IError) string {
	if err is pg_async.PgError {
		return err.sqlstate
	}
	return ''
}

// A complete result that arrives together with the server's FIN is a success:
// the statement ran, so reporting it failed would make a retrying caller run it
// twice. The connection is known broken from that same read on.
fn test_result_arriving_with_fin_is_a_success() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	mut c := connect_nonblocking(fake)!
	defer {
		c.close()
	}
	submit(mut c, 'select 7 -- then-fin')!
	time.sleep(100 * time.millisecond) // the reply and the FIN both land before the first read
	assert value(mut c)! == 7
	assert c.is_broken()
	assert !c.can_submit()
	assert !c.async_submit('select 8', []?[]u8{}), 'a broken connection takes no new query'
	if _ := c.async_on_readable() {
		assert false, 'a broken connection must not report not-ready (a re-armed watch would spin)'
	} else {
		assert err.msg() == 'pg: connection closed by server'
	}
}

// Pipelined replies buffered before the EOF are delivered in order; only the
// query whose reply never came fails.
fn test_pipelined_replies_before_eof_are_delivered() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	mut c := connect_nonblocking(fake)!
	defer {
		c.close()
	}
	assert c.async_submit('select 1', []?[]u8{})
	assert c.async_submit('select 2 -- then-fin', []?[]u8{})
	assert c.async_submit('select 3', []?[]u8{})
	assert c.async_flush()!
	time.sleep(100 * time.millisecond)
	assert value(mut c)! == 1
	assert value(mut c)! == 2
	if _ := value(mut c) {
		assert false, 'the third query was never answered'
	} else {
		assert err.msg() == 'pg: connection closed by server'
		assert sqlstate(err) == ''
	}
	assert !c.is_busy()
}

// The FATAL a terminated backend sends (pg_terminate_backend: 57P01) is the
// error the caller gets, with its SQLSTATE — not a generic "closed".
fn test_fatal_error_response_surfaces_its_sqlstate() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	// Terminated while running the query.
	mut c := connect_nonblocking(fake)!
	defer {
		c.close()
	}
	if _ := query_value(mut c, 'select fatal') {
		assert false, 'expected the FATAL'
	} else {
		assert err is pg_async.PgError
		if err is pg_async.PgError {
			assert err.severity == 'FATAL'
			assert err.sqlstate == '57P01'
			assert err.message == 'terminating connection due to administrator command'
		}
		assert err.msg() == 'pg: query failed: terminating connection due to administrator command (SQLSTATE 57P01)'
	}
	assert c.is_broken()

	// Terminated while idle: FATAL + FIN reach a connection nobody reads, and
	// the next query on it reports that FATAL.
	mut idle := connect_nonblocking(fake)!
	defer {
		idle.close()
	}
	assert query_value(mut idle, 'select 1 -- then-fatal')! == 1
	time.sleep(300 * time.millisecond)
	if _ := query_value(mut idle, 'select 2') {
		assert false, 'expected the FATAL'
	} else {
		assert sqlstate(err) == '57P01', err.msg()
	}
	assert idle.is_broken()
}

// A statement error is a PgError with its SQLSTATE and the historical message,
// and leaves the connection healthy — on the async and the blocking path.
fn test_query_error_is_typed_and_keeps_the_connection() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	mut c := connect_nonblocking(fake)!
	defer {
		c.close()
	}
	if _ := query_value(mut c, 'select 1/0') {
		assert false, 'expected division by zero'
	} else {
		assert err is pg_async.PgError
		if err is pg_async.PgError {
			assert err.severity == 'ERROR'
			assert err.sqlstate == '22012'
			assert err.message == 'division by zero'
		}
		assert err.msg() == 'pg: query failed: division by zero (SQLSTATE 22012)'
	}
	assert !c.is_broken()
	assert query_value(mut c, 'select 5')! == 5

	mut blocking := pg_async.PgConn.connect(fake.cfg())!
	defer {
		blocking.close()
	}
	if _ := blocking.query('select 1/0', []?[]u8{}) {
		assert false, 'expected division by zero'
	} else {
		assert sqlstate(err) == '22012'
	}
	res := blocking.query('select 6', []?[]u8{})!
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	assert row.int4(0)! == 6
}

// pool_query runs one query on pooled connection idx (acquired by the caller).
fn pool_query(mut pool pg_async.PgPool, idx int, query string) !int {
	mut c := pool.conn(idx)
	return query_value(mut c, query)
}

// A connection the server closes while idle costs exactly one failed query.
// acquire() then skips it — the other slot serves — while re-dialing it a
// step per call, until it is back with a fresh backend.
fn test_pool_redials_a_connection_closed_by_the_server() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	mut pool := pg_async.PgPool.connect(fake.cfg(), 2)!
	defer {
		pool.close()
	}
	idx := pool.acquire() or { panic('acquire') }
	assert idx == 0
	assert pool_query(mut pool, idx, 'select backend -- then-close')! == 0
	pool.release(idx)
	time.sleep(300 * time.millisecond) // the server closes slot 0 50 ms after replying

	// The next query on slot 0 is the one that finds out.
	lost := pool.acquire() or { panic('acquire') }
	assert lost == 0
	if _ := pool_query(mut pool, lost, 'select backend') {
		assert false, 'slot 0 was closed by the server'
	}
	assert pool.conn(0).is_broken()
	pool.release(lost)

	// From here every query succeeds: slot 1 (backend 1) serves while slot 0
	// re-dials, and slot 0 comes back as the fake's third connection.
	mut backends := []int{}
	for _ in 0 .. 500 {
		i := pool.acquire() or { panic('pool exhausted: slot 1 is idle and healthy') }
		backends << pool_query(mut pool, i, 'select backend')!
		pool.release(i)
		if i == 0 {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	assert backends.last() == 2, 'slot 0 was not re-dialed: ${backends}'
	assert backends#[..-1].all(it == 1), '${backends}'
	assert !pool.conn(0).is_broken()
}

// An exclusive borrower that gives up on a query in flight (a failed or
// partial flush) and releases the connection retires it: the next borrower
// must never receive the abandoned query's reply.
fn test_release_with_a_query_in_flight_retires_the_connection() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	mut pool := pg_async.PgPool.connect(fake.cfg(), 1)!
	defer {
		pool.close()
	}
	idx := pool.acquire() or { panic('acquire') }
	mut c := pool.conn(idx)
	submit(mut c, 'select 41')!
	pool.release(idx) // abandoned with its reply still to come
	assert pool.conn(0).is_broken()
	for _ in 0 .. 500 {
		i := pool.acquire() or {
			time.sleep(2 * time.millisecond)
			continue
		}
		assert pool_query(mut pool, i, 'select 42')! == 42
		pool.release(i)
		return
	}
	assert false, 'the retired connection was not re-dialed'
}

// ── end to end: the HTTP server with a per-worker pool ──────────────────────

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn make_pool() voidptr {
	cfg := pg_async.ConnConfig{
		host:     '127.0.0.1'
		port:     os.getenv('VANILLA_FAKE_PG_PORT').int()
		user:     'u'
		password: 'secret'
		database: 'd'
	}
	pool := pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') }
	return voidptr(pool)
}

fn has_prefix(req []u8, prefix string) bool {
	return req.len >= prefix.len && unsafe { tos(req.data, prefix.len) } == prefix
}

// db_handler mirrors examples/async_db_pg with the persistent watch a pooled
// fd needs: GET /close and GET /fin pick the fake's server-side close, any
// other path a plain query. The body is the backend that answered.
fn db_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	query := if has_prefix(req, 'GET /close ') {
		'select backend -- then-close'
	} else if has_prefix(req, 'GET /fin ') {
		'select backend -- then-fin'
	} else {
		'select backend'
	}
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.acquire() or {
		out << resp_503
		return .done
	}
	mut conn := pool.conn(idx)
	if !conn.async_submit(query, []?[]u8{}) {
		pool.release(idx)
		out << resp_503
		return .done
	}
	flushed := conn.async_flush() or { false }
	if !flushed {
		pool.release(idx)
		out << resp_500
		return .done
	}
	event_loop.watch_fd_persistent(pool.fd(idx), .readable, on_db_ready, unsafe { nil })
	return .suspend
}

fn on_db_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.idx_of_fd(ready_fd) or { return .close }
	mut conn := pool.conn(idx)
	poll := conn.async_on_readable() or {
		pool.release(idx)
		out << resp_500
		return .done
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, .readable, on_db_ready, unsafe { nil })
		return .suspend
	}
	mut it := poll.result.rows()
	row := it.next() or {
		pool.release(idx)
		out << resp_500
		return .done
	}
	backend := row.int4(0) or { -1 }
	pool.release(idx)
	mut digits := [20]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	n := strconv.write_dec(i64(backend), mut view)
	ok_head := 'HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: '
	unsafe { out.push_many(ok_head.str, ok_head.len) }
	out << u8(`0` + n) // a backend id is a few digits, so its length is one
	unsafe { out.push_many(c'\r\n\r\n', 4) }
	unsafe { out.push_many(&digits[0], n) }
	return .done
}

// get sends one request on a fresh client connection and returns
// (status code, backend that answered — -1 when none did).
fn get(mut h vtest.Harness, path string) !(int, int) {
	o := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: 'GET ${path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		}]
	}])!
	assert o.conns[0].frames.len == 1, 'no response for ${path}'
	frame := o.conns[0].frames[0].bytestr()
	status := frame.all_after('HTTP/1.1 ').all_before(' ').int()
	body := frame.all_after('\r\n\r\n')
	return status, if body == '' { -1 } else { body.int() }
}

// Through the server: a connection closed while idle costs one 500, then every
// request is served (the other slot, then the re-dialed one); a reply that
// came with the FIN is a 200, and the loss it revealed costs no request.
fn test_server_pool_survives_server_side_closes() ! {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	os.setenv('VANILLA_FAKE_PG_PORT', fake.port.str(), true)
	mut h := vtest.start(server.ServerConfig{
		handler:    db_handler
		make_state: make_pool
		workers:    1
	})!
	defer {
		h.stop()
	}
	// Slot 0 (backend 0) answers, then the server closes it while idle.
	status, backend := get(mut h, '/close')!
	assert status == 200 && backend == 0
	time.sleep(300 * time.millisecond)

	mut failures := 0
	mut seen := []int{}
	for _ in 0 .. 500 {
		st, be := get(mut h, '/db')!
		if st != 200 {
			assert st == 500, 'status ${st}'
			failures++
			continue
		}
		seen << be
		if be == 2 {
			break // slot 0 is back: re-dialed as the fake's third connection
		}
	}
	assert failures == 1, 'one failure for the dead connection, got ${failures} (served by ${seen})'
	assert seen.last() == 2, 'slot 0 was not re-dialed: ${seen}'

	// The reply and the FIN together: a success, and the loss it revealed costs
	// no request — the FIN was read with the reply, so slot 0 is already known
	// broken. (The fake guarantees "together" on Linux only, via TCP_CORK;
	// elsewhere the FIN may come a read later and cost one request, as above.)
	st, be := get(mut h, '/fin')!
	assert st == 200 && be == 2, 'reply + FIN must be a 200 (got ${st})'
	seen.clear()
	failures = 0
	for _ in 0 .. 500 {
		st2, be2 := get(mut h, '/db')!
		if st2 != 200 {
			failures++
			continue
		}
		seen << be2
		if be2 == 3 {
			break
		}
	}
	$if linux {
		assert failures == 0, 'no request may fail for a loss already seen (served by ${seen})'
	} $else {
		assert failures <= 1
	}
	assert seen.last() == 3, 'slot 0 was not re-dialed after the FIN: ${seen}'
}
