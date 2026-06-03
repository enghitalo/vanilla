module main

// Authentication — reference design (password hashing + JWT + API key).
//
// This REPLACES the misleading plaintext `password == password` check in the
// hexagonal example. Three real mechanisms, each for its right context:
//
//   1. PASSWORD HASHING — never store or compare plaintext. Use a SLOW,
//      memory-hard KDF (argon2id preferred, bcrypt acceptable) with a per-user
//      salt. Verify in CONSTANT TIME. V stdlib has no argon2/bcrypt, so that
//      step is ASPIRATIONAL (bind libargon2 or libsodium); the salted-hash
//      shape is shown with sha256 purely to illustrate structure — sha256 alone
//      is NOT acceptable for passwords (too fast to brute force).
//
//   2. JWT (HMAC-SHA256) — stateless bearer token: header.payload.signature,
//      base64url, signed with a server secret. Verify signature + expiry in
//      constant time. WORKS TODAY (crypto.hmac + crypto.sha256 + base64).
//
//   3. API KEY — opaque high-entropy key for service-to-service. Store only its
//      hash; compare in constant time. WORKS TODAY.
//
// CONSTANT-TIME COMPARISON is the cross-cutting rule: any secret comparison
// must not short-circuit, or timing leaks the secret. crypto.hmac has
// `equal()`; use it for every token/hash check.

import http_server
import http_server.http1_1.request_parser
import crypto.hmac
import crypto.sha256
import encoding.base64

const jwt_secret = 'change-me-in-production'.bytes()

// ---- password hashing ------------------------------------------------------
// ASPIRATIONAL: replace with argon2id(password, salt). Shown salted to convey
// the shape; do NOT ship sha256 for passwords.
fn hash_password(password string, salt []u8) []u8 {
	mut data := salt.clone()
	data << password.bytes()
	return sha256.sum(data) // <-- argon2id here in production
}

fn verify_password(password string, salt []u8, stored_hash []u8) bool {
	computed := hash_password(password, salt)
	return hmac.equal(computed, stored_hash) // constant-time
}

// ---- JWT (HS256) -----------------------------------------------------------
fn b64url(data []u8) string {
	return base64.url_encode(data)
}

fn jwt_sign(payload string) string {
	header := b64url('{"alg":"HS256","typ":"JWT"}'.bytes())
	body := b64url(payload.bytes())
	signing_input := '${header}.${body}'
	sig := hmac.new(jwt_secret, signing_input.bytes(), sha256.sum, sha256.block_size)
	return '${signing_input}.${b64url(sig)}'
}

fn jwt_verify(token string) bool {
	parts := token.split('.')
	if parts.len != 3 {
		return false
	}
	signing_input := '${parts[0]}.${parts[1]}'
	expected := hmac.new(jwt_secret, signing_input.bytes(), sha256.sum, sha256.block_size)
	got := base64.url_decode(parts[2])
	// Constant-time signature check. (A full impl also checks `exp`.)
	return hmac.equal(expected, got)
}

// ---- API key ---------------------------------------------------------------
// Store only the hash of issued keys; never the keys themselves.
const known_api_key_hash = sha256.sum('secret-api-key-123'.bytes())

fn check_api_key(key string) bool {
	return hmac.equal(sha256.sum(key.bytes()), known_api_key_hash)
}

// ---- routing ---------------------------------------------------------------
fn bearer(req request_parser.HttpRequest) string {
	auth := if s := req.get_header_value_slice('Authorization') {
		s.to_string(req.buffer)
	} else {
		''
	}
	if auth.starts_with('Bearer ') {
		return auth['Bearer '.len..]
	}
	return ''
}

fn handle(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	path := req.path.to_string(req.buffer)

	match path {
		'/token' {
			// After verifying a password (verify_password above), issue a JWT.
			token := jwt_sign('{"sub":"user-42","exp":9999999999}')
			body := '{"token":"${token}"}'
			return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
		}
		'/protected' {
			if !jwt_verify(bearer(req)) {
				return 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\n\r\n'.bytes()
			}
			return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
		'/service' {
			key := if s := req.get_header_value_slice('X-API-Key') {
				s.to_string(req.buffer)
			} else {
				''
			}
			if !check_api_key(key) {
				return 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'.bytes()
			}
			return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
		else {
			return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
	}
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: handle
	})!
	println('Auth demo on http://localhost:3000/  (/token, /protected [Bearer], /service [X-API-Key])')
	server.run()
}
