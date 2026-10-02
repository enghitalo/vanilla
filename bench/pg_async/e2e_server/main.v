module main

// pg_async end-to-end benchmark server: examples/async_db_pg's handler shape
// with both pooling shapes and the failure loads the leak harness needs, kept
// allocation-free on every path it measures (routing included), so under
// -gc none any RSS growth is the driver's, not the harness's.
//
//   GET /db      acquire(): one query per pooled connection at a time
//   GET /dbp     acquire_pipelined(): up to max_inflight queries per connection
//   GET /dberr   acquire_pipelined() + `select 1/0`: the query-error path (500)
//   GET /dbslow  acquire_pipelined() + a 5 ms query: for clients that hang up
//                while their query is in flight (the tombstone path)
//   GET /health  no database
//
// /db, /dbp and /dbslow render pg_async_demo (3 rows, seeded by
// pg_async/testdata/throwaway_pg.sh) as JSON. Configuration: the PG* env vars
// (PGSSLMODE + PGSSLROOTCERT for TLS, in a -d vanilla_tls build), PG_POOL_SIZE
// (connections per worker, default 4), BENCH_PORT (default 8099),
// VANILLA_WORKERS. Driven by bench/pg_async/e2e.sh and leak.sh (TLS=1 for both).
import os
import strconv
import server
import core
import pg_async

const q_rows = 'select id, name from pg_async_demo order by id'

const q_err = 'select 1/0'

const q_slow = 'select id, name from pg_async_demo, pg_sleep(0.005) order by id'

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const resp_json_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()

const resp_json_sep = '\r\nConnection: keep-alive\r\n\r\n'.bytes()

const row_id_key = '{"id":'.bytes()

const row_name_key = ',"name":'.bytes()

// watch_payload carries the slot index plus this flag: the slot was taken
// exclusively (acquire()) and must be released when the request ends.
const exclusive_flag = u64(1) << 32

struct DbState {
mut:
	pool &pg_async.PgPool
	body []u8
}

fn env_or(name string, dflt string) string {
	v := os.getenv(name)
	return if v != '' { v } else { dflt }
}

fn build_state() voidptr {
	cfg := pg_async.ConnConfig{
		host:          env_or('PGHOST', '127.0.0.1')
		port:          env_or('PGPORT', '5432').int()
		user:          os.getenv('PGUSER')
		password:      os.getenv('PGPASSWORD')
		database:      os.getenv('PGDATABASE')
		ssl_mode:      pg_async.SslMode.from_string(env_or('PGSSLMODE', 'disable').replace('-', '_')) or {
			panic('pg_async bench: PGSSLMODE must be disable, require, verify-ca or verify-full')
		}
		ssl_root_cert: os.getenv('PGSSLROOTCERT')
	}
	pool := pg_async.new_pool(cfg, env_or('PG_POOL_SIZE', '4').int()) or {
		panic('pg_async bench: pool bring-up failed: ${err}')
	}
	return voidptr(&DbState{
		pool: pool
		body: []u8{cap: 512}
	})
}

// path_is reports whether the request line's target is exactly `path`:
// "GET " + path + " ", compared in place (no allocation).
@[direct_array_access]
fn path_is(req []u8, path string) bool {
	if req.len < 5 + path.len || req[4 + path.len] != ` ` {
		return false
	}
	return unsafe { vmemcmp(&u8(req.data) + 4, path.str, path.len) } == 0
}

fn handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &DbState(worker_state) }
	if path_is(req, '/dbp') {
		return park_query(mut st, q_rows, false, mut out, mut event_loop)
	}
	if path_is(req, '/db') {
		return park_query(mut st, q_rows, true, mut out, mut event_loop)
	}
	if path_is(req, '/dberr') {
		return park_query(mut st, q_err, false, mut out, mut event_loop)
	}
	if path_is(req, '/dbslow') {
		return park_query(mut st, q_slow, false, mut out, mut event_loop)
	}
	if path_is(req, '/health') {
		out << resp_ok
		return .done
	}
	out << resp_404
	return .done
}

// park_query submits `query` on a pooled connection and parks the request on
// its socket (watch_fd_persistent: the pool owns and reuses it).
fn park_query(mut st DbState, query string, exclusive bool, mut out []u8, mut event_loop core.EventLoop) core.Step {
	slot := if exclusive { st.pool.acquire() } else { st.pool.acquire_pipelined() }
	idx := slot or {
		out << resp_503
		return .done
	}
	mut conn := st.pool.conn(idx)
	if !conn.async_submit(query, []?[]u8{}) {
		if exclusive {
			st.pool.release(idx)
		}
		out << resp_503
		return .done
	}
	// From here on the query is in the connection's in-flight FIFO: the
	// request parks for its outcome whatever the flush did. A partial flush
	// finishes in on_db_ready (async_wants_write); a failed one breaks the
	// connection, and async_on_readable then reports the error. Answering
	// without parking would leave the entry unconsumed, and the slot would
	// never be re-dialed (pool.v's FIFO contract).
	conn.async_flush() or {}
	payload := u64(idx) | if exclusive { exclusive_flag } else { u64(0) }
	event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, on_db_ready, voidptr(payload))
	return .suspend
}

fn on_db_ready(mut out []u8, ready_fd int, _ bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &DbState(worker_state) }
	payload := u64(watch_payload)
	idx := int(payload & 0xffff_ffff)
	exclusive := payload & exclusive_flag != 0
	mut conn := st.pool.conn(idx)
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	poll := conn.async_on_readable() or {
		if exclusive {
			st.pool.release(idx)
		}
		out << resp_500
		return .done
	}
	if !poll.ready {
		// Not complete yet: keep waiting, even on ready_fd_error. A socket
		// error breaks the connection inside async_on_readable, and a broken
		// connection never reports not-ready, so this cannot spin on a dead
		// fd; answering here instead would abandon the query in the FIFO.
		event_loop.watch_fd_persistent(ready_fd, .readable, on_db_ready, watch_payload)
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
	if exclusive {
		st.pool.release(idx)
	}
	wb(mut out, resp_json_head)
	wi(mut out, st.body.len)
	wb(mut out, resp_json_sep)
	wb(mut out, st.body)
	return .done
}

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

fn json_escape_into(mut out []u8, s []u8) {
	out << `"`
	for c in s {
		if c == `"` || c == `\\` {
			out << `\\`
			out << c
		} else if c < 0x20 {
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
	out << `"`
}

@[inline]
fn hex_digit(n u8) u8 {
	return if n < 10 { `0` + n } else { `a` + (n - 10) }
}

fn main() {
	mut s := server.new_server(server.ServerConfig{
		port:       env_or('BENCH_PORT', '8099').int()
		handler:    handler
		make_state: build_state
	})!
	s.run()
}
