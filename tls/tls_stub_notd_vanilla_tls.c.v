module tls

// TLS stubs compiled by default (i.e. without `-d vanilla_tls`). They keep the
// public API present so the rest of the server module type-checks and links with no
// Mbed TLS dependency, while making any attempt to actually use TLS fail
// loudly. To get a working TLS server, rebuild with `-d vanilla_tls` (which
// swaps in tls_mbedtls_d_vanilla_tls.c.v and links Mbed TLS).

const not_built = 'vtls: built without TLS support — rebuild with `-d vanilla_tls` (and install Mbed TLS 4)'

// parallel_crypto reports whether TLS workers run their crypto in parallel:
// true when the linked Mbed TLS was built with MBEDTLS_THREADING_C; false
// when every call into it takes one process-wide lock (the workers then take
// turns in the crypto library). Either way the functions are safe from
// several threads on distinct sessions. The stub has no crypto: true.
pub fn parallel_crypto() bool {
	return true
}

// initialize runs the process-wide crypto init (psa_crypto_init). Idempotent;
// every constructor calls it, so an application needs it only to fail early.
// The stub errors: built without `-d vanilla_tls`.
pub fn initialize() ! {
	return error(not_built)
}

// new_self_signed builds a server config with a freshly generated self-signed
// certificate (EC P-256, TLS 1.3) for the SANs in `opts`, kept across
// restarts with `persist_dir` (see SelfSignedOpts); export it with cert_pem()
// for clients to trust. The stub errors: built without `-d vanilla_tls`.
pub fn new_self_signed(opts SelfSignedOpts) !&Config {
	return error(not_built)
}

// new_from_pem builds a server config from a PEM certificate (chain) and its
// PEM private key, copying both. Errors when either does not parse; a key
// that does not match the certificate is not detected (#284). The stub
// errors: built without `-d vanilla_tls`.
pub fn new_from_pem(cert []u8, key []u8) !&Config {
	return error(not_built)
}

// set_alpn replaces the advertised ALPN list (default_alpn until then),
// comma-separated in preference order: at most 63 bytes and 4 protocols
// (#297). Not atomic: call it before serving. The stub errors: built without
// `-d vanilla_tls`.
pub fn (c &Config) set_alpn(protos string) ! {
	return error(not_built)
}

// set_ktls allows (the default) or forbids kernel TLS for the sessions
// created from now on; atomic, so it may flip while workers run. The stub
// does nothing.
pub fn (c &Config) set_ktls(enabled bool) {}

// set_ktls_rx_no_pad opts kTLS sessions in to TLS_RX_EXPECT_NO_PAD: the
// kernel decrypts straight into the recv buffer. Off by default: older
// kernels (fixed in v7.2, v7.1.9+, v6.18.45+) corrupt a padded record, so
// enable it on a fixed kernel or with peers that never pad. Not atomic: call
// it before serving. The stub does nothing.
pub fn (c &Config) set_ktls_rx_no_pad(enabled bool) {}

// set_session_tickets makes a server config send `n` TLS 1.3
// NewSessionTickets at the end of each handshake (0, the default: none), for
// tests of clients; such sessions never enable kTLS. Not atomic: call it
// before serving. The stub returns an error.
pub fn (c &Config) set_session_tickets(n int) ! {
	return error(not_built)
}

// cert_pem returns the server certificate as PEM, for clients that must trust
// it; '' for a client config, or when new_from_pem's PEM did not fit 4 KiB.
// Allocates a V string. The stub returns ''.
pub fn (c &Config) cert_pem() string {
	return ''
}

// key_pem returns the server's private key as PEM (what persist_dir writes
// to key.pem; never log it); '' for a client config, or when it did not fit
// 2 KiB. Allocates a V string. The stub returns ''.
pub fn (c &Config) key_pem() string {
	return ''
}

// free releases the config. Call it once, after every session created from
// it is freed. The stub does nothing.
pub fn (c &Config) free() {}

// new_session starts a server session on `fd`, an accepted non-blocking
// socket, copying the config's kTLS settings as they are now; none when
// allocation or setup fails. The stub returns none.
pub fn (c &Config) new_session(fd int) ?Session {
	return none
}

// handshake drives the TLS handshake as far as the socket allows: 0 once
// complete, `want` / `want_write` to call again when the socket is ready,
// `closed` when it failed (handshake_error says why). The stub returns
// `closed`.
pub fn (s &Session) handshake() int {
	return closed
}

// read_into decrypts up to `len` (> 0) bytes into `ptr` and returns how
// many, never 0; `want` once the socket is drained (read again after
// mark_readable), `want_write` when Mbed TLS must send first, `closed` on the
// peer's close (peer_closed) or a fatal error. The stub returns `closed`.
pub fn (s &Session) read_into(ptr &u8, len int) int {
	return closed
}

// mark_readable tells the session its socket may hold new bytes: call it on
// every readable edge, before handshake / read_into. The stub does nothing.
pub fn (s &Session) mark_readable() {}

// write_from encrypts and sends up to `len` bytes (one record at most) and
// returns how many it took; on `want_write` / `want` call it again with the
// SAME `ptr` and `len` once the socket is ready; `closed` on a fatal error.
// The stub returns `closed`.
pub fn (s &Session) write_from(ptr &u8, len int) int {
	return closed
}

// enable_ktls hands record crypto to the kernel after the handshake: true
// means plain recv/send from now on; false keeps read_into / write_from,
// unless ktls_failed() says the connection must close. The stub returns
// false.
pub fn (s &Session) enable_ktls(fd int) bool {
	return false
}

// ktls_active reports whether kTLS is engaged on this session. The stub
// returns false.
pub fn (s &Session) ktls_active() bool {
	return false
}

// ktls_failed reports that enable_ktls left the socket half-converted: the
// connection must close. The stub returns false.
pub fn (s &Session) ktls_failed() bool {
	return false
}

// ktls_abort sends a fatal alert on a kTLS session about to close
// mid-response, after the record a MSG_MORE send left open. The stub does
// nothing.
pub fn (s &Session) ktls_abort() {}

// alpn returns the protocol negotiated via ALPN, '' if none, once the
// handshake is complete. Allocates a V string. The stub returns ''.
pub fn (s &Session) alpn() string {
	return ''
}

// free ends the session: a close_notify on a userspace session (not on kTLS,
// nor after reset(-1)), then its memory. It does not close the fd. The stub
// does nothing.
pub fn (s &Session) free() {}

// peer_closed reports whether the peer ended the session (EOF or
// close_notify), making read_into's `closed` a clean close. The stub returns
// false.
pub fn (s &Session) peer_closed() bool {
	return false
}

// close_notify reports whether the peer ended the session with a
// close_notify alert, not a bare EOF (RFC 9112 §9.8). The stub returns false.
pub fn (s &Session) close_notify() bool {
	return false
}

// verify_failed reports, after handshake() returned `closed`, whether the
// server's certificate failed verification. No allocation. The stub returns
// false.
pub fn (s &Session) verify_failed() bool {
	return false
}

// system_ca_file is the system's trusted CA bundle (PEM): $SSL_CERT_FILE,
// else the first that exists of the usual distribution paths; '' if none.
// The stub returns ''.
pub fn system_ca_file() string {
	return ''
}

// new_client builds a TLS 1.3 client config that checks the server's
// certificate per `verify` against the PEM bundle `ca_file` ('' =
// system_ca_file()). Errors when the bundle is missing or unreadable. The
// stub errors: built without `-d vanilla_tls`.
pub fn new_client(ca_file string, verify Verify) !&Config {
	return error(not_built)
}

// new_client_session starts a client session on `fd`, a connected
// non-blocking socket, to `host` (SNI and the name checked under
// Verify.full; an IP is matched against iPAddress SANs); none when allocation
// or setup fails. The stub returns none.
pub fn (c &Config) new_client_session(fd int, host string) ?Session {
	return none
}

// reset re-arms a client session for a new handshake on a new socket,
// keeping its buffers; fd -1 detaches it from a socket about to close. false
// when Mbed TLS failed to reset. The stub returns false.
pub fn (s &Session) reset(fd int) bool {
	return false
}

// handshake_error says why handshake() returned `closed` (the failed
// certificate check, or the TLS error). Allocates a V string. The stub
// returns the not-built message.
pub fn (s &Session) handshake_error() string {
	return not_built
}
