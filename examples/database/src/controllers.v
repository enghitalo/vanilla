module main

import strings
import http1_1.response

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

const tiny_internal_server_error_response = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

fn home_controller(params []string) ![]u8 {
	return http_ok_response
}

fn get_users_controller(params []string, mut pool ConnectionPool) ![]u8 {
	mut db := pool.acquire() or { return tiny_internal_server_error_response }
	defer { pool.release(db) }
	rows := db.exec('SELECT * FROM users') or { return tiny_internal_server_error_response }

	mut response_body := strings.new_builder(200)
	for row in rows {
		response_body.write_string(row.str())
		response_body.write_string('\n')
	}

	// response_body_str := response_body.str()
	defer {
		unsafe {
			response_body.free()
			params.free()
		}
	}

	mut sb := strings.new_builder(200)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	sb.write_string(response_body.len.str())
	sb.write_string('\r\nConnection: close\r\n\r\n')
	sb.write(response_body)!

	return sb
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
@[direct_array_access; manualfree]
fn get_user_controller(id string, mut pool ConnectionPool) ![]u8 {
	if !is_user_id(id) {
		return response.tiny_bad_request_response
	}
	// libpq reads parameters as NUL-terminated C strings, and `id` is a view
	// into the request buffer (not NUL-terminated): copy the digits onto the
	// stack. The array is zeroed, so the terminator is already in place.
	mut param := [max_user_id_digits + 1]u8{}
	unsafe { vmemcpy(&param[0], id.str, id.len) }
	mut db := pool.acquire() or { return tiny_internal_server_error_response }
	defer { pool.release(db) }
	result := db.exec_param('SELECT * FROM users WHERE id = $1', unsafe { tos(&param[0], id.len) }) or {
		return tiny_internal_server_error_response
	}
	response_body := result.map(it.str()).join('\n')

	mut sb := strings.new_builder(200)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	sb.write_string(response_body.len.str())
	sb.write_string('\r\nConnection: close\r\n\r\n')
	sb.write_string(response_body)

	defer {
		unsafe { response_body.free() } // never `id`: it borrows the request buffer
	}
	return sb
}

fn create_user_controller(params []string, mut pool ConnectionPool) ![]u8 {
	dump('create_user_controller')
	mut db := pool.acquire() or { return tiny_internal_server_error_response }
	defer { pool.release(db) }
	db.exec("INSERT INTO users (name) VALUES ('new_user')") or {
		return tiny_internal_server_error_response
	}
	return http_created_response
}
