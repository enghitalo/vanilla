module tls

// These exercise the real Mbed TLS-backed implementation, so they only do
// anything under `-d vanilla_tls`. In the default (stub) build they compile and
// pass trivially, keeping `v test` green without an Mbed TLS dependency.

fn test_self_signed_generation() {
	$if vanilla_tls ? {
		initialize() or { panic('initialize: ${err}') }
		cfg := new_self_signed() or { panic('gen: ${err}') }
		pem := cfg.cert_pem()
		assert pem.starts_with('-----BEGIN CERTIFICATE-----')
		assert pem.contains('-----END CERTIFICATE-----')
		assert pem.len > 200
		cfg.free()
	}
}

// ALPN is configurable (default http/1.1) and overridable. Negotiation itself
// happens during the handshake; this just exercises the config path doesn't err.
fn test_alpn_config() {
	$if vanilla_tls ? {
		initialize() or { panic('initialize: ${err}') }
		cfg := new_self_signed() or { panic('gen: ${err}') }
		// Default is applied by the constructor; an explicit override must also work.
		cfg.set_alpn('h2,http/1.1') or { panic('set_alpn list: ${err}') }
		cfg.set_alpn('http/1.1') or { panic('set_alpn single: ${err}') }
		cfg.free()
	}
}
