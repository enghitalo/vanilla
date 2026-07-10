module main

import os
import http_server
import http_server.core
import pg_async

// End-to-end demo of the native async Postgres driver (pg_async) on the epoll
// async runtime. Each worker owns its own connection pool (via make_state); a
// GET /db request acquires a connection, issues a query, parks on the PG socket
// with ctx.watch, and the continuation renders the rows once they arrive — all on
// the worker's single epoll loop, never blocking it. This is the template the
// HttpArena framework's async-db/fortunes endpoints follow.
//
// Bring up the demo table first, e.g.:
//   create table pg_async_demo (id int4 primary key, name text);
//   insert into pg_async_demo values (1,'alpha'),(2,'beta'),(3,'gamma');
// Then run with PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE set.

const pool_size = 4

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

fn env_or(name string, dflt string) string {
	v := os.getenv(name)
	return if v != '' { v } else { dflt }
}

// build_pool brings up this worker's Postgres pool from the standard PG* env
// vars and returns it as the opaque per-worker state.
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
	return voidptr(pool)
}

fn targets_db(req []u8) bool {
	return req.bytestr().contains(' /db') // crude routing — fine for a demo
}

// handler: GET /db runs a query via the pool + a watch on the PG socket; any
// other path replies synchronously.
fn handler(req []u8, mut out []u8, mut ctx core.Ctx) core.Step {
	if !targets_db(req) {
		out << resp_ok
		return .done
	}
	mut pool := unsafe { &pg_async.PgPool(ctx.state) }
	idx := pool.acquire() or {
		out << resp_503
		return .done
	}
	mut conn := pool.conn(idx)
	if !conn.async_submit(r'select id, name from pg_async_demo order by id', []?[]u8{}) {
		// Connection saturated (pipeline full) — shed.
		pool.release(idx)
		out << resp_503
		return .done
	}
	flushed := conn.async_flush() or {
		pool.release(idx)
		out << resp_500
		return .done
	}
	if !flushed {
		// Tiny queries flush in one write; a partial send is a v1 edge we don't handle.
		pool.release(idx)
		out << resp_500
		return .done
	}
	ctx.watch(pool.fd(idx), .readable, on_db_ready, unsafe { nil })
	return .suspend
}

// on_db_ready runs when the watched PG socket is readable: it pumps the result
// and, once complete, renders the rows as JSON and releases the connection.
fn on_db_ready(mut out []u8, mut ctx core.Ctx) core.Step {
	mut pool := unsafe { &pg_async.PgPool(ctx.state) }
	idx := pool.idx_of_fd(ctx.ready_fd) or { return .close }
	mut conn := pool.conn(idx)
	poll := conn.async_on_readable() or {
		pool.release(idx)
		out << resp_500
		return .done
	}
	if !poll.ready {
		ctx.watch(pool.fd(idx), .readable, on_db_ready, unsafe { nil }) // re-arm: more bytes to come
		return .suspend
	}
	mut body := []u8{cap: 512}
	body << `[`
	mut it := poll.result.rows()
	mut first := true
	for {
		row := it.next() or { break }
		if !first {
			body << `,`
		}
		first = false
		id := row.int4(0) or { -1 }
		name := row.text(1) or { ''.bytes() }
		body << '{"id":${id},"name":"'.bytes()
		body << name
		body << '"}'.bytes()
	}
	body << `]`
	pool.release(idx)
	out << 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n'.bytes()
	out << body
	return .done
}

fn main() {
	mut s := http_server.new_server(http_server.ServerConfig{
		port:       8099
		handler:    handler
		make_state: build_pool
	})!
	println('async_db_pg listening on http://localhost:8099/ (GET /db, GET /health)')
	s.run()
}
