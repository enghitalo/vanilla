module main

// Controllers append response bytes STRAIGHT INTO the caller-owned `out`
// buffer (docs/BEST_PRACTICES.md §3b) — no per-request strings.Builder, no
// return-then-copy, no `.str()`, no manual frees. Static responses are consts
// appended with `out <<`; the one dynamic response (`/user/<id>`) is framed
// with the zero-alloc helpers `ws` (push_many) and `wi` (strconv.write_dec
// into a stack scratch).
import strconv

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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
	out << http_ok_response
}

fn get_users_controller(mut out []u8) {
	out << http_ok_response
}

// get_user_controller echoes the id back as text/plain. `id` is a zero-copy
// view into the request buffer (never empty — the router guarantees at least
// one id byte); it is read here and never retained.
fn get_user_controller(id []u8, mut out []u8) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	wi(mut out, id.len)
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	out << id
}

fn create_user_controller(mut out []u8) {
	out << http_created_response
}
