module main

// Controllers + the request router. Each controller declares its OWN auth policy
// at the top (Pattern A) — public routes have no guard, private ones call
// require_auth, role-gated ones also check the role inline.
//
// Responses follow BEST_PRACTICES §3: controllers append straight into the
// caller's `out` — no `${}`, no strings.Builder, no return-then-copy. A fixed
// response is a `const` string appended with core.append_str (§3a); a dynamic
// one sums its body length first, then appends the head, the Content-Length
// digits (`wi`) and the body parts (§3b).
import strconv
import core
import http1_1.request_parser { HttpRequest }
import http1_1.response

const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// The public home response never changes — precompute it once (§3a).
// Content-Length 28 = len('{"page":"home","auth":false}').
const home_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\nConnection: keep-alive\r\n\r\n{"page":"home","auth":false}'

const json_ok_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const json_ok_tail = '\r\nConnection: keep-alive\r\n\r\n'

// The literal parts of the dynamic bodies:
//   GET /me     {"id":<id>,"name":"<name>","role":"<role>"}
//   GET /admin  {"admin":"<name>","secret":42}
const profile_id = '{"id":'
const profile_name = ',"name":"'
const profile_role = '","role":"'
const profile_end = '"}'
const admin_name = '{"admin":"'
const admin_end = '","secret":42}'

// route decodes the request and dispatches by path. This is the handler passed to
// chain(); the global decorators wrap it.
fn route(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	// The path is a `tos` view into the handler's own req_buffer: matched here,
	// never stored, never copied.
	match unsafe { tos(&req_buffer[req.path.start], req.path.len) } {
		'/' { handle_home(mut out) }
		'/me' { handle_profile(req, mut out) }
		'/admin' { handle_admin(req, mut out) }
		else { core.append_str(mut out, not_found_response) }
	}
	return .done
}

// PUBLIC — no guard, static response.
fn handle_home(mut out []u8) {
	core.append_str(mut out, home_response)
}

// PRIVATE — any authenticated user. Guard at the very top.
fn handle_profile(req HttpRequest, mut out []u8) {
	user := require_auth(req) or {
		core.append_str(mut out, unauthorized_response)
		return
	}
	body_len := profile_id.len + strconv.dec_digits(u64(user.id)) + profile_name.len +
		user.name.len + profile_role.len + user.role.len + profile_end.len
	append_json_ok_head(mut out, body_len)
	core.append_str(mut out, profile_id)
	wi(mut out, user.id)
	core.append_str(mut out, profile_name)
	core.append_str(mut out, user.name)
	core.append_str(mut out, profile_role)
	core.append_str(mut out, user.role)
	core.append_str(mut out, profile_end)
}

// ROLE-GATED — admins only: 401 without a valid token, 403 for any other role.
fn handle_admin(req HttpRequest, mut out []u8) {
	user := require_auth(req) or {
		core.append_str(mut out, unauthorized_response)
		return
	}
	if user.role != 'admin' {
		core.append_str(mut out, forbidden_response)
		return
	}
	append_json_ok_head(mut out, admin_name.len + user.name.len + admin_end.len)
	core.append_str(mut out, admin_name)
	core.append_str(mut out, user.name)
	core.append_str(mut out, admin_end)
}

// append_json_ok_head appends the status line and headers of a 200 JSON
// response whose body is `body_len` bytes; the caller appends the body next.
// Note: `user.name` / `user.role` in the bodies come from the trusted session
// table; a value derived from request input would need JSON escaping first
// (§8) — see `json_string` in examples/veb_like/src/responses.v.
fn append_json_ok_head(mut out []u8, body_len int) {
	core.append_str(mut out, json_ok_head)
	wi(mut out, body_len)
	core.append_str(mut out, json_ok_tail)
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
