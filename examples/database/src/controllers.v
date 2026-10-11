module main

// Controllers append the response straight into the caller-owned `out`
// (docs/BEST_PRACTICES.md §3): no builder, no return-then-copy, no `.str()`.
// They call libpq synchronously, so a worker thread blocks on every query
// (BEST_PRACTICES §5); examples/async_db_pg is the non-blocking version.
import core
import db.pg
import strconv
import http1_1.response

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const tiny_internal_server_error_response = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

// The 200 text/plain head, split around its Content-Length digits.
const rows_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: '
const rows_tail = '\r\nConnection: close\r\n\r\n'

fn home_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

// append_rows_response appends a 200 text/plain response listing one
// `row.str()` (V's dump of the pg.Row struct) per row, separated by '\n'
// (`trailing`: '\n' after every row). The query result and that text are what
// these routes still allocate. A row's text exists only once `row.str()`
// has made it, so the body goes straight into `out` and its length is spliced
// in front of it afterwards (one memmove over the body), instead of building
// the body in a strings.Builder first just to measure it.
fn append_rows_response(mut out []u8, rows []pg.Row, trailing bool) {
	core.append_str(mut out, rows_head)
	at := out.len // the Content-Length digits go here
	core.append_str(mut out, rows_tail)
	body := out.len
	for i, row in rows {
		if i > 0 && !trailing {
			out << `\n`
		}
		core.append_str(mut out, row.str())
		if trailing {
			out << `\n`
		}
	}
	n := out.len - body
	digits := strconv.dec_digits(u64(n))
	moved := out.len - at
	unsafe {
		out.grow_len(digits)
		vmemmove(&out[at + digits], &out[at], moved)
		mut view := (&out[at]).vbytes(digits)
		strconv.write_dec(n, mut view) // writes at view[0], i.e. out[at]
	}
}

fn get_users_controller(mut pool ConnectionPool, mut out []u8) {
	mut db := pool.acquire() or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	defer { pool.release(db) }
	rows := db.exec('SELECT * FROM users') or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	append_rows_response(mut out, rows, true)
}

// `users.id` is a `serial` (int4): at most 10 digits, at most max_user_id.
const max_user_id_digits = 10
const max_user_id = u64(2147483647)

// is_user_id reports whether `id` is a plain decimal user id: 1-10 ASCII digits
// that fit in an int4. No sign, no spaces, no SQL comments, no query string —
// get_user_controller answers 400 to everything else.
fn is_user_id(id string) bool {
	if id.len == 0 || id.len > max_user_id_digits {
		return false
	}
	mut n := u64(0)
	for c in id {
		if c < `0` || c > `9` {
			return false
		}
		n = n * 10 + u64(c - `0`)
	}
	return n <= max_user_id
}

// get_user_controller looks up one user. `id` is validated FIRST (400 before
// the pool is touched; it also keeps the stack copy below in bounds), and then
// still BOUND as a query parameter ($1), never spliced into the SQL text: two
// independent defenses against injection.
@[direct_array_access]
fn get_user_controller(id string, mut pool ConnectionPool, mut out []u8) {
	if !is_user_id(id) {
		out << response.tiny_bad_request_response
		return
	}
	// libpq reads parameters as NUL-terminated C strings, and `id` is a view
	// into the request buffer (not NUL-terminated): copy the digits onto the
	// stack. The array is zeroed, so the terminator is already in place.
	mut param := [max_user_id_digits + 1]u8{}
	unsafe { vmemcpy(&param[0], id.str, id.len) }
	mut db := pool.acquire() or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	defer { pool.release(db) }
	result := db.exec_param('SELECT * FROM users WHERE id = $1', unsafe { tos(&param[0], id.len) }) or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	append_rows_response(mut out, result, false)
}

fn create_user_controller(mut pool ConnectionPool, mut out []u8) {
	mut db := pool.acquire() or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	defer { pool.release(db) }
	db.exec("INSERT INTO users (name) VALUES ('new_user')") or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	core.append_str(mut out, http_created_response)
}
