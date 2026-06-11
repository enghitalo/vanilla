module main

// Per-route auth guards — "Pattern A": explicit, called at the top of each
// controller. Public routes call nothing; private routes call require_auth();
// role-gated routes call require_role(). A guard returns the User, or an error
// carrying the HTTP status the controller should send.
import http_server.http1_1.request_parser { HttpRequest }

struct User {
	id   int
	name string
	role string // 'user' | 'admin'
}

// Ready-made denials, built once.
const unauthorized_response = 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const forbidden_response = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// require_auth — gate for "any authenticated user". Returns the User, or a 401.
fn require_auth(req HttpRequest) !User {
	token := bearer_token(req)
	if token == '' {
		return error_with_code('missing bearer token', 401)
	}
	return user_for_token(token) or { return error_with_code('invalid token', 401) }
}

// require_role — gate for a specific role. 401 if unauthenticated, 403 if the
// authenticated user lacks the role.
fn require_role(req HttpRequest, role string) !User {
	user := require_auth(req)!
	if user.role != role {
		return error_with_code('requires role ${role}', 403)
	}
	return user
}

// auth_error_response maps a guard error to its ready-made response (403 vs 401).
fn auth_error_response(err IError) []u8 {
	return if err.code() == 403 { forbidden_response } else { unauthorized_response }
}

// bearer_token extracts the token from `Authorization: Bearer <token>` — a
// zero-copy slice lookup, materialized to a string only for the matched header.
fn bearer_token(req HttpRequest) string {
	slice := req.get_header_value_slice('Authorization') or { return '' }
	value := slice.to_string(req.buffer)
	if value.starts_with('Bearer ') {
		return value['Bearer '.len..]
	}
	return ''
}

// user_for_token resolves a token to a user. DEMO ONLY — in production validate a
// signed JWT (see examples/auth) instead of a static table.
fn user_for_token(token string) ?User {
	return match token {
		'tok-alice' {
			User{
				id:   1
				name: 'alice'
				role: 'user'
			}
		}
		'tok-root' {
			User{
				id:   2
				name: 'root'
				role: 'admin'
			}
		}
		else {
			none
		}
	}
}
