module main

// Controllers append the response straight into the caller-owned `out`
// (docs/BEST_PRACTICES.md §3): no builder, no return-then-copy, no `.str()`.
import strconv
import core
import http1_1.request_parser

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

fn (controller App) home_controller(_ request_parser.HttpRequest, mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

fn (controller App) get_users_controller(_ request_parser.HttpRequest, mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

fn (controller App) get_user_controller(req request_parser.HttpRequest, mut out []u8) {
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	id := unsafe { tos(path.str + 6, path.len - 6) } // path is "/user/{id}"; a view, no copy

	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	wi(mut out, id.len)
	core.append_str(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	core.append_str(mut out, id)
}

fn (controller App) create_user_controller(_ request_parser.HttpRequest, mut out []u8) {
	core.append_str(mut out, http_created_response)
}
