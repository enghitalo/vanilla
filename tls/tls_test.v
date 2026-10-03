module tls

import os
import encoding.base64

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

// A session is created from a config whose kTLS settings were changed, and
// set_ktls(false) makes its enable_ktls take the clean opt-out (no handshake
// needed). That runs every atomic in the C shim, so `v test tls/` builds and
// runs the session path with each compiler. tcc, V's default, miscompiled an
// __atomic_load in vtls_session_new: every HTTPS server it built crashed on
// its first connection, and only the e2e tests reached that code. The
// session never touches its fd here.
fn test_new_session_after_ktls_settings() {
	$if vanilla_tls ? {
		initialize() or { panic('initialize: ${err}') }
		cfg := new_self_signed() or { panic('gen: ${err}') }
		cfg.set_ktls_rx_no_pad(true)
		cfg.set_ktls(false)
		mut p := os.pipe() or { panic('pipe: ${err}') }
		s := cfg.new_session(p.read_fd) or { panic('new_session failed') }
		assert !s.enable_ktls(p.read_fd), 'set_ktls(false) must keep the session on userspace TLS'
		assert !s.ktls_failed() && !s.ktls_active()
		s.free()
		p.close()
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

// der_len reads the DER length at b[i] (short or long form) and returns
// (length, index of the first content byte).
fn der_len(b []u8, i int) (int, int) {
	if b[i] < 0x80 {
		return int(b[i]), i + 1
	}
	n := int(b[i] & 0x7f)
	mut l := 0
	for k in 0 .. n {
		l = (l << 8) | int(b[i + 1 + k])
	}
	return l, i + 1 + n
}

// The certificate serial is a DER INTEGER: it must be minimally encoded and
// positive, or OpenSSL 3 clients refuse the certificate ("illegal padding").
// A random 12-byte serial written as is breaks that 1 time in 512; 2048 fresh
// certificates (~2 s) catch such a regression ~98% of the time.
fn test_self_signed_serial_is_minimal_positive_der() {
	$if vanilla_tls ? {
		for _ in 0 .. 2048 {
			cfg := new_self_signed() or { panic('gen: ${err}') }
			pem := cfg.cert_pem()
			cfg.free()
			body := pem.all_after('-----BEGIN CERTIFICATE-----').all_before('-----END CERTIFICATE-----').replace('\n',
				'')
			der := base64.decode(body)
			// Certificate SEQUENCE -> tbsCertificate SEQUENCE -> [0] version -> serial.
			assert der[0] == 0x30
			_, tbs := der_len(der, 1)
			assert der[tbs] == 0x30
			_, inner := der_len(der, tbs + 1)
			assert der[inner] == 0xa0 // explicit version tag
			vlen, vstart := der_len(der, inner + 1)
			si := vstart + vlen
			assert der[si] == 0x02, 'serial must be an INTEGER'
			slen, sstart := der_len(der, si + 1)
			assert slen >= 1
			assert der[sstart] & 0x80 == 0, 'serial must be positive'
			if slen > 1 {
				assert !(der[sstart] == 0 && der[sstart + 1] & 0x80 == 0), 'serial must be minimally encoded'
			}
		}
	}
}

// Each leg of the TLS CI lane (.github/workflows/tls_backend.yml) builds Mbed
// TLS one way and says which: the threading leg must really link a build with
// MBEDTLS_THREADING_C (no crypto lock in the shim), the default leg one
// without it (every call takes the lock), or the e2e tests after this would
// exercise the other path than the leg claims. No-op without the define.
fn test_parallel_crypto_matches_the_linked_build() {
	$if vanilla_tls ? {
		$if vanilla_expect_parallel_crypto ? {
			assert parallel_crypto(), 'this leg builds Mbed TLS with MBEDTLS_THREADING_C, but the shim was compiled without it'
		} $else $if vanilla_expect_serialized_crypto ? {
			assert !parallel_crypto(), 'this leg builds the default Mbed TLS config, without MBEDTLS_THREADING_C, but the shim was compiled with it'
		}
	}
}
