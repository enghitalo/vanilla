// vtest build: linux
// A query that hangs, end to end on the epoll reactor (vanilla#200): the
// request parks on its pooled connection with a deadline
// (watch_fd_persistent_deadline); when the deadline passes, the continuation
// cancels the query (PgConn.cancel, a CancelRequest driven as a background
// watch on the same worker) and answers 504. The cancelled query's reply
// (57014, then ReadyForQuery) is drained by the park's tombstone, so the next
// request on that same connection gets its own result. Against
// pg_async/testdata/fake_pg.py, whose `select pg_sleep(S)` a CancelRequest
// interrupts; one worker with a one-connection pool, so every request shares
// the connection. Both pool shapes: pipelined (acquire_pipelined) and
// exclusive (acquire/release: the tombstone run releases the connection).
// Skipped without python3 (unless VANILLA_REQUIRE_FAKE_PG is set). With
// PGHOST set it runs against that server too (its real pg_sleep).
import os
import server
import core
import pg_async
import sync.stdatomic
import testkit
import time
import transport
import vtest

const pc_504 = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n'

const pc_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n'

const pc_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'

const pc_200 = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n'

// The park deadline of /slow and /slowx: far below the query's 10 s.
const pc_deadline_ms = 200

// PcCounts is what the continuations saw (worker thread) for the checks
// (test thread): atomics only.
struct PcCounts {
mut:
	timeouts  i64 // continuation runs with timed_out()
	cancels   i64 // cancel() calls that started a request
	cancelled i64 // runs that consumed a 57014 (the tombstone's)
}

const pc = &PcCounts{}

struct PcState {
mut:
	pool &pg_async.PgPool
}

fn pc_state() voidptr {
	fake_port := os.getenv('PG_CANCEL_FAKE_PORT').int()
	cfg := if fake_port > 0 {
		pg_async.ConnConfig{
			host:     '127.0.0.1'
			port:     fake_port
			user:     'vanilla'
			password: 'secret'
			database: 'vanilla'
		}
	} else {
		pg_async.ConnConfig{
			host:          os.getenv('PGHOST')
			port:          if os.getenv('PGPORT') != '' { os.getenv('PGPORT').int() } else { 5432 }
			user:          os.getenv('PGUSER')
			password:      os.getenv('PGPASSWORD')
			database:      os.getenv('PGDATABASE')
			ssl_mode:      pg_async.SslMode.from_string(os.getenv('PGSSLMODE').replace('-', '_')) or {
				pg_async.SslMode.disable
			}
			ssl_root_cert: os.getenv('PGSSLROOTCERT')
		}
	}
	pool := pg_async.new_pool(cfg, 1) or { panic('pool bring-up failed: ${err}') }
	return voidptr(&PcState{
		pool: pool
	})
}

// GET /slow runs `select pg_sleep(10)` on the shared connection, pipelined;
// GET /slowx the same on the connection held exclusively; GET /q runs
// `select 7` (pipelined) and answers its digit.
fn pc_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PcState(worker_state) }
	exclusive := req.len > 10 && req[9] == `x`
	slow := req.len > 9 && req[5] == `s`
	mut idx := -1
	if exclusive {
		idx = st.pool.acquire() or { -1 }
	} else {
		idx = st.pool.acquire_pipelined() or { -1 }
	}
	if idx < 0 {
		core.append_str(mut out, pc_503)
		return .done
	}
	mut conn := st.pool.conn(idx)
	query := if slow { 'select pg_sleep(10)' } else { 'select 7' }
	if !conn.async_submit(query, []?[]u8{}) {
		if exclusive {
			st.pool.release(idx)
		}
		core.append_str(mut out, pc_503)
		return .done
	}
	conn.async_flush() or {}
	// The payload: the slot, and whether it is held exclusively (bit 16).
	payload := voidptr(usize(idx) | if exclusive { usize(1) << 16 } else { usize(0) })
	ms := if slow { pc_deadline_ms } else { 0 }
	event_loop.watch_fd_persistent_deadline(st.pool.fd(idx), .readable, pc_ready, payload,
		ms)
	return .suspend
}

fn pc_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PcState(worker_state) }
	mut c := unsafe { pc }
	idx := int(usize(watch_payload) & 0xffff)
	exclusive := usize(watch_payload) >> 16 != 0
	mut conn := st.pool.conn(idx)
	if event_loop.timed_out() {
		// The reply is still due: leave it (and the slot) to the tombstone run.
		// Ask the server to give up on the query, and answer now.
		stdatomic.add_i64(&c.timeouts, 1)
		if _ := conn.cancel(mut event_loop) {
			stdatomic.add_i64(&c.cancels, 1)
		}
		core.append_str(mut out, pc_504)
		return .done
	}
	poll := conn.async_on_readable() or {
		if err is pg_async.PgError && err.sqlstate == '57014' {
			stdatomic.add_i64(&c.cancelled, 1)
		}
		if exclusive {
			st.pool.release(idx)
		}
		core.append_str(mut out, pc_500)
		return .done
	}
	if !poll.ready {
		if ready_fd_error {
			if exclusive {
				st.pool.release(idx)
			}
			core.append_str(mut out, pc_500)
			return .done
		}
		event_loop.watch_fd_persistent_deadline(ready_fd, .readable, pc_ready, watch_payload,
			0)
		return .suspend
	}
	if exclusive {
		st.pool.release(idx)
	}
	mut it := poll.result.rows()
	row := it.next() or {
		core.append_str(mut out, pc_500)
		return .done
	}
	v := row.int4(0) or { 0 }
	core.append_str(mut out, pc_200)
	out << u8(48 + v) // one digit
	return .done
}

fn pc_send(port int, path string) !int {
	fd := transport.dial_tcp('127.0.0.1', port)!
	if !testkit.fd_write_all(fd, 'GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 3000) {
		transport.close_fd(fd)
		return error('could not write the request')
	}
	return fd
}

fn pc_until(p &i64, want i64) i64 {
	for _ in 0 .. 3000 {
		if stdatomic.load_i64(p) >= want {
			break
		}
		time.sleep(time.millisecond)
	}
	return stdatomic.load_i64(p)
}

// pc_check runs the scenario against the fake (live false) or the PGHOST
// server (live true).
fn pc_check(slow_path string, live bool) ! {
	mut c := unsafe { pc }
	for f in [&c.timeouts, &c.cancels, &c.cancelled] {
		stdatomic.store_i64(f, 0)
	}
	mut fake := if live { testkit.FakePg{} } else { testkit.start_fake_pg([])! }
	defer {
		if !live {
			fake.stop()
		}
	}
	os.setenv('PG_CANCEL_FAKE_PORT', fake.port.str(), true)
	mut h := vtest.start(server.ServerConfig{
		handler:    pc_handler
		make_state: pc_state
		workers:    1
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	a := pc_send(h.port(), slow_path)!
	defer {
		transport.close_fd(a)
	}
	got_a := testkit.fd_read_until(a, '\r\n\r\n', 3000)
	took := sw.elapsed().milliseconds()
	assert got_a.starts_with('HTTP/1.1 504 '), '${slow_path}: no 504 after ${took} ms: ${got_a}'
	assert took >= pc_deadline_ms - 20 && took < 2000, '${slow_path}: a ${pc_deadline_ms} ms deadline answered after ${took} ms'
	assert pc_until(&c.cancelled, 1) == 1, '${slow_path}: the cancelled reply was not drained'
	assert stdatomic.load_i64(&c.timeouts) == 1
	assert stdatomic.load_i64(&c.cancels) == 1
	if !live {
		assert fake.stat('cancels_honored') == 1
		assert fake.stat('cancelled') == 1
	}
	// The same connection, the next request: its own result, not the 57014.
	assert testkit.fd_write_all(a, 'GET /q HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 1000)
	got_q := testkit.fd_read_until(a, '\r\n\r\n7', 3000)
	assert got_q.ends_with('\r\n\r\n7'), '${slow_path}: the next query did not get its own result: ${got_q}'
	if !live {
		assert fake.stat('authenticated') == 1, '${slow_path}: the pooled connection was replaced'
	}
	assert sw.elapsed().milliseconds() < 3000, 'the 10 s query was waited out'
}

fn test_pg_async_cancel_on_park_timeout_pipelined() ! {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping the cancel e2e (no python3)')
		return
	}
	pc_check('/slow', false)!
}

fn test_pg_async_cancel_on_park_timeout_exclusive() ! {
	if !testkit.fake_pg_available() {
		return
	}
	pc_check('/slowx', false)!
}

fn test_pg_async_cancel_on_park_timeout_live() ! {
	if os.getenv('PGHOST') == '' {
		eprintln('pg_async: skipping the live cancel e2e (no PGHOST)')
		return
	}
	pc_check('/slow', true)!
	pc_check('/slowx', true)!
}
