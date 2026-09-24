module tls

import os

// Real TLS implementation backed by the vanilla_tls C shim (Mbed TLS 4,
// TLS 1.3). Compiled only with `-d vanilla_tls`; otherwise the stubs in
// tls_stub_notd_vanilla_tls.c.v are used and Mbed TLS is not a dependency.
// The gnarly Mbed TLS macros/structs live in vanilla_tls.c; here we expose the
// small, clean V API declared (as types) in tls.v.

#flag -I@VMODROOT/tls
#flag -I/usr/local/include
#flag -L/usr/local/lib -lmbedtls -lmbedx509 -lmbedcrypto
#flag @VMODROOT/tls/vanilla_tls.c

#include "vanilla_tls.h"

fn C.vtls_global_init() int
fn C.vtls_ctx_new() voidptr
fn C.vtls_ctx_free(ctx voidptr)
fn C.vtls_use_self_signed(ctx voidptr, sans &&char, nsans usize) int
fn C.vtls_use_pem(ctx voidptr, cert &u8, clen usize, key &u8, klen usize) int
fn C.vtls_setup(ctx voidptr) int
fn C.vtls_set_alpn(ctx voidptr, list &char) int
fn C.vtls_cert_pem(ctx voidptr) &char
fn C.vtls_key_pem(ctx voidptr) &char
fn C.vtls_get_alpn(sess voidptr) &char
fn C.vtls_session_new(ctx voidptr, fd int) voidptr
fn C.vtls_session_free(sess voidptr)
fn C.vtls_handshake(sess voidptr) int
fn C.vtls_read(sess voidptr, buf &u8, len usize) int
fn C.vtls_write(sess voidptr, buf &u8, len usize) int
fn C.vtls_enable_ktls(sess voidptr, fd int) int
fn C.vtls_ktls_active(sess voidptr) int
fn C.vtls_ktls_failed(sess voidptr) int

// init performs process-wide crypto init (psa_crypto_init). Call once at startup.
pub fn initialize() ! {
	if C.vtls_global_init() != 0 {
		return error('vtls: psa_crypto_init failed')
	}
}

// new_self_signed builds a config with a self-signed certificate (EC P-256,
// TLS 1.3) - the zero-config way to get HTTPS without a CA. Defaults to
// SANs for localhost and the loopback IPs; pass `sans:` for the real host/IP
// and `persist_dir:` to keep the same identity across restarts (see
// SelfSignedOpts). The certificate is self-signed, so clients must be told to
// trust it: `curl --cacert`, an Android network-security-config trust anchor,
// or a browser exception - export it with cert_pem().
pub fn new_self_signed(opts SelfSignedOpts) !&Config {
	initialize()! // psa_crypto_init is idempotent
	if opts.persist_dir != '' {
		cert_path := os.join_path(opts.persist_dir, 'cert.pem')
		key_path := os.join_path(opts.persist_dir, 'key.pem')
		if os.exists(cert_path) && os.exists(key_path) {
			cert := os.read_bytes(cert_path) or {
				return error('vtls: cannot read ${cert_path}: ${err}')
			}
			key := os.read_bytes(key_path) or { return error('vtls: cannot read ${key_path}: ${err}') }
			return new_from_pem(cert, key)
		}
	}
	if opts.sans.len == 0 {
		return error('vtls: at least one SAN is required (e.g. "DNS:localhost" or "IP:203.0.113.5")')
	}
	ctx := C.vtls_ctx_new()
	if ctx == unsafe { nil } {
		return error('vtls: out of memory')
	}
	mut csans := []&char{cap: opts.sans.len}
	for s in opts.sans {
		csans << &char(s.str)
	}
	if C.vtls_use_self_signed(ctx, unsafe { &&char(csans.data) }, usize(csans.len)) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: self-signed certificate generation failed - each SAN must be "DNS:<host>" or "IP:<v4|v6>" (got ${opts.sans})')
	}
	if C.vtls_setup(ctx) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: ssl config setup failed')
	}
	if C.vtls_set_alpn(ctx, &char(default_alpn.str)) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: failed to set ALPN')
	}
	cfg := &Config{
		ctx: ctx
	}
	if opts.persist_dir != '' {
		persist_identity(cfg, opts.persist_dir) or {
			cfg.free()
			return err
		}
	}
	return cfg
}

// persist_identity writes key.pem (0600) then cert.pem into `dir` (created
// 0700 if missing). Key first: a crash between the two writes must never leave
// a cert on disk whose key is lost, or the next start would load a half pair.
fn persist_identity(cfg &Config, dir string) ! {
	if !os.exists(dir) {
		os.mkdir_all(dir, mode: 0o700) or { return error('vtls: cannot create ${dir}: ${err}') }
	}
	key := cfg.key_pem()
	if key == '' {
		return error('vtls: private key export failed, nothing persisted')
	}
	key_path := os.join_path(dir, 'key.pem')
	os.write_file(key_path, key) or { return error('vtls: cannot write ${key_path}: ${err}') }
	os.chmod(key_path, 0o600) or { return error('vtls: cannot chmod ${key_path}: ${err}') }
	cert_path := os.join_path(dir, 'cert.pem')
	os.write_file(cert_path, cfg.cert_pem()) or {
		return error('vtls: cannot write ${cert_path}: ${err}')
	}
}

// new_from_pem builds a config from PEM-encoded certificate and private key.
pub fn new_from_pem(cert []u8, key []u8) !&Config {
	initialize()!
	ctx := C.vtls_ctx_new()
	if ctx == unsafe { nil } {
		return error('vtls: out of memory')
	}
	// Mbed TLS detects PEM (vs DER) by a trailing NUL, and the length passed MUST
	// include it. os.read_bytes() doesn't NUL-terminate, so ensure it here.
	mut c := cert.clone()
	if c.len == 0 || c[c.len - 1] != 0 {
		c << 0
	}
	mut k := key.clone()
	if k.len == 0 || k[k.len - 1] != 0 {
		k << 0
	}
	if C.vtls_use_pem(ctx, c.data, usize(c.len), k.data, usize(k.len)) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: failed to parse PEM cert/key')
	}
	if C.vtls_setup(ctx) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: ssl config setup failed')
	}
	if C.vtls_set_alpn(ctx, &char(default_alpn.str)) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: failed to set ALPN')
	}
	return &Config{
		ctx: ctx
	}
}

// set_alpn overrides the advertised ALPN list (comma-separated, preference
// order — e.g. 'h2,http/1.1'). Defaults to `http/1.1`. Only advertise protocols
// the server can actually serve. Call before accepting connections.
pub fn (c &Config) set_alpn(protos string) ! {
	if C.vtls_set_alpn(c.ctx, &char(protos.str)) != 0 {
		return error('vtls: failed to set ALPN to "${protos}"')
	}
}

// cert_pem returns the certificate as PEM, to hand to clients that must trust
// a self-signed server: `curl --cacert server.pem`, an Android
// network-security-config trust anchor, a browser exception. Pair it with
// `persist_dir` in new_self_signed, otherwise the PEM is only valid for the
// current process - the next start generates a different certificate.
pub fn (c &Config) cert_pem() string {
	p := C.vtls_cert_pem(c.ctx)
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

// key_pem returns the private key as PEM - exported for new_self_signed
// configs, a copy of the input for new_from_pem ones. It is what
// `persist_dir` writes to key.pem; treat it like any private key - never
// log it. Empty only if the key did not fit the 2 KiB buffer.
pub fn (c &Config) key_pem() string {
	p := C.vtls_key_pem(c.ctx)
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

pub fn (c &Config) free() {
	C.vtls_ctx_free(c.ctx)
}

pub fn (c &Config) new_session(fd int) ?Session {
	s := C.vtls_session_new(c.ctx, fd)
	if s == unsafe { nil } {
		return none
	}
	return Session{
		sess: s
	}
}

// handshake drives the TLS handshake. Returns 0 (done), `want` (retry), or `closed`.
pub fn (s &Session) handshake() int {
	return C.vtls_handshake(s.sess)
}

// read_into decrypts up to `len` bytes into `ptr`. Returns >=0 bytes, `want`,
// or `closed`. Raw pointer so the read loop can fill a buffer's spare capacity.
pub fn (s &Session) read_into(ptr &u8, len int) int {
	return C.vtls_read(s.sess, ptr, usize(len))
}

// write_from encrypts `len` bytes from `ptr`. Returns bytes written (>=0),
// `want`, or `closed`.
pub fn (s &Session) write_from(ptr &u8, len int) int {
	return C.vtls_write(s.sess, ptr, usize(len))
}

// enable_ktls hands record crypto to the kernel after the handshake. true => reads
// and writes become PLAIN recv()/send() and the kernel does AES-128-GCM; false =>
// keep using read_into/write_from (userspace mbedtls). When it returns false, check
// ktls_failed(): if true the socket is half-converted and the connection must close.
pub fn (s &Session) enable_ktls(fd int) bool {
	return C.vtls_enable_ktls(s.sess, fd) == 1
}

// ktls_active reports whether kTLS is engaged on this session.
pub fn (s &Session) ktls_active() bool {
	return C.vtls_ktls_active(s.sess) == 1
}

// ktls_failed reports a setsockopt failure AFTER the kTLS ULP attached — the socket
// is then unusable for the userspace path, so the caller must close the connection.
pub fn (s &Session) ktls_failed() bool {
	return C.vtls_ktls_failed(s.sess) == 1
}

// alpn returns the protocol negotiated via ALPN (e.g. 'http/1.1'), or '' if the
// client offered none. Meaningful only after the handshake completes.
pub fn (s &Session) alpn() string {
	p := C.vtls_get_alpn(s.sess)
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

pub fn (s &Session) free() {
	C.vtls_session_free(s.sess)
}
