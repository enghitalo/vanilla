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

// handle_server_first parses the server-first message (r= combined nonce, s=
// base64 salt, i= iteration count), runs the SCRAM computation, stashes the
// expected ServerSignature for the final step, and returns the client-final
// message carrying the ClientProof.
pub fn (mut c ScramClient) handle_server_first(server_first []u8) ![]u8 {
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

	// SaltedPassword := Hi(password, salt, i) = PBKDF2-HMAC-SHA256, 32 bytes.
	salt := base64.decode(salt_b64)
	salted_password := pbkdf2.key(c.password.bytes(), salt, iter, sha256.size, sha256.new())!
	// ClientKey := HMAC(SaltedPassword, "Client Key"); StoredKey := H(ClientKey).
	client_key := hmac.new(salted_password, 'Client Key'.bytes(), sha256.sum, sha256.block_size)
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
	server_key := hmac.new(salted_password, 'Server Key'.bytes(), sha256.sum, sha256.block_size)
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
