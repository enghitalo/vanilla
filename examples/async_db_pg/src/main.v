module main

import os
import strconv
import server
import core
import pg_async
import http1_1.request_parser
import http1_1.response

// End-to-end demo of the native async Postgres driver (pg_async) on the epoll
// async runtime. Each worker owns its own connection pool (via make_state); a
// GET /db request acquires a connection, issues a query, parks on the PG socket
// with event_loop.watch_fd_persistent, and the continuation renders the rows
// once they arrive — all on the worker's single epoll loop, never blocking it.
// This is the template the HttpArena framework's async-db/fortunes endpoints
// follow.
//
// Bring up the demo table first, e.g.:
//   create table pg_async_demo (id int4 primary key, name text);
//   insert into pg_async_demo values (1,'alpha'),(2,'beta'),(3,'gamma');
// Then run with PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE set.

const pool_size = 4

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const resp_json_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '

const resp_json_sep = '\r\nConnection: keep-alive\r\n\r\n'

const row_id_key = '{"id":'

const row_name_key = ',"name":'

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

// start_maintenance runs the pool's maintenance timer on this worker: a
// connection the server closes while idle (restart, idle timeout, a managed
// database's connection lifetime) is found within ~1 s and re-dialed before a
// request meets it, instead of failing the next query on it.
fn start_maintenance(worker_state voidptr, mut event_loop core.EventLoop) {
	mut st := unsafe { &DbState(worker_state) }
	st.pool.start_maintenance(mut event_loop) or { eprintln('async_db_pg: ${err}') }
}

// route_is reports whether the request path, without its query string, is
// `lit`. req.path includes the query, so the compare stops at the first `?`.
// It compares bytes in place: the request is never copied.
@[direct_array_access]
fn route_is(req request_parser.HttpRequest, lit string) bool {
	mut n := 0
	for n < req.path.len && req.buffer[req.path.start + n] != `?` {
		n++
	}
	if n != lit.len {
		return false
	}
	for i in 0 .. n {
		if req.buffer[req.path.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// handler: GET /db runs a query via the pool + a watch on the PG socket; any
// other path replies synchronously.
fn handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		out << response.tiny_bad_request_response
		return .close
	}
	if !route_is(r, '/db') {
		core.append_str(mut out, resp_ok)
		return .done
	}
	mut st := unsafe { &DbState(worker_state) }
	idx := st.pool.acquire() or {
		core.append_str(mut out, resp_503)
		return .done
	}
	mut conn := st.pool.conn(idx)
	if !conn.async_submit(r'select id, name from pg_async_demo order by id', []?[]u8{}) {
		// Connection saturated (pipeline full) — shed.
		st.pool.release(idx)
		core.append_str(mut out, resp_503)
		return .done
	}
	flushed := conn.async_flush() or {
		st.pool.release(idx)
		core.append_str(mut out, resp_500)
		return .done
	}
	if !flushed {
		// Tiny queries flush in one write; a partial send is a v1 edge we don't handle.
		st.pool.release(idx)
		core.append_str(mut out, resp_500)
		return .done
	}
	// The pool owns this socket and reuses it, so park with watch_fd_persistent,
	// never watch_fd. If the client disconnects mid-query, a plain watch_fd would
	// close the pooled socket and drop the continuation: release() would never
	// run, and after pool_size such disconnects every /db on this worker gets 503.
	// The persistent watch keeps the socket open and still runs on_db_ready when
	// the reply arrives (its response is discarded), which drains the reply and
	// releases the slot. The slot index rides in watch_payload.
	event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, on_db_ready, voidptr(usize(idx)))
	return .suspend
}

// on_db_ready runs when the watched PG socket is readable: it pumps the result
// and, once complete, renders the rows as JSON and releases the connection.
// Every path that does not re-arm releases the slot.
fn on_db_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &DbState(worker_state) }
	idx := int(usize(watch_payload))
	mut conn := st.pool.conn(idx)
	poll := conn.async_on_readable() or {
		st.pool.release(idx)
		core.append_str(mut out, resp_500)
		return .done
	}
	if !poll.ready {
		if ready_fd_error {
			// Error/hangup with the reply still incomplete: the socket is dead.
			// Re-arming a dead level-triggered fd would busy-spin the worker.
			st.pool.release(idx)
			core.append_str(mut out, resp_500)
			return .done
		}
		event_loop.watch_fd_persistent(ready_fd, .readable, on_db_ready, watch_payload) // more bytes to come
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
		core.append_str(mut st.body, row_id_key)
		wi(mut st.body, row.int4(0) or { -1 })
		core.append_str(mut st.body, row_name_key)
		json_escape_into(mut st.body, row.text(1) or { []u8{} })
		st.body << `}`
	}
	st.body << `]`
	st.pool.release(idx)
	core.append_str(mut out, resp_json_head)
	wi(mut out, st.body.len)
	core.append_str(mut out, resp_json_sep)
	wb(mut out, st.body)
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
