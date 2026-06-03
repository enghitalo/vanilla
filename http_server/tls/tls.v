module tls

// V bindings over the vanilla_tls C shim (Mbed TLS 4, TLS 1.3). The gnarly
// Mbed TLS macros/structs live in vanilla_tls.c; here we expose a small, clean
// V API: a server-wide Config (cert + key + ssl conf) and per-connection
// Sessions driven by the non-blocking epoll loop.

#flag -I@VMODROOT/http_server/tls
#flag -I/usr/local/include
#flag -L/usr/local/lib -lmbedtls -lmbedx509 -lmbedcrypto
#flag @VMODROOT/http_server/tls/vanilla_tls.c

#include "vanilla_tls.h"

fn C.vtls_global_init() int
fn C.vtls_ctx_new() voidptr
fn C.vtls_ctx_free(ctx voidptr)
fn C.vtls_use_self_signed(ctx voidptr) int
fn C.vtls_use_pem(ctx voidptr, cert &u8, clen usize, key &u8, klen usize) int
fn C.vtls_setup(ctx voidptr) int
fn C.vtls_set_alpn(ctx voidptr, list &char) int
fn C.vtls_cert_pem(ctx voidptr) &char
fn C.vtls_get_alpn(sess voidptr) &char
fn C.vtls_session_new(ctx voidptr, fd int) voidptr
fn C.vtls_session_free(sess voidptr)
fn C.vtls_handshake(sess voidptr) int
fn C.vtls_read(sess voidptr, buf &u8, len usize) int
fn C.vtls_write(sess voidptr, buf &u8, len usize) int

// Handshake/read/write status (mirrors the C shim). Negative so they never
// collide with a byte count from read/write.
pub const want = -2 // would block on READ — retry on the next EPOLLIN
pub const want_write = -3 // would block on WRITE — retry on the next EPOLLOUT
pub const closed = -1 // fatal — close the connection

// Default ALPN offer. Only `http/1.1` for now: advertising `h2` while the
// server speaks only HTTP/1.1 would let an h2 client negotiate a protocol we
// can't serve (RFC 7301 §3.2). When HTTP/2 lands, this becomes 'h2,http/1.1'
// and the worker branches on Session.alpn().
pub const default_alpn = 'http/1.1'

// Config is a server-wide TLS configuration (certificate + key + SSL settings).
pub struct Config {
	ctx voidptr
}

// init performs process-wide crypto init (psa_crypto_init). Call once at startup.
pub fn init() ! {
	if C.vtls_global_init() != 0 {
		return error('vtls: psa_crypto_init failed')
	}
}

// new_self_signed builds a config with a freshly generated self-signed cert
// (EC P-256, TLS 1.3) — handy for dev/testing without a real certificate.
pub fn new_self_signed() !&Config {
	init()! // psa_crypto_init is idempotent
	ctx := C.vtls_ctx_new()
	if ctx == unsafe { nil } {
		return error('vtls: out of memory')
	}
	if C.vtls_use_self_signed(ctx) != 0 {
		C.vtls_ctx_free(ctx)
		return error('vtls: self-signed certificate generation failed')
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

// new_from_pem builds a config from PEM-encoded certificate and private key.
pub fn new_from_pem(cert []u8, key []u8) !&Config {
	init()!
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

// cert_pem returns the certificate as PEM (e.g. to save so a client can trust a
// self-signed cert: `curl --cacert server.pem`).
pub fn (c &Config) cert_pem() string {
	p := C.vtls_cert_pem(c.ctx)
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

pub fn (c &Config) free() {
	C.vtls_ctx_free(c.ctx)
}

// Session is a per-connection TLS session bound to an accepted, non-blocking fd.
pub struct Session {
	sess voidptr
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
