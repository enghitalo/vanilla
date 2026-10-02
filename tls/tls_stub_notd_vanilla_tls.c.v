module tls

// TLS stubs compiled by default (i.e. without `-d vanilla_tls`). They keep the
// public API present so the rest of the server module type-checks and links with no
// Mbed TLS dependency, while making any attempt to actually use TLS fail
// loudly. To get a working TLS server, rebuild with `-d vanilla_tls` (which
// swaps in tls_mbedtls_d_vanilla_tls.c.v and links Mbed TLS).

const not_built = 'vtls: built without TLS support — rebuild with `-d vanilla_tls` (and install Mbed TLS 4)'

pub fn parallel_crypto() bool {
	return true
}

pub fn initialize() ! {
	return error(not_built)
}

pub fn new_self_signed(opts SelfSignedOpts) !&Config {
	return error(not_built)
}

pub fn new_from_pem(cert []u8, key []u8) !&Config {
	return error(not_built)
}

pub fn (c &Config) set_alpn(protos string) ! {
	return error(not_built)
}

pub fn (c &Config) set_ktls(enabled bool) {}

pub fn (c &Config) set_ktls_rx_no_pad(enabled bool) {}

pub fn (c &Config) cert_pem() string {
	return ''
}

pub fn (c &Config) key_pem() string {
	return ''
}

pub fn (c &Config) free() {}

pub fn (c &Config) new_session(fd int) ?Session {
	return none
}

pub fn (s &Session) handshake() int {
	return closed
}

pub fn (s &Session) read_into(ptr &u8, len int) int {
	return closed
}

pub fn (s &Session) mark_readable() {}

pub fn (s &Session) write_from(ptr &u8, len int) int {
	return closed
}

pub fn (s &Session) enable_ktls(fd int) bool {
	return false
}

pub fn (s &Session) ktls_active() bool {
	return false
}

pub fn (s &Session) ktls_failed() bool {
	return false
}

pub fn (s &Session) ktls_abort() {}

pub fn (s &Session) alpn() string {
	return ''
}

pub fn (s &Session) free() {}

pub fn (s &Session) peer_closed() bool {
	return false
}

pub fn system_ca_file() string {
	return ''
}

pub fn new_client(ca_file string, verify Verify) !&Config {
	return error(not_built)
}

pub fn (c &Config) new_client_session(fd int, host string) ?Session {
	return none
}

pub fn (s &Session) reset(fd int) bool {
	return false
}

pub fn (s &Session) handshake_error() string {
	return not_built
}
