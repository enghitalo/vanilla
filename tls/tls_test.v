module tls

import os

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

// The default certificate must be usable by real clients: SANs for localhost
// and both loopback IPs, and an exportable key so the pair can be kept.
fn test_self_signed_default_has_key_and_cert() {
	$if vanilla_tls ? {
		cfg := new_self_signed() or { panic('gen: ${err}') }
		assert cfg.cert_pem().starts_with('-----BEGIN CERTIFICATE-----')
		key := cfg.key_pem()
		assert key.starts_with('-----BEGIN')
		assert key.contains('PRIVATE KEY-----')
		cfg.free()
	}
}

// Custom SANs (an IP, a hostname) generate fine, and the exported pair
// reloads through new_from_pem - the exact path persist_dir relies on.
fn test_self_signed_custom_sans_roundtrip() {
	$if vanilla_tls ? {
		cfg := new_self_signed(sans: ['IP:203.0.113.5', 'DNS:api.example.test', 'IP:2001:db8::1']) or {
			panic('gen: ${err}')
		}
		reloaded := new_from_pem(cfg.cert_pem().bytes(), cfg.key_pem().bytes()) or {
			panic('reload: ${err}')
		}
		assert reloaded.cert_pem() == cfg.cert_pem()
		reloaded.free()
		cfg.free()
	}
}

fn test_self_signed_rejects_bad_sans() {
	$if vanilla_tls ? {
		if _ := new_self_signed(sans: ['api.example.test']) {
			assert false, 'a SAN without a DNS:/IP: prefix must be rejected'
		}
		if _ := new_self_signed(sans: ['IP:not-an-address']) {
			assert false, 'an unparsable IP must be rejected'
		}
		if _ := new_self_signed(sans: []) {
			assert false, 'an empty SAN list must be rejected'
		}
	}
}

// persist_dir: the first call writes cert.pem + key.pem (key 0600), the
// second call loads them and yields the SAME certificate instead of a new one.
fn test_self_signed_persist_dir_keeps_identity() {
	$if vanilla_tls ? {
		dir := os.join_path(os.temp_dir(), 'vanilla_tls_persist_${os.getpid()}')
		os.rmdir_all(dir) or {}
		defer {
			os.rmdir_all(dir) or {}
		}
		first := new_self_signed(persist_dir: dir) or { panic('first: ${err}') }
		assert os.exists(os.join_path(dir, 'cert.pem'))
		assert os.exists(os.join_path(dir, 'key.pem'))
		assert os.inode(os.join_path(dir, 'key.pem')).bitmask() & 0o077 == 0, 'key.pem must not be group/world readable'
		second := new_self_signed(persist_dir: dir) or { panic('second: ${err}') }
		assert second.cert_pem() == first.cert_pem()
		// Without persistence every call is a different identity.
		fresh := new_self_signed() or { panic('fresh: ${err}') }
		assert fresh.cert_pem() != first.cert_pem()
		fresh.free()
		second.free()
		first.free()
	}
}
