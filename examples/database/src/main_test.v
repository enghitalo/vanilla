module main

import db.pg

// SQL-injection regression (#193). The `/user/<id>` segment is validated before
// the database is touched, then bound as a query parameter. No PostgreSQL
// needed: the pool below holds no connection and is CLOSED, so any request that
// reaches the database layer gets the controller's 500. A 400 therefore proves
// the query was never executed.
// (`${}` here is TEST scaffolding — the example code never interpolates SQL.)

fn closed_pool() ConnectionPool {
	connections := chan pg.DB{cap: 1}
	connections.close()
	return ConnectionPool{
		connections: connections
	}
}

fn get(path string) string {
	mut pool := closed_pool()
	mut out := []u8{}
	handle_request('GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, mut pool)
	return out.bytestr()
}

fn test_injection_payloads_get_400_without_touching_the_database() {
	for path in [
		'/user/1/**/OR/**/1=1', // was: every row
		'/user/1;SELECT/**/1', // was: a second statement (PQexec runs them all)
		'/user/1;DELETE/**/FROM/**/users', // was: the table emptied
		'/user/abc',
		'/user/',
		'/user/-1',
		'/user/+1',
		'/user/1?x=1',
		'/user/2147483648', // int4 overflow
		'/user/12345678901', // too many digits
	] {
		resp := get(path)
		assert resp.starts_with('HTTP/1.1 400 Bad Request'), '${path} -> ${resp}'
	}
}

fn test_integer_id_reaches_the_database() {
	// Control for the test above: a valid id passes validation and hits the
	// closed pool (500), so the 400s are the validation, not some other path.
	for path in ['/user/1', '/user/007', '/user/2147483647'] {
		resp := get(path)
		assert resp.starts_with('HTTP/1.1 500 Internal Server Error'), '${path} -> ${resp}'
	}
}

// append_rows_response sends exactly what the old builder code did:
// `row.str()` + '\n' per row for GET /user, the rows joined by '\n' for
// GET /user/<id>, framed with the body's Content-Length. `out` starts non-empty
// and full, so the splice runs at an offset and through a regrow.
fn test_rows_response_matches_the_builder_format() {
	rows := [pg.Row{
		vals: [?string('1'), ?string('new_user')]
	}, pg.Row{
		vals: [?string('2'), ?string('second')]
	}]
	for n in 0 .. rows.len + 1 {
		for trailing in [true, false] {
			mut body := ''
			if trailing {
				for row in rows[..n] {
					body += row.str() + '\n'
				}
			} else {
				body = rows[..n].map(it.str()).join('\n')
			}
			mut out := 'prefix'.bytes()
			append_rows_response(mut out, rows[..n], trailing)
			assert out.bytestr() == 'prefixHTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n${body}'
		}
	}
}

// The routes that answer before the database allocate nothing: 20k rounds
// through one reused buffer must not move the collector's lifetime counter.
// Routes that reach the pool are left out: they block on libpq and allocate
// its result (and, on this closed pool, acquire's error).
fn test_routes_before_the_database_allocate_nothing() {
	$if gcboehm ? {
		mut pool := closed_pool()
		reqs := [
			'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /user/1;DELETE HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle_request(r, mut out, mut pool)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle_request(r, mut out, mut pool)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

fn test_is_user_id() {
	assert is_user_id('1')
	assert is_user_id('42')
	assert is_user_id('2147483647')
	for bad in ['', '0x1', '1 ', ' 1', '1.0', '1e3', '2147483648', '99999999999', '1;', "1'"] {
		assert !is_user_id(bad), bad
	}
}
