module main

import core
import http1_1.response
import time

// SOLUTION: pure crypto/round-trip + raw-request E2E (BEST_PRACTICES §9).
// JWT, API keys and password hashing are pure functions, so their security
// properties (round-trip, tamper detection, expiry, wrong-password rejection)
// are directly assertable. This is exactly the layer where unit tests pay off
// most. Handlers are pure too, so the E2E tests feed raw request bytes
// straight to handle() — no listening socket required.
// (`${}` below is TEST scaffolding — the example code itself never
// concatenates; see main.v's byte-discipline header.)

fn future_exp() i64 {
	return time.utc().unix() + 3600
}

fn test_jwt_roundtrip() {
	token := jwt_sign('{"sub":"user-42","exp":${future_exp()}}'.bytes())
	assert jwt_verify(token) // a token we signed verifies
}

fn test_jwt_tamper_is_rejected() {
	mut token := jwt_sign('{"sub":"user-42","exp":${future_exp()}}'.bytes())
	// Flip a MIDDLE signature char — every one of its 6 bits is MAC material.
	// (The old version flipped the LAST char between A and B, which differ
	// only in base64url padding bits for a 43-char signature — the decoded
	// MAC was unchanged and the test flaked whenever the char landed on A.)
	i := token.len - 2
	token[i] = if token[i] == `A` { `B` } else { `A` }
	assert !jwt_verify(token)
}

const b64url_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

fn test_jwt_noncanonical_signature_rejected() {
	// A 32-byte MAC encodes to 43 base64url chars: the last char carries 4
	// MAC bits + 2 padding bits. XOR-ing its lowest bit changes ONLY padding
	// — the decoded bytes stay identical — yet the canonical verifier must
	// reject it (RFC 8725: one token, one spelling; blocklists and replay
	// caches keyed by token bytes depend on it).
	mut token := jwt_sign('{"sub":"user-42","exp":${future_exp()}}'.bytes())
	last := token[token.len - 1]
	idx := b64url_alphabet.index_u8(last)
	assert idx >= 0, 'signature must end in a base64url char'
	token[token.len - 1] = b64url_alphabet[idx ^ 1]
	assert !jwt_verify(token)
}

fn test_jwt_expiry_is_enforced() {
	assert !jwt_verify(jwt_sign('{"sub":"user-42","exp":1}'.bytes())) // expired
	assert !jwt_verify(jwt_sign('{"sub":"user-42"}'.bytes())) // no exp claim -> rejected
}

fn test_jwt_garbage_rejected() {
	assert !jwt_verify('not.a.jwt'.bytes())
	assert !jwt_verify('a.b'.bytes()) // only one dot
	assert !jwt_verify('a.b.c.d'.bytes()) // three dots
	assert !jwt_verify('..'.bytes()) // empty segments
	assert !jwt_verify([]u8{})
}

fn test_password_hash_verify() {
	// The demo PHC hash is generated at init with a random salt; verification
	// re-derives with the embedded salt+params and compares in constant time.
	assert verify_password(demo_password.bytes(), demo_password_phc)
	assert !verify_password('wrong-password'.bytes(), demo_password_phc)
	assert !verify_password([]u8{}, demo_password_phc)
	assert !verify_password('x'.bytes(), 'not-a-phc-string') // malformed hash -> false, not panic
}

fn test_api_key_constant_time_check() {
	assert check_api_key('secret-api-key-123'.bytes())
	assert !check_api_key('secret-api-key-124'.bytes())
	assert !check_api_key([]u8{})
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect.
fn serve(req string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	return out.bytestr()
}

fn test_token_login_flow() {
	// wrong password -> 401
	bad := serve('POST /token HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nwrong')
	assert bad.contains('401')
	// wrong method -> 405 with Allow
	notpost := serve('GET /token HTTP/1.1\r\nHost: x\r\n\r\n')
	assert notpost.contains('405')
	assert notpost.contains('Allow: POST')
	// correct password -> 200, correct Content-Length, token that verifies
	body := demo_password
	ok := serve('POST /token HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.len}\r\n\r\n${body}')
	assert ok.contains('200 OK')
	json_body := ok.all_after('\r\n\r\n')
	clen := ok.all_after('Content-Length: ').all_before('\r\n').int()
	assert clen == json_body.len
	token := json_body.all_after('"token":"').all_before('"')
	assert jwt_verify(token.bytes())
}

fn test_protected_route_requires_valid_bearer() {
	// no token -> 401 with challenge
	no_tok := serve('GET /protected HTTP/1.1\r\nHost: x\r\n\r\n')
	assert no_tok.contains('401')
	assert no_tok.contains('WWW-Authenticate: Bearer')
	// valid token -> 200 (scheme is case-insensitive: `bearer` must work too)
	token := jwt_sign('{"sub":"user-42","exp":${future_exp()}}'.bytes()).bytestr()
	ok := serve('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${token}\r\n\r\n')
	assert ok.contains('200 OK')
	ok2 := serve('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: bearer ${token}\r\n\r\n')
	assert ok2.contains('200 OK')
	// expired token -> 401
	old_token := jwt_sign('{"exp":1}'.bytes()).bytestr()
	old := serve('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${old_token}\r\n\r\n')
	assert old.contains('401')
}

fn test_service_route_requires_api_key() {
	assert serve('GET /service HTTP/1.1\r\nHost: x\r\n\r\n').contains('401')
	assert serve('GET /service HTTP/1.1\r\nHost: x\r\nX-API-Key: nope\r\n\r\n').contains('401')
	assert serve('GET /service HTTP/1.1\r\nHost: x\r\nX-API-Key: secret-api-key-123\r\n\r\n').contains('200 OK')
}

fn test_unknown_route_and_malformed() {
	assert serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n').contains('404')
	// Malformed input gets the canned 400 and the connection is closed.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
}
