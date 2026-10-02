module main

import os
import strconv
import server
import core
import pg_async

// End-to-end demo of the native async Postgres driver (pg_async) on the epoll
// async runtime. Each worker owns its own connection pool (via make_state); a
// GET /db request acquires a connection, issues a query, parks on the PG socket
// with event_loop.watch_fd_persistent, and the continuation renders the rows
// once they arrive — all on the worker's single epoll loop, never blocking it.
// on_worker_start runs the pool's maintenance timer, which re-dials a
// connection the server closed (a restart, a failover, pg_terminate_backend)
// off the request path. Answers are honest: 500 when the server failed the
// query, 503 when the database could not answer (pool exhausted, connection
// lost) — a retry may succeed.
// This is the template the HttpArena framework's async-db/fortunes endpoints
// follow.
//
// Bring up the demo table first, e.g.:
//   create table pg_async_demo (id int4 primary key, name text);
//   insert into pg_async_demo values (1,'alpha'),(2,'beta'),(3,'gamma');
// Then run with PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE set.

const pool_size = 4

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const resp_json_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()

const resp_json_sep = '\r\nConnection: keep-alive\r\n\r\n'.bytes()

const row_id_key = '{"id":'.bytes()

const row_name_key = ',"name":'.bytes()

// DbState is one worker's make_state value: its connection pool and a render
// scratch for the JSON body, reused by every response on that worker.
struct DbState {
mut:
	pool &pg_async.PgPool
	body []u8
}

fn env_or(name string, dflt string) string {
	v := os.getenv(name)
	return if v != '' { v } else { dflt }
}

// build_pool brings up this worker's Postgres pool from the standard PG* env
// vars and returns it, with the render scratch, as the opaque per-worker state.
fn build_pool() voidptr {
	port_env := os.getenv('PGPORT')
	cfg := pg_async.ConnConfig{
		host:     env_or('PGHOST', 'localhost')
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	pool := pg_async.new_pool(cfg, pool_size) or {
		panic('async_db_pg: pool bring-up failed: ${err}')
	}
	return voidptr(&DbState{
		pool: pool
		body: []u8{cap: 512}
	})
}

// start_maintenance re-dials this worker's broken connections from a timer.
fn start_maintenance(worker_state voidptr, mut event_loop core.EventLoop) {
	mut st := unsafe { &DbState(worker_state) }
	st.pool.start_maintenance(mut event_loop) or { eprintln('async_db_pg: ${err}') }
}

fn targets_db(req []u8) bool {
	return req.bytestr().contains(' /db') // crude routing — fine for a demo
}

// handler: GET /db runs a query via the pool + a watch on the PG socket; any
// other path replies synchronously.
fn handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !targets_db(req) {
		out << resp_ok
		return .done
	}
	mut st := unsafe { &DbState(worker_state) }
	idx := st.pool.acquire() or {
		out << resp_503 // every connection busy (or being re-dialed): shed
		return .done
	}
	mut conn := st.pool.conn(idx)
	queued := conn.submit(r'select id, name from pg_async_demo order by id', []?[]u8{}) or {
		false // the connection broke since it was handed out: nothing was sent
	}
	if !queued {
		st.pool.release(idx)
		out << resp_503
		return .done
	}
	// The query is in flight: park for its outcome even if this flush fails —
	// the continuation then receives the error. The pool owns this socket and
	// reuses it, so park with watch_fd_persistent, never watch_fd. If the client
	// disconnects mid-query, a plain watch_fd would close the pooled socket and
	// drop the continuation: release() would never run, and after pool_size such
	// disconnects every /db on this worker gets 503. The persistent watch keeps
	// the socket open and still runs on_db_ready when the reply arrives (its
	// response is discarded), which drains the reply and releases the slot. The
	// slot index rides in watch_payload.
	conn.async_flush() or {}
	event_loop.watch_fd_persistent(st.pool.fd(idx), interest(conn), on_db_ready, voidptr(usize(idx)))
	return .suspend
}

// interest is what the parked request waits for: writability while request
// bytes are still unsent (a full socket buffer), else the reply.
fn interest(conn &pg_async.PgConn) core.WatchInterest {
	return if conn.async_wants_write() { .writable } else { .readable }
}

// on_db_ready runs when the watched PG socket is ready: it pumps the result
// and, once complete, renders the rows as JSON and releases the connection.
// Every path that does not re-arm releases the slot.
fn on_db_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &DbState(worker_state) }
	idx := int(usize(watch_payload))
	mut conn := st.pool.conn(idx)
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	mut poll := conn.async_on_readable() or { return db_failed(mut st, idx, err, mut out) }
	if !poll.ready && ready_fd_error {
		// Error/hangup with the reply still incomplete: the socket is dead.
		// Re-arming a dead level-triggered fd would busy-spin the worker; give
		// up on the connection instead, which ends this query (unknown).
		conn.mark_broken()
		poll = conn.async_on_readable() or { return db_failed(mut st, idx, err, mut out) }
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, interest(conn), on_db_ready, watch_payload) // more bytes to come
		return .suspend
	}
	unsafe {
		st.body.len = 0
	}
	st.body << `[`
	mut it := poll.result.rows()
	mut first := true
	for {
		row := it.next() or { break }
		if !first {
			st.body << `,`
		}
		first = false
		wb(mut st.body, row_id_key)
		wi(mut st.body, row.int4(0) or { -1 })
		wb(mut st.body, row_name_key)
		json_escape_into(mut st.body, row.text(1) or { []u8{} })
		st.body << `}`
	}
	st.body << `]`
	st.pool.release(idx)
	wb(mut out, resp_json_head)
	wi(mut out, st.body.len)
	wb(mut out, resp_json_sep)
	wb(mut out, st.body)
	return .done
}

// db_failed answers a query that ended in an error and releases its slot: 500
// when the server failed the statement, 503 when the connection was lost (the
// outcome is unknown; a read like this one is safe to retry).
fn db_failed(mut st DbState, idx int, err IError, mut out []u8) core.Step {
	st.pool.release(idx)
	if err is pg_async.PgError && err.kind == .server {
		out << resp_500
	} else {
		out << resp_503
	}
	return .done
}

// wb/wi — the zero-alloc append helpers (docs/BEST_PRACTICES.md §3b).
@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// json_escape_into appends s as a quoted JSON string (RFC 8259): a row value
// containing `"`, `\` or a control character must not break the document.
fn json_escape_into(mut out []u8, s []u8) {
	out << `"`
	for c in s {
		match c {
			`"` {
				out << `\\`
				out << `"`
			}
			`\\` {
				out << `\\`
				out << `\\`
			}
			`\n` {
				out << `\\`
				out << `n`
			}
			`\r` {
				out << `\\`
				out << `r`
			}
			`\t` {
				out << `\\`
				out << `t`
			}
			else {
				if c < 0x20 {
					out << `\\`
					out << `u`
					out << `0`
					out << `0`
					out << hex_digit(c >> 4)
					out << hex_digit(c & 0x0f)
				} else {
					out << c
				}
			}
		}
	}
	out << `"`
}

@[inline]
fn hex_digit(n u8) u8 {
	return if n < 10 { `0` + n } else { `a` + (n - 10) }
}

fn main() {
	mut s := server.new_server(server.ServerConfig{
		port:            8099
		handler:         handler
		make_state:      build_pool
		on_worker_start: start_maintenance
	})!
	println('async_db_pg listening on http://localhost:8099/ (GET /db, GET /health)')
	s.run()
}
