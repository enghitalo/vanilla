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

fn test_is_user_id() {
	assert is_user_id('1')
	assert is_user_id('42')
	assert is_user_id('2147483647')
	for bad in ['', '0x1', '1 ', ' 1', '1.0', '1e3', '2147483648', '99999999999', '1;', "1'"] {
		assert !is_user_id(bad), bad
	}
}
