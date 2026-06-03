module tls

fn test_self_signed_generation() {
	init() or { panic('init: ${err}') }
	cfg := new_self_signed() or { panic('gen: ${err}') }
	pem := cfg.cert_pem()
	assert pem.starts_with('-----BEGIN CERTIFICATE-----')
	assert pem.contains('-----END CERTIFICATE-----')
	assert pem.len > 200
	cfg.free()
}
