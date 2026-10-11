module main

import core
import db.pg
import http1_1.response
import json2

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

fn serve(raw string) (core.Step, string) {
	mut pool := closed_pool()
	mut out := []u8{}
	step := handle_request(raw.bytes(), mut out, mut pool)
	return step, out.bytestr()
}

fn get(path string) string {
	_, resp := serve('GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n')
	return resp
}

fn test_injection_payloads_get_400_without_touching_the_database() {
	for path in [
		'/user/1/**/OR/**/1=1', // was: every row
		'/user/1;SELECT/**/1', // was: a second statement (PQexec runs them all)
		'/user/1;DELETE/**/FROM/**/users', // was: the table emptied
		'/user/1;DELETE/**/FROM/**/users?x=1', // only the query is cut off
		'/user/abc',
		'/user/abc?x=1',
		'/user/',
		'/user/?x=1',
		'/user/-1',
		'/user/+1',
		'/user/2147483648', // int4 overflow
		'/user/12345678901', // too many digits
	] {
		assert get(path) == http_bad_request_response, path
	}
}

fn test_integer_id_reaches_the_database() {
	// Control for the test above: a valid id passes validation and hits the
	// closed pool (500), so the 400s are the validation, not some other path.
	// Routing drops the query string, so `/user/1?x=1` is `/user/1`: what
	// reaches the pool is still an id that passed is_user_id, digits only.
	for path in ['/user/1', '/user/007', '/user/2147483647', '/user/1?x=1',
		'/user/1?id=1;DELETE/**/FROM/**/users'] {
		assert get(path) == tiny_internal_server_error_response, path
	}
}

// Every route by method and path, query string or not. The routes that need
// the database get the closed pool's 500.
const route_answers = {
	'GET /':          http_ok_response
	'GET /?x=1':      http_ok_response
	'GET /user':      tiny_internal_server_error_response
	'GET /user?x=1':  tiny_internal_server_error_response
	'POST /user':     tiny_internal_server_error_response
	'POST /user?x=1': tiny_internal_server_error_response
	'GET /user/1':    tiny_internal_server_error_response
	'GET /user/abc':  http_bad_request_response
	'GET /nope':      http_not_found_response
	'GET /nope?x=1':  http_not_found_response
	'GET /users':     http_not_found_response
	'GET /user/1/':   http_bad_request_response
	'POST /':         http_not_found_response
	'POST /user/1':   http_not_found_response
	'DELETE /user':   http_not_found_response
	'PUT /user/1':    http_not_found_response
}

// Every request that parses is answered with `.done` and says so:
// `Connection: keep-alive`, never `close` (RFC 9112 §9.6).
fn test_every_answer_keeps_the_connection() {
	for line, want in route_answers {
		step, resp := serve('${line} HTTP/1.1\r\nHost: x\r\n\r\n')
		assert step == .done, line
		assert resp == want, '${line} -> ${resp}'
		assert resp.contains('\r\nConnection: keep-alive\r\n'), line
		assert !resp.contains('close'), line
	}
}

// Only a request that does not parse gets the canned 400 with
// `Connection: close`, and the connection is closed.
fn test_a_malformed_request_gets_the_canned_400_and_closes() {
	for raw in ['GET /\r\n\r\n', ' GET / HTTP/1.1\r\n\r\n', 'GET / HTTP/1.1\nHost: x\n\n'] {
		step, resp := serve(raw)
		assert step == .close, raw
		assert resp == response.tiny_bad_request_response.bytestr(), raw
	}
}

const sample_rows = [
	pg.Row{
		vals: [?string('1'), ?string('new_user')]
	},
	pg.Row{
		vals: [?string('2'), ?string('a "quoted" \\ name\r\n\t\x01 é€😀')]
	},
	pg.Row{
		vals: [?string(none), ?string(none)]
	},
]

// The JSON object of each sample row.
const sample_objects = [
	r'{"id":1,"name":"new_user"}',
	r'{"id":2,"name":"a \"quoted\" \\ name\r\n\t\u0001 é€😀"}',
	r'{"id":null,"name":null}',
]

fn json_response(body string) string {
	return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'
}

// append_users_response renders real JSON: an array of objects for GET /user
// (empty, one row, several), one object for GET /user/<id>; the id as its
// digits, the name escaped, SQL NULL as `null`; framed with the body's
// Content-Length. `out` starts non-empty and full, so the splice runs at an
// offset and through a regrow.
fn test_users_response_is_json() {
	for n in 0 .. sample_rows.len + 1 {
		body := '[' + sample_objects[..n].join(',') + ']'
		mut out := 'prefix'.bytes()
		append_users_response(mut out, sample_rows[..n], true)
		assert out.bytestr() == 'prefix' + json_response(body), 'list of ${n}'
	}
	for i, row in sample_rows {
		mut out := 'prefix'.bytes()
		append_users_response(mut out, [row], false)
		assert out.bytestr() == 'prefix' + json_response(sample_objects[i]), 'row ${i}'
	}
	// A JSON parser reads the escaped name back as it was stored.
	name := sample_rows[1].vals[1] or { '' }
	mut out := []u8{}
	json_escape_into(mut out, name)
	assert json2.decode[string](out.bytestr()) or { panic(err) } == name
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
			'GET /?x=1 HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /user/1;DELETE HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /user/abc?x=1 HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
			'DELETE /user HTTP/1.1\r\nHost: x\r\n\r\n',
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

// Rendering the rows allocates nothing either: on GET /user and GET
// /user/<id>, what allocates is db.pg (its result rows, fabricated here).
fn test_json_rendering_allocates_nothing() {
	$if gcboehm ? {
		mut out := []u8{cap: 4096}
		append_users_response(mut out, sample_rows, true) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			append_users_response(mut out, sample_rows, true)
			unsafe {
				out.len = 0
			}
			append_users_response(mut out, sample_rows, false)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'rendering allocated ${grown} bytes over ${rounds * 2} responses'
	}
}

fn test_is_user_id() {
	assert is_user_id('1')
	assert is_user_id('42')
	assert is_user_id('2147483647')
	for bad in ['', '0x1', '1 ', ' 1', '1.0', '1e3', '2147483648', '99999999999', '1;', "1'", '1?x=1'] {
		assert !is_user_id(bad), bad
	}
}
