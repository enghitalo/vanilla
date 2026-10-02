// vtest build: linux
// Pool maintenance through the server, against a LIVE PostgreSQL (skipped
// unless PGHOST is set): every pooled backend is terminated while idle
// (pg_terminate_backend), and the maintenance timer started from
// on_worker_start re-dials them before any request meets a dead connection.
import os
import time
import strconv
import server
import core
import pg_async
import vtest

fn live_cfg() ?pg_async.ConnConfig {
	host := os.getenv('PGHOST')
	if host == '' {
		return none
	}
	port_env := os.getenv('PGPORT')
	return pg_async.ConnConfig{
		host:     host
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
}

fn make_live_pool() voidptr {
	cfg := live_cfg() or { panic('PGHOST unset') }
	return voidptr(pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') })
}

fn start_pool_maintenance(worker_state voidptr, mut event_loop core.EventLoop) {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	pool.start_maintenance(mut event_loop) or { panic(err) }
}

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn pid_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.acquire() or {
		out << resp_503
		return .done
	}
	mut conn := pool.conn(idx)
	if !conn.async_submit('select pg_backend_pid()', []?[]u8{}) {
		pool.release(idx)
		out << resp_503
		return .done
	}
	conn.async_flush() or {}
	event_loop.watch_fd_persistent(pool.fd(idx), .readable, on_pid_ready, unsafe { nil })
	return .suspend
}

fn on_pid_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.idx_of_fd(ready_fd) or { return .close }
	mut conn := pool.conn(idx)
	poll := conn.async_on_readable() or {
		pool.release(idx)
		out << resp_500
		return .done
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, .readable, on_pid_ready, unsafe { nil })
		return .suspend
	}
	mut it := poll.result.rows()
	pid := (it.next() or {
		pool.release(idx)
		out << resp_500
		return .done
	}).int4(0) or { -1 }
	pool.release(idx)
	body := strconv.format_int(pid, 10)
	out << ('HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: ' + body.len.str() +
		'\r\n\r\n' + body).bytes()
	return .done
}

fn get_pid(mut h vtest.Harness) !(int, int) {
	o := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: 'GET /db HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		}]
	}])!
	frame := o.conns[0].frames[0].bytestr()
	return frame.all_after('HTTP/1.1 ').all_before(' ').int(), frame.all_after('\r\n\r\n').int()
}

fn terminate_others(mut admin pg_async.PgConn) !int {
	res := admin.query("select count(pg_terminate_backend(pid))::int4 from pg_stat_activity where usename = current_user and pid <> pg_backend_pid() and backend_type = 'client backend'",
		[]?[]u8{})!
	mut it := res.rows()
	return (it.next() or { return error('no row') }).int4(0)!
}

fn test_maintenance_redials_terminated_backends_before_requests_meet_them() ! {
	cfg := live_cfg() or {
		eprintln('pg_async: skipping live maintenance test (set PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)')
		return
	}
	mut h := vtest.start(server.ServerConfig{
		handler:         pid_handler
		make_state:      make_live_pool
		on_worker_start: start_pool_maintenance
		workers:         1
	})!
	defer {
		h.stop()
	}
	st0, before := get_pid(mut h)!
	assert st0 == 200
	mut admin := pg_async.PgConn.connect(cfg)!
	defer {
		admin.close()
	}
	killed := terminate_others(mut admin)!
	assert killed >= 2, 'expected both pooled backends to be terminated, got ${killed}'
	// One idle tick (1 s) finds them; the re-dial runs on the following fast ticks.
	time.sleep(1500 * time.millisecond)
	mut failures := 0
	mut pids := map[int]bool{}
	for _ in 0 .. 20 {
		st, pid := get_pid(mut h)!
		if st != 200 {
			failures++
			continue
		}
		pids[pid] = true
	}
	assert failures == 0, '${failures} of 20 requests failed after the backends were terminated'
	assert before !in pids, 'a terminated backend (${before}) still answered'
}
