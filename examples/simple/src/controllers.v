module main

// Controllers append the response straight into the caller-owned `out`
// (docs/BEST_PRACTICES.md §3): no builder, no return-then-copy, no `.str()`.
import strconv
import core

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`. A fixed-size array is zeroed on every
// call (V gotcha), so keep the scratch small: 24 bytes covers any i64.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

fn home_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

fn get_users_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

// get_user_controller echoes the id back as text/plain. `id` is a view into
// the request buffer: read here, never retained.
fn get_user_controller(id string, mut out []u8) {
	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	wi(mut out, id.len)
	core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	core.append_str(mut out, id)
}

fn create_user_controller(mut out []u8) {
	core.append_str(mut out, http_created_response)
}
