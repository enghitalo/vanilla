module main

// Controllers + the request router. Each controller declares its OWN auth policy
// at the top (Pattern A) — public routes have no guard, private/role-gated ones
// call require_auth / require_role.
//
// Responses follow BEST_PRACTICES §3: no `${}` interpolation on the hot path. A
// fixed response is a precomputed `const ... .bytes()` (§3a); a dynamic one is
// built with a pre-sized strings.Builder, writing integers via write_decimal so
// there is no `.str()` / concat allocation (§3b).
import strings
import core
import http1.request_parser { HttpRequest }
import http1.response

const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// The public home response never changes — precompute it once (§3a).
// Content-Length 28 = len('{"page":"home","auth":false}').
const home_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\nConnection: keep-alive\r\n\r\n{"page":"home","auth":false}'.bytes()

// route decodes the request and dispatches by path. This is the handler passed to
// chain(); the global decorators wrap it.
fn route(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	out << match req.path.to_string(req.buffer) {
		'/' { handle_home(req) }
		'/me' { handle_profile(req) }
		'/admin' { handle_admin(req) }
		else { not_found_response }
	}

	return .done
}

// PUBLIC — no guard, static response.
fn handle_home(_ HttpRequest) []u8 {
	return home_response
}

// PRIVATE — any authenticated user. Guard at the very top.
fn handle_profile(req HttpRequest) []u8 {
	user := require_auth(req) or { return auth_error_response(err) }
	mut body := strings.new_builder(48)
	body.write_string('{"id":')
	body.write_decimal(user.id)
	body.write_string(',"name":"')
	body.write_string(user.name)
	body.write_string('","role":"')
	body.write_string(user.role)
	body.write_string('"}')
	return json_ok(body)
}

// ROLE-GATED — admins only.
fn handle_admin(req HttpRequest) []u8 {
	user := require_role(req, 'admin') or { return auth_error_response(err) }
	mut body := strings.new_builder(32)
	body.write_string('{"admin":"')
	body.write_string(user.name)
	body.write_string('","secret":42}')
	return json_ok(body)
}

// json_ok wraps a JSON body in a 200 with an accurate Content-Length, built with
// a pre-sized builder + write_decimal — no `${}`, no int.str() (§3b).
// Note: `user.name` / `user.role` here come from the trusted session table; a
// value derived from request input would need JSON escaping first (§8) — see the
// `json_str` helper in examples/veb_like.
fn json_ok(body []u8) []u8 {
	mut sb := strings.new_builder(80 + body.len)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
	sb.write_decimal(body.len)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write(body) or {}
	return sb
}
