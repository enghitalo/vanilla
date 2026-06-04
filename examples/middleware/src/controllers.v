module main

// Controllers + the request router. Each controller declares its OWN auth policy
// at the top (Pattern A) — public routes have no guard, private/role-gated ones
// call require_auth / require_role.

import http_server.http1_1.request_parser { HttpRequest }

const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// route decodes the request and dispatches by path. This is the handler passed to
// chain(); the global decorators wrap it.
fn route(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	return match req.path.to_string(req.buffer) {
		'/' { handle_home(req) }
		'/me' { handle_profile(req) }
		'/admin' { handle_admin(req) }
		else { not_found_response }
	}
}

// PUBLIC — no guard.
fn handle_home(_ HttpRequest) []u8 {
	return ok_json('{"page":"home","auth":false}')
}

// PRIVATE — any authenticated user. Guard at the very top.
fn handle_profile(req HttpRequest) []u8 {
	user := require_auth(req) or { return auth_error_response(err) }
	return ok_json('{"id":${user.id},"name":"${user.name}","role":"${user.role}"}')
}

// ROLE-GATED — admins only.
fn handle_admin(req HttpRequest) []u8 {
	user := require_role(req, 'admin') or { return auth_error_response(err) }
	return ok_json('{"admin":"${user.name}","secret":42}')
}

// ok_json builds a 200 with a correct Content-Length.
fn ok_json(body string) []u8 {
	return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
}
