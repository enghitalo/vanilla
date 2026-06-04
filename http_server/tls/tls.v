module tls

// Public TLS surface (types + status codes) shared by both builds.
//
// The Mbed TLS 4 implementation is heavy (links libmbedtls/x509/crypto and
// compiles vanilla_tls.c), so it is opt-in: it only compiles when the program
// is built with `-d vanilla_tls`. Without that flag a thin stub is compiled
// instead, so a plain-HTTP server (and the benchmark entry) builds with no
// Mbed TLS dependency at all.
//
//   real impl  -> tls_mbedtls_d_vanilla_tls.c.v   (built with `-d vanilla_tls`)
//   stub       -> tls_stub_notd_vanilla_tls.c.v   (built by default)
//
// The types and constants below are identical in both builds, so the rest of
// http_server (worker dispatch, the TLS connection state machine) type-checks
// and compiles regardless; only the C-backed bodies differ.

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

// Session is a per-connection TLS session bound to an accepted, non-blocking fd.
pub struct Session {
	sess voidptr
}
