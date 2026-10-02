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

// ---- client ------------------------------------------------------------------

#include <sys/socket.h>
#include <fcntl.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int

// nonblocking_pair is a connected, non-blocking AF_UNIX socket pair: TLS does
// not care what carries it, and both ends live in this thread.
fn nonblocking_pair() [2]int {
	mut sv := [2]i32{} // C ints: V's int is 64-bit
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	fds := [int(sv[0]), int(sv[1])]!
	for fd in fds {
		C.fcntl(fd, C.F_SETFL, C.fcntl(fd, C.F_GETFL, 0) | C.O_NONBLOCK)
	}
	return fds
}

// handshake_both steps a client and a server session in turn until both are
// done, or one fails: the client's result, then the server's.
fn handshake_both(cli Session, srv Session) (int, int) {
	mut cr, mut sr := want, want
	for _ in 0 .. 1000 {
		if cr != 0 && cr != closed {
			cli.mark_readable()
			cr = cli.handshake()
		}
		if sr != 0 && sr != closed {
			srv.mark_readable()
			sr = srv.handshake()
		}
		if (cr == 0 || cr == closed) && (sr == 0 || sr == closed || cr == closed) {
			break
		}
	}
	return cr, sr
}

// The client side (pg_async's TLS) against vanilla's own server side: each
// Verify mode against the self-signed localhost/loopback certificate, a host
// the certificate does not name, a session re-armed for a second connection,
// and data both ways.
fn test_client_sessions_against_the_server() {
	$if vanilla_tls ? {
		srv_cfg := new_self_signed() or { panic(err) }
		defer {
			srv_cfg.free()
		}
		ca := os.join_path(os.temp_dir(), 'vanilla_tls_client_ca_${os.getpid()}.pem')
		os.write_file(ca, srv_cfg.cert_pem()) or { panic(err) }
		defer {
			os.rm(ca) or {}
		}
		cases := [
			ClientCase{.full, 'localhost', ''},
			ClientCase{.full, '127.0.0.1', ''},
			ClientCase{.full, '::1', ''},
			ClientCase{.full, 'db.example.com', 'does not match the host name'},
			ClientCase{.chain, 'db.example.com', ''},
			ClientCase{.off, 'db.example.com', ''},
		]
		for case in cases {
			verify, host, want_err := case.verify, case.host, case.want_err
			cli_cfg := new_client(if verify == .off { '' } else { ca }, verify) or { panic(err) }
			mut cli := Session{}
			for round in 0 .. 2 {
				fds := nonblocking_pair()
				srv := srv_cfg.new_session(fds[0]) or { panic('server session') }
				if round == 0 {
					cli = cli_cfg.new_client_session(fds[1], host) or { panic('client session') }
				} else {
					// A re-dial: the same session, re-armed on a new socket.
					assert cli.reset(fds[1])
				}
				cr, _ := handshake_both(cli, srv)
				if want_err != '' {
					assert cr == closed, '${verify} ${host}: the handshake must fail'
					assert cli.handshake_error().contains(want_err), cli.handshake_error()
				} else {
					assert cr == 0, '${verify} ${host}: ${cli.handshake_error()}'
					// Exact-size C buffers: under AddressSanitizer a read or
					// write past either end (Mbed TLS's memcpy included) aborts.
					msg := 'ping ${host} ${round}'
					out := unsafe { &u8(C.malloc(msg.len)) }
					unsafe { vmemcpy(out, msg.str, msg.len) }
					assert cli.write_from(out, msg.len) == msg.len
					inb := unsafe { &u8(C.malloc(msg.len)) }
					srv.mark_readable()
					assert srv.read_into(inb, msg.len) == msg.len
					assert unsafe { tos(inb, msg.len) } == msg
					assert srv.write_from(out, msg.len) == msg.len
					cli.mark_readable()
					assert cli.read_into(inb, msg.len) == msg.len
					assert !cli.peer_closed()
					unsafe {
						C.free(out)
						C.free(inb)
					}
				}
				srv.free() // sends close_notify
				if want_err == '' {
					cli.mark_readable()
					assert cli.read_into(buf_scratch().data, 16) == closed
					assert cli.peer_closed()
				}
				assert cli.reset(-1) // detach before the fd is closed
				C.close(fds[0])
				C.close(fds[1])
			}
			cli.free()
			cli_cfg.free()
		}
	}
}

struct ClientCase {
	verify   Verify
	host     string
	want_err string // '' = the handshake succeeds
}

fn buf_scratch() []u8 {
	return []u8{len: 16}
}

// A root certificate file that is missing, or holds no certificate, is an
// error at config time; with Verify.off no file is read at all.
fn test_client_config_errors() {
	$if vanilla_tls ? {
		if _ := new_client('/nonexistent/ca.pem', .full) {
			assert false, 'a missing CA file must be an error'
		} else {
			assert err.msg().contains('/nonexistent/ca.pem'), err.msg()
		}
		junk := os.join_path(os.temp_dir(), 'vanilla_tls_junk_${os.getpid()}.pem')
		os.write_file(junk, 'not a certificate\n') or { panic(err) }
		defer {
			os.rm(junk) or {}
		}
		if _ := new_client(junk, .chain) {
			assert false, 'a file without a certificate must be an error'
		}
		c := new_client('/nonexistent/ca.pem', .off) or { panic(err) }
		c.free()
	}
}
