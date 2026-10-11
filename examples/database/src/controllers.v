module main

// Controllers append the response straight into the caller-owned `out`
// (docs/BEST_PRACTICES.md §3): no builder, no return-then-copy, no `.str()`.
// They call libpq synchronously, so a worker thread blocks on every query
// (BEST_PRACTICES §5); examples/async_db_pg is the non-blocking version.
// Every response here says `Connection: keep-alive`: the handler returns
// `.done`, so the server keeps the connection.
import core
import db.pg
import strconv

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const http_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const http_not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const tiny_internal_server_error_response = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// The 200 application/json head, split around its Content-Length digits.
const json_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const json_tail = '\r\nConnection: keep-alive\r\n\r\n'

// A user object, around its two values.
const json_id_key = '{"id":'
const json_name_key = ',"name":'
const json_null = 'null'

fn home_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

// append_users_response appends a 200 application/json response for rows of
// `SELECT id, name FROM users`: all of them as an array (`list`), or the first
// one alone as an object (get_user_controller answers 404 when there is none).
// The body goes straight into `out` and its length is spliced in front of it
// afterwards (one memmove over the tail and body), instead of building the body
// in a strings.Builder first just to measure it.
fn append_users_response(mut out []u8, rows []pg.Row, list bool) {
	core.append_str(mut out, json_head)
	at := out.len // the Content-Length digits go here
	core.append_str(mut out, json_tail)
	body := out.len
	if list {
		out << `[`
		for i, row in rows {
			if i > 0 {
				out << `,`
			}
			append_user(mut out, row)
		}
		out << `]`
	} else {
		append_user(mut out, rows[0])
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

// append_user appends one `id, name` row as a JSON object. The id goes in as
// libpq's text for an int4, its digits, which is already a JSON number; the
// name is escaped; SQL NULL in either column is `null`.
fn append_user(mut out []u8, row pg.Row) {
	core.append_str(mut out, json_id_key)
	if id := row.vals[0] {
		core.append_str(mut out, id)
	} else {
		core.append_str(mut out, json_null)
	}
	core.append_str(mut out, json_name_key)
	if name := row.vals[1] {
		json_escape_into(mut out, name)
	} else {
		core.append_str(mut out, json_null)
	}
	out << `}`
}

// json_escape_into appends s as a quoted JSON string (RFC 8259), as
// examples/async_db_pg does: a name containing `"`, `\` or a control character
// must not break the document.
fn json_escape_into(mut out []u8, s string) {
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

fn get_users_controller(mut pool ConnectionPool, mut out []u8) {
	mut db := pool.acquire() or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	defer { pool.release(db) }
	rows := db.exec('SELECT id, name FROM users ORDER BY id') or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	append_users_response(mut out, rows, true)
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
// independent defenses against injection. An id with no row is a 404.
@[direct_array_access]
fn get_user_controller(id string, mut pool ConnectionPool, mut out []u8) {
	if !is_user_id(id) {
		core.append_str(mut out, http_bad_request_response)
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
	rows := db.exec_param('SELECT id, name FROM users WHERE id = $1', unsafe { tos(&param[0], id.len) }) or {
		core.append_str(mut out, tiny_internal_server_error_response)
		return
	}
	if rows.len == 0 {
		core.append_str(mut out, http_not_found_response)
		return
	}
	append_users_response(mut out, rows, false)
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
