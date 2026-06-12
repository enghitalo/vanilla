module main

// SOLUTION: pure crypto/round-trip test — works today.
// JWT, API keys and password hashing are pure functions, so their security
// properties (round-trip, tamper detection, wrong-password rejection) are
// directly assertable. This is exactly the layer where unit tests pay off most.

fn test_jwt_roundtrip() {
	token := jwt_sign('{"sub":"user-42","exp":9999999999}')
	assert jwt_verify(token) // a token we signed verifies
}

fn test_jwt_tamper_is_rejected() {
	token := jwt_sign('{"sub":"user-42"}')
	// flip the last two signature chars
	tampered := token[..token.len - 2] + if token.ends_with('AA') { 'BB' } else { 'AA' }
	assert !jwt_verify(tampered)
}

fn test_jwt_garbage_rejected() {
	assert !jwt_verify('not.a.jwt')
	assert !jwt_verify('')
}

fn test_password_hash_verify() {
	salt := [u8(0x11), 0x22, 0x33, 0x44]
	h := hash_password('hunter2', salt)
	assert verify_password('hunter2', salt, h) // correct password
	assert !verify_password('wrong', salt, h) // wrong password
}

fn test_api_key_constant_time_check() {
	assert check_api_key('secret-api-key-123')
	assert !check_api_key('secret-api-key-124')
}

fn test_protected_route_requires_valid_bearer() ! {
	// no token -> 401
	mut out1 := []u8{}
	handle('GET /protected HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, mut out1)!
	assert out1.bytestr().contains('401')
	// valid token -> 200
	token := jwt_sign('{"sub":"user-42","exp":9999999999}')
	req := 'GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${token}\r\n\r\n'.bytes()
	mut out2 := []u8{}
	handle(req, -1, mut out2)!
	assert out2.bytestr().contains('200 OK')
}
