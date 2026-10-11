module main

import core
import crypto.hmac
import crypto.sha256
import encoding.base64
import http1_1.response
import os
import time

// SOLUTION: pure crypto/round-trip + raw-request E2E (BEST_PRACTICES §9).
// JWT, API keys and password hashing are pure functions, so their security
// properties (round-trip, tamper detection, expiry, wrong-password rejection)
// are directly assertable. This is exactly the layer where unit tests pay off
// most. Handlers are pure too, so the E2E tests feed raw request bytes
// straight to handle() — no listening socket required.
// (`${}` and `+` below are TEST scaffolding — the example code itself never
// concatenates; see main.v's byte-discipline header.)

fn future_exp() i64 {
	return time.utc().unix() + 3600
}

// mint signs `payload` the way write_token_200 does (append_jwt), with a fresh
// per-worker state: what make_state builds on a worker, minus the argon2 pool.
fn mint(payload string) []u8 {
	mut st := new_auth_state(unsafe { nil })
	mut token := []u8{}
	append_jwt(mut token, mut st, payload.bytes())
	return token
}

fn verify(token []u8) bool {
	mut st := new_auth_state(unsafe { nil })
	return jwt_verify(mut st, token)
}

fn api_key_ok(key []u8) bool {
	mut st := new_auth_state(unsafe { nil })
	return check_api_key(mut st, key)
}

fn test_jwt_roundtrip() {
	token := mint('{"sub":"user-42","exp":${future_exp()}}')
	assert verify(token) // a token we signed verifies
}

// The stack/in-place base64url and the pre-keyed HMAC must mint exactly the
// token the allocating stdlib calls would: same bytes, for every payload
// length mod 3 and for bytes whose base64 is `+`/`/` (base64url `-`/`_`).
fn test_jwt_matches_stdlib_hmac_and_base64url() {
	mut st := new_auth_state(unsafe { nil })
	for n in 0 .. 12 {
		payload := []u8{len: n, init: u8(0xfb + index * 2)}
		mut token := []u8{}
		append_jwt(mut token, mut st, payload)
		signing := jwt_header_b64 + '.' + base64.url_encode(payload)
		sig := hmac.new(jwt_secret, signing.bytes(), sha256.sum, sha256.block_size)
		assert token.bytestr() == signing + '.' + base64.url_encode(sig), 'payload len ${n}'
		assert token.len == jwt_len(n), 'payload len ${n}'
	}
}

fn test_b64url_decode_matches_stdlib() {
	mut buf := []u8{len: 64}
	for n in 0 .. 24 {
		data := []u8{len: n, init: u8(0xfb + index * 3)}
		enc := base64.url_encode(data)
		got := b64url_decode(enc.bytes(), unsafe { &buf[0] })
		assert got == n, 'len ${n}'
		assert buf[..got] == data, 'len ${n}'
		assert buf[..got] == base64.url_decode(enc), 'len ${n}'
	}
	assert b64url_decode('abcde'.bytes(), unsafe { &buf[0] }) == -1 // len % 4 == 1: not base64
}

fn test_jwt_tamper_is_rejected() {
	mut token := mint('{"sub":"user-42","exp":${future_exp()}}')
	// Flip a MIDDLE signature char — every one of its 6 bits is MAC material.
	// (The old version flipped the LAST char between A and B, which differ
	// only in base64url padding bits for a 43-char signature — the decoded
	// MAC was unchanged and the test flaked whenever the char landed on A.)
	i := token.len - 2
	token[i] = if token[i] == `A` { `B` } else { `A` }
	assert !verify(token)
}

const b64url_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

fn test_jwt_noncanonical_signature_rejected() {
	// A 32-byte MAC encodes to 43 base64url chars: the last char carries 4
	// MAC bits + 2 padding bits. XOR-ing its lowest bit changes ONLY padding
	// — the decoded bytes stay identical — yet the canonical verifier must
	// reject it (RFC 8725: one token, one spelling; blocklists and replay
	// caches keyed by token bytes depend on it).
	mut token := mint('{"sub":"user-42","exp":${future_exp()}}')
	last := token[token.len - 1]
	idx := b64url_alphabet.index_u8(last)
	assert idx >= 0, 'signature must end in a base64url char'
	token[token.len - 1] = b64url_alphabet[idx ^ 1]
	assert !verify(token)
}

fn test_jwt_expiry_is_enforced() {
	assert !verify(mint('{"sub":"user-42","exp":1}')) // expired
	assert !verify(mint('{"sub":"user-42"}')) // no exp claim -> rejected
}

// The payload decodes into a fixed per-worker scratch: a validly signed token
// whose payload segment is longer than jwt_payload_b64_max is rejected.
fn test_jwt_oversized_payload_rejected() {
	head := '{"exp":${future_exp()},"pad":"'
	// 384 payload bytes encode to exactly 512 base64url chars: the limit.
	at_limit := head + 'x'.repeat(384 - head.len - 2) + '"}'
	assert at_limit.len == 384
	assert verify(mint(at_limit))
	assert !verify(mint(head + 'x'.repeat(385 - head.len - 2) + '"}'))
}

fn test_jwt_secret_is_never_a_hardcoded_value() {
	assert jwt_secret.len >= jwt_secret_min_len
	if os.getenv('JWT_SECRET').len < jwt_secret_min_len {
		// No real key configured (main() would refuse to start): a fresh random
		// key per process, never a constant anyone could mint tokens with.
		assert load_jwt_secret() != load_jwt_secret()
	}
}

fn test_jwt_garbage_rejected() {
	assert !verify('not.a.jwt'.bytes())
	assert !verify('a.b'.bytes()) // only one dot
	assert !verify('a.b.c.d'.bytes()) // three dots
	assert !verify('..'.bytes()) // empty segments
	assert !verify([]u8{})
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
	assert api_key_ok('secret-api-key-123'.bytes())
	assert !api_key_ok('secret-api-key-124'.bytes())
	assert !api_key_ok([]u8{})
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
	assert verify(token.bytes())
}

fn test_protected_route_requires_valid_bearer() {
	// no token -> 401 with challenge
	no_tok := serve('GET /protected HTTP/1.1\r\nHost: x\r\n\r\n')
	assert no_tok.contains('401')
	assert no_tok.contains('WWW-Authenticate: Bearer')
	// valid token -> 200 (scheme is case-insensitive: `bearer` must work too)
	token := mint('{"sub":"user-42","exp":${future_exp()}}').bytestr()
	ok := serve('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${token}\r\n\r\n')
	assert ok.contains('200 OK')
	ok2 := serve('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: bearer ${token}\r\n\r\n')
	assert ok2.contains('200 OK')
	// expired token -> 401
	old_token := mint('{"exp":1}').bytestr()
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

// ── the point of the design: the per-request routes allocate nothing ──────────

// Every /protected outcome (valid, tampered, expired, no token), every
// /service outcome (valid, wrong, missing key), 404 and 405 run 20k times
// through one reused buffer with a real per-worker state, as a worker serves
// them; the collector's lifetime allocation counter must not move. (Under
// `-gc none`, the epoll production build, any allocation here would be a
// permanent leak.) The login's response writer is held to the same rule; its
// argon2 verify (64 MiB by design) and the .suspend offload stay out.
fn test_hot_path_allocates_nothing() {
	$if gcboehm ? {
		st := make_auth_state()
		token := mint('{"sub":"user-42","exp":${future_exp()}}')
		mut tampered := token.clone()
		i := tampered.len - 2
		tampered[i] = if tampered[i] == `A` { `B` } else { `A` }
		expired := mint('{"sub":"user-42","exp":1}')
		cases := {
			'GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${token.bytestr()}\r\n\r\n':    '200'
			'GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${tampered.bytestr()}\r\n\r\n': '401'
			'GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${expired.bytestr()}\r\n\r\n':  '401'
			'GET /protected HTTP/1.1\r\nHost: x\r\n\r\n':                                                '401'
			'GET /service HTTP/1.1\r\nHost: x\r\nX-API-Key: secret-api-key-123\r\n\r\n':                 '200'
			'GET /service HTTP/1.1\r\nHost: x\r\nX-API-Key: nope\r\n\r\n':                               '401'
			'GET /service HTTP/1.1\r\nHost: x\r\n\r\n':                                                  '401'
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n':                                                     '404'
			'GET /token HTTP/1.1\r\nHost: x\r\n\r\n':                                                    '405'
		}
		reqs := cases.keys().map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up (`out` reaches its high-water mark) + each outcome is the intended one
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, st, mut event_loop)
			assert out.bytestr().starts_with('HTTP/1.1 ${cases[r.bytestr()]}'), r.bytestr()
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, st, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the routes allocated ${grown} bytes over ${rounds * reqs.len} requests'

		// The login response: mint, sign and frame the token straight into `out`.
		mut ast := unsafe { &AuthState(st) }
		unsafe {
			out.len = 0
		}
		write_token_200(mut out, mut ast)
		token_200 := out.bytestr()
		assert verify(token_200.all_after('"token":"').all_before('"').bytes())
		before_login := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			write_token_200(mut out, mut ast)
		}
		grown_login := gc_heap_usage().total_bytes - before_login
		assert grown_login < 4096, 'write_token_200 allocated ${grown_login} bytes over ${rounds} responses'
	}
}
