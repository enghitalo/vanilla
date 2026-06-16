module pg_async

// Test vectors from RFC 7677 §3 (SCRAM-SHA-256 example): user "user",
// password "pencil", fixed client nonce. Raw strings (r'...') keep V from
// interpolating the `$` in the server nonce.
fn test_scram_sha256_rfc7677_vector() {
	mut c := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')

	client_first := c.client_first().bytestr()
	assert client_first == 'n,,n=user,r=rOprNGfwEbeRWgbNEkqO'

	server_first := r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'
	client_final := c.handle_server_first(server_first.bytes())!.bytestr()
	assert client_final == r'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ='

	// Correct ServerSignature is accepted.
	c.handle_server_final('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='.bytes())!
	assert c.is_done()
}

fn test_scram_rejects_wrong_server_signature() {
	mut c := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
	c.client_first()
	server_first := r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'
	c.handle_server_first(server_first.bytes())!
	// A tampered v= must be rejected and must not mark the client done.
	if _ := c.handle_server_final('v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='.bytes()) {
		assert false, 'tampered server signature must be rejected'
	}
	assert !c.is_done()
}

fn test_scram_rejects_bad_nonce() {
	mut c := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
	c.client_first()
	// server nonce that does not start with the client nonce → reject
	if _ := c.handle_server_first('r=DIFFERENT,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'.bytes()) {
		assert false, 'mismatched nonce must be rejected'
	}
}

fn test_scram_escape() {
	assert scram_escape('plain') == 'plain'
	assert scram_escape('a,b') == 'a=2Cb'
	assert scram_escape('a=b') == 'a=3Db'
	// '=' is escaped before ',' so the '=' in =2C is not double-encoded
	assert scram_escape('a=,') == 'a=3D=2C'
}

fn test_scram_new_generates_random_nonce() {
	mut c := ScramClient.new('app', 'secret')!
	cf := c.client_first().bytestr()
	assert cf.starts_with('n,,n=app,r=')
	assert cf.len > 'n,,n=app,r='.len // a non-empty nonce was appended
}
