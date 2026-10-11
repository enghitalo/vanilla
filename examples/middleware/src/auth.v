module main

// Per-route auth guards — "Pattern A": explicit, called at the top of each
// controller. Public routes call nothing; private routes call require_auth()
// and answer 401 when it returns none; role-gated routes also compare the
// user's role inline and answer 403. No error values: a denial is routine, and
// `error()` would allocate one per rejected request.
import http1_1.request_parser { HttpRequest }

struct User {
	id   int
	name string
	role string // 'user' | 'admin'
}

// Ready-made denials, appended with core.append_str (§3a).
const unauthorized_response = 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const forbidden_response = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const bearer_prefix = 'Bearer '

// require_auth — gate for "any authenticated user". Returns the User, or none
// (the controller answers 401).
fn require_auth(req HttpRequest) ?User {
	token := bearer_token(req)
	if token == '' {
		return none
	}
	return user_for_token(token)
}

// bearer_token returns the token of `Authorization: Bearer <token>`, or '' if
// there is none. The prefix is compared in place and the token is a `tos` view
// into the request buffer, not a copy: match on it, never store it.
fn bearer_token(req HttpRequest) string {
	s := req.get_header_value_slice('Authorization') or { return '' }
	if s.len <= bearer_prefix.len {
		return ''
	}
	unsafe {
		if tos(&req.buffer[s.start], bearer_prefix.len) != bearer_prefix {
			return ''
		}
		return tos(&req.buffer[s.start + bearer_prefix.len], s.len - bearer_prefix.len)
	}
}

// user_for_token resolves a token to a user. DEMO ONLY — in production validate a
// signed JWT (see examples/auth) instead of a static table. A `match` on a secret
// is not constant-time: compare secrets with `crypto.hmac.equal`.
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
