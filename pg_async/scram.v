module pg_async

import crypto.sha256
import crypto.hmac
import crypto.pbkdf2
import crypto.rand
import encoding.base64

// SCRAM-SHA-256 (RFC 5802 / RFC 7677) client-side authentication for the
// PostgreSQL SASL handshake. Channel binding is not used — the gs2 header is
// "n,," — which is what PostgreSQL's `scram-sha-256` (non-`-plus`) method
// expects. All primitives come from V's stdlib (crypto.{sha256,hmac,pbkdf2},
// encoding.base64), so there is no external crypto dependency.

pub const scram_sha_256 = 'SCRAM-SHA-256'

const gs2_header = 'n,,' // no channel binding, no authorization identity

// ScramClient drives the three client steps in order:
//   client_first()          → the SASLInitialResponse payload
//   handle_server_first(..)  → consumes server-first, returns client-final
//   handle_server_final(..)  → verifies the server proved it knows the password
pub struct ScramClient {
	username string
	password string
mut:
	client_nonce      string
	client_first_bare string
	server_signature  []u8 // computed in handle_server_first, checked in handle_server_final
	done              bool
}

// ScramClient.new builds a client with a fresh random nonce (base64 of 18
// random bytes — printable and comma-free, as the nonce grammar requires).
pub fn ScramClient.new(username string, password string) !ScramClient {
	nonce := rand.bytes(18)!
	return ScramClient{
		username:     username
		password:     password
		client_nonce: base64.encode(nonce)
	}
}

// ScramClient.with_nonce builds a client with a caller-supplied nonce, for
// deterministic tests (RFC vectors). Production code uses new().
fn ScramClient.with_nonce(username string, password string, client_nonce string) ScramClient {
	return ScramClient{
		username:     username
		password:     password
		client_nonce: client_nonce
	}
}

// client_first returns the SASL client-first message: gs2-header followed by
// "n=<escaped-username>,r=<client-nonce>".
pub fn (mut c ScramClient) client_first() []u8 {
	c.client_first_bare = 'n=${scram_escape(c.username)},r=${c.client_nonce}'
	return '${gs2_header}${c.client_first_bare}'.bytes()
}

// ScramCache keeps the PBKDF2 result for one (salt, iteration count): a role's
// SCRAM verifier on the server does not change between connections, so a
// pool computes Hi(password, salt, i) — 4096 iterations of HMAC-SHA-256, ~14
// ms of CPU here, most of a connect's cost — once, and every other connection
// and every re-dial reuses it. It holds password-equivalent material, like the
// pool's ConnConfig: per pool, never logged.
struct ScramCache {
mut:
	salt       []u8
	iterations int
	client_key []u8
	server_key []u8
	computed   int // PBKDF2 runs (tests check the reuse)
}

// keys returns ClientKey and ServerKey for (password, salt, iterations),
// computing them only when the cache holds another salt or count.
fn (mut cache ScramCache) keys(password string, salt []u8, iterations int) !([]u8, []u8) {
	if cache.client_key.len == 0 || cache.iterations != iterations || cache.salt != salt {
		// SaltedPassword := Hi(password, salt, i) = PBKDF2-HMAC-SHA256, 32 bytes.
		mut pw := password.bytes()
		mut salted_password := pbkdf2.key(pw, salt, iterations, sha256.size, sha256.new()) or {
			wipe(mut pw)
			return err
		}
		cache.client_key = hmac.new(salted_password, 'Client Key'.bytes(), sha256.sum, sha256.block_size)
		cache.server_key = hmac.new(salted_password, 'Server Key'.bytes(), sha256.sum, sha256.block_size)
		cache.salt = salt.clone()
		cache.iterations = iterations
		cache.computed++
		// Password-equivalent temporaries: don't leave them in freed memory.
		wipe(mut pw)
		wipe(mut salted_password)
	}
	return cache.client_key, cache.server_key
}

// wipe zeroes a buffer that held secret material.
fn wipe(mut b []u8) {
	if b.len > 0 {
		unsafe { vmemset(b.data, 0, b.len) }
	}
}

// handle_server_first parses the server-first message (r= combined nonce, s=
// base64 salt, i= iteration count), runs the SCRAM computation, stashes the
// expected ServerSignature for the final step, and returns the client-final
// message carrying the ClientProof.
pub fn (mut c ScramClient) handle_server_first(server_first []u8) ![]u8 {
	mut cache := ScramCache{}
	return c.reply_to_server_first(server_first, c.password, mut cache)
}

// reply_to_server_first is handle_server_first with the password passed in
// (the dialer keeps it in the pool's config, never on a connection) and the
// PBKDF2 result taken from `cache` when it matches.
fn (mut c ScramClient) reply_to_server_first(server_first []u8, password string, mut cache ScramCache) ![]u8 {
	sf := server_first.bytestr()
	mut combined_nonce := ''
	mut salt_b64 := ''
	mut iter := 0
	for attr in sf.split(',') {
		if attr.len < 2 || attr[1] != `=` {
			continue
		}
		val := attr[2..]
		match attr[0] {
			`r` { combined_nonce = val }
			`s` { salt_b64 = val }
			`i` { iter = val.int() }
			`e` { return error('scram: server error in server-first: ${val}') }
			else {}
		}
	}
	if combined_nonce == '' || !combined_nonce.starts_with(c.client_nonce) {
		return error('scram: server nonce does not extend the client nonce')
	}
	if salt_b64 == '' || iter <= 0 {
		return error('scram: malformed server-first message')
	}

	salt := base64.decode(salt_b64)
	// ClientKey := HMAC(SaltedPassword, "Client Key"); ServerKey likewise.
	client_key, server_key := cache.keys(password, salt, iter)!
	// StoredKey := H(ClientKey).
	stored_key := sha256.sum(client_key)

	// client-final-message-without-proof, then the full AuthMessage.
	channel_binding := 'c=' + base64.encode(gs2_header.bytes()) // "c=biws"
	client_final_bare := '${channel_binding},r=${combined_nonce}'
	auth_message := '${c.client_first_bare},${sf},${client_final_bare}'

	// ClientSignature := HMAC(StoredKey, AuthMessage); ClientProof := ClientKey XOR ClientSignature.
	client_signature := hmac.new(stored_key, auth_message.bytes(), sha256.sum, sha256.block_size)
	mut client_proof := []u8{len: client_key.len}
	for i in 0 .. client_key.len {
		client_proof[i] = client_key[i] ^ client_signature[i]
	}

	// ServerSignature := HMAC(ServerKey, AuthMessage), verified in the final step.
	c.server_signature = hmac.new(server_key, auth_message.bytes(), sha256.sum, sha256.block_size)

	return '${client_final_bare},p=${base64.encode(client_proof)}'.bytes()
}

// handle_server_final verifies the server's ServerSignature (the v= field)
// matches the one computed during handle_server_first — proving the server
// also knows the password — and marks the handshake complete.
pub fn (mut c ScramClient) handle_server_final(server_final []u8) ! {
	sf := server_final.bytestr()
	mut v_b64 := ''
	for attr in sf.split(',') {
		if attr.len < 2 || attr[1] != `=` {
			continue
		}
		match attr[0] {
			`v` { v_b64 = attr[2..] }
			`e` { return error('scram: server rejected authentication: ${attr[2..]}') }
			else {}
		}
	}
	if v_b64 == '' {
		return error('scram: missing server signature in server-final')
	}
	if base64.encode(c.server_signature) != v_b64 {
		return error('scram: server signature mismatch')
	}
	c.done = true
}

// is_done reports whether the server has been verified.
pub fn (c &ScramClient) is_done() bool {
	return c.done
}

// scram_escape encodes a username for the SASL `n=` field: '=' → "=3D" and
// ',' → "=2C". '=' must be escaped first, or the '=' introduced by the comma
// escaping would be double-encoded.
fn scram_escape(s string) string {
	return s.replace('=', '=3D').replace(',', '=2C')
}
