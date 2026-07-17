module tls

// TLS stubs compiled by default (i.e. without `-d vanilla_tls`). They keep the
// public API present so the rest of the server module type-checks and links with no
// Mbed TLS dependency, while making any attempt to actually use TLS fail
// loudly. To get a working TLS server, rebuild with `-d vanilla_tls` (which
// swaps in tls_mbedtls_d_vanilla_tls.c.v and links Mbed TLS).

const not_built = 'vtls: built without TLS support — rebuild with `-d vanilla_tls` (and install Mbed TLS 4)'

pub fn initialize() ! {
	return error(not_built)
}

pub fn new_self_signed() !&Config {
	return error(not_built)
}

pub fn new_from_pem(cert []u8, key []u8) !&Config {
	return error(not_built)
}

pub fn (c &Config) set_alpn(protos string) ! {
	return error(not_built)
}

pub fn (c &Config) cert_pem() string {
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

pub fn (s &Session) alpn() string {
	return ''
}

pub fn (s &Session) free() {}
