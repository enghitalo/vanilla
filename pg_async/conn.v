module pg_async

import tls
import time
import transport

// PgConn is a single PostgreSQL connection: the TCP socket (optionally TLS over
// it, see SslMode) plus the v3 startup / SCRAM-SHA-256 handshake and
// extended-query execution.
//
// This is the BLOCKING form. It is used for pool bring-up (connecting + auth
// happen once, before the worker starts serving) and to validate the protocol
// and SCRAM layers against a live server. The non-blocking, reactor-driven
// query path that the async worker uses is built on the same wire encoding
// (protocol.v) — only the I/O pump differs.

// pg_async deliberately does NOT import V's `net`: `net` declares `C.socket`
// with TYPED enum params on some V versions, and V merges C declarations
// globally — so importing `net` clashes with the plain-`int` `C.socket` that
// the socket module declares and breaks the build (e.g. on the V 0.5.1
// tag). The connection is opened with libc directly, using the same signatures
// server.socket uses. C.recv/C.send/C.fcntl live in conn_async.v.
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>

// Full addrinfo layout (matches V's net module) so sizeof is correct and every
// field is zeroed — a partial decl leaves ai_flags as stack garbage and
// getaddrinfo fails.
struct C.addrinfo {
mut:
	ai_family    int
	ai_socktype  int
	ai_flags     int
	ai_protocol  int
	ai_addrlen   int
	ai_addr      voidptr
	ai_canonname voidptr
	ai_next      voidptr
}

#include <poll.h>
#include "@VMODROOT/pg_async/pg_async_shim.h"

fn C.socket(domain int, typ int, protocol int) int
fn C.connect(sockfd int, addr voidptr, addrlen u32) int
fn C.close(fd int) int
fn C.getaddrinfo(node &char, service &char, hints &C.addrinfo, res &&C.addrinfo) int
fn C.freeaddrinfo(res &C.addrinfo)
fn C.pg_async_wait(fd int, events int, timeout_ms int) int
fn C.pg_async_gai_strerror(rc int) &char
fn C.pg_async_getsockopt_int(fd int, level int, name int) int

// resolve returns every address getaddrinfo gives for host:port, in its order
// (IPv6 and IPv4 alike); dial tries them in turn. Blocking: DNS.
fn resolve(host string, port int) ![]transport.Addr {
	mut hints := C.addrinfo{}
	unsafe { vmemset(&hints, 0, int(sizeof(hints))) }
	hints.ai_family = C.AF_UNSPEC
	hints.ai_socktype = C.SOCK_STREAM
	port_str := port.str()
	mut res := &C.addrinfo(unsafe { nil })
	rc := C.getaddrinfo(&char(host.str), &char(port_str.str), &hints, &res)
	if rc != 0 {
		reason := unsafe { cstring_to_vstring(C.pg_async_gai_strerror(rc)) }
		return error('pg: cannot resolve ${host}:${port}: ${reason}')
	}
	defer {
		C.freeaddrinfo(res)
	}
	mut out := []transport.Addr{}
	mut ai := res
	for ai != unsafe { nil } {
		if ai.ai_addrlen > 0 && ai.ai_addrlen <= 128 {
			mut a := transport.Addr{
				family: ai.ai_family
				len:    u32(ai.ai_addrlen)
			}
			unsafe { vmemcpy(&a.data[0], ai.ai_addr, ai.ai_addrlen) }
			out << a
		}
		ai = unsafe { &C.addrinfo(ai.ai_next) }
	}
	if out.len == 0 {
		return error('pg: no usable address for ${host}:${port}')
	}
	return out
}

// connect_addr opens a TCP socket to `a` with transport.dial_addr (the connect
// always starts non-blocking, on a close-on-exec socket tuned per cfg). With
// `nonblocking` the socket is returned as is (the connect may still be in
// flight: the re-dial path, redial.v, finishes it without waiting on the
// network). Otherwise this waits up to cfg.connect_timeout_ms (0 = no bound)
// for the connect to complete, then returns a blocking socket. On error the
// socket is closed and the errno is the error code.
fn connect_addr(a &transport.Addr, cfg &ConnConfig, nonblocking bool) !int {
	fd := transport.dial_addr(a, tcp_opts(cfg))
	if fd < 0 {
		return error_with_code('connect failed (errno ${-fd})', -fd)
	}
	if nonblocking {
		return fd
	}
	timeout_ms := cfg.connect_timeout_ms
	r := C.pg_async_wait(fd, C.POLLOUT, if timeout_ms > 0 { timeout_ms } else { -1 })
	if r == 0 {
		C.close(fd)
		return error_with_code('connect timed out after ${timeout_ms} ms', C.ETIMEDOUT)
	}
	so_error := transport.socket_error(fd)
	if r < 0 || so_error != 0 {
		C.close(fd)
		code := if so_error > 0 { so_error } else { C.errno }
		return error_with_code('connect failed (errno ${code})', code)
	}
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags < 0 || C.fcntl(fd, C.F_SETFL, flags & ~int(C.O_NONBLOCK)) < 0 {
		e := C.errno
		C.close(fd)
		return error_with_code('fcntl(restore blocking) failed', e)
	}
	return fd
}

// tcp_opts is the socket tuning cfg asks for: TCP_NODELAY, so a small
// pipelined query is not held back by Nagle waiting on the server's delayed
// ACK; keepalive and TCP_USER_TIMEOUT, so a peer that vanished without a FIN
// or RST is noticed.
fn tcp_opts(cfg &ConnConfig) transport.TcpOpts {
	return transport.TcpOpts{
		nodelay:           cfg.tcp_nodelay
		keepalive_idle_s:  cfg.tcp_keepalive_idle_s
		keepalive_intvl_s: cfg.tcp_keepalive_interval_s
		keepalive_cnt:     cfg.tcp_keepalive_count
		user_timeout_ms:   cfg.tcp_user_timeout_ms
	}
}

// dial resolves cfg.host:cfg.port and connects to the first address that
// accepts, starting at address `start` (mod the count) and trying each in
// turn. Every socket it returns is tuned (tcp_opts). Blocking (each connect
// bounded by connect_timeout_ms), unless `nonblocking`: then the first address
// whose connect() starts is returned with the connect possibly still in
// flight.
fn dial(cfg &ConnConfig, nonblocking bool, start int) !int {
	addrs := resolve(cfg.host, cfg.port)!
	return dial_addrs(addrs, cfg, nonblocking, start)
}

// dial_addrs is dial over an already resolved address list.
fn dial_addrs(addrs []transport.Addr, cfg &ConnConfig, nonblocking bool, start int) !int {
	mut last := ''
	for i in 0 .. addrs.len {
		a := &addrs[(start + i) % addrs.len]
		fd := connect_addr(a, cfg, nonblocking) or {
			last = err.msg()
			continue
		}
		return fd
	}
	return error('pg: connect to ${cfg.host}:${cfg.port} failed on all ${addrs.len} address(es): ${last}')
}

// SslMode is whether, and how strictly, a connection uses TLS — libpq's
// sslmode values, minus `allow` and `prefer`: a mode that asks for TLS gets it
// or fails, it never falls back to plaintext. TLS needs the `-d vanilla_tls`
// build (Mbed TLS 4, the same library the HTTPS server links); without it
// every mode but .disable fails to connect.
pub enum SslMode {
	disable     // plaintext (the default)
	require     // TLS; the certificate is not checked, unless ssl_root_cert is set: then as .verify_ca (libpq's rule)
	verify_ca   // TLS; the certificate chains to a trusted CA
	verify_full // TLS; the certificate chains to a trusted CA and names `host` (SNI is sent for a DNS name; an IP must be an iPAddress SAN, stricter than libpq): what managed databases need
}

// PasswordFn returns the password for one connection attempt (see
// ConnConfig.password_fn).
pub type PasswordFn = fn () !string

pub struct ConnConfig {
pub:
	host     string = 'localhost'
	port     int    = 5432
	user     string
	password string
	// password_fn, when set, is asked for the password on every connection
	// attempt instead of reading `password`: once per connection a pool brings
	// up, and once per re-dial (a lost connection, a max_lifetime_ms recycle).
	// It is for short-lived credentials, such as an IAM auth token (Aurora DSQL,
	// RDS), which the server checks only when a session starts. It runs on the
	// worker thread, never per query but inline in a re-dial step: keep it
	// fast and non-blocking (sign a token locally; fetch secrets elsewhere).
	// Every worker's pool calls it from its own thread, so state it shares
	// across workers needs a lock or atomics. An error fails the attempt, and
	// a pool retries after its backoff.
	password_fn PasswordFn = unsafe { nil }
	database    string
	// params are run-time parameters sent in the StartupMessage, the session's
	// defaults: {'application_name': 'orders-api'} names the sessions in
	// pg_stat_activity. A name or value holding a NUL, an empty name, and
	// `user` / `database` (set those fields) fail the connect before dialing.
	params map[string]string
	// allowed_auth lists the authentication methods the client answers, like
	// libpq's require_auth: .sasl (SCRAM-SHA-256) and .cleartext_password. A
	// server asking for another one is refused before any credential is sent.
	// A server that asks for none (AuthenticationOk at once: trust) is
	// accepted, as it sends nothing. .cleartext_password sends the password
	// itself and is answered only over TLS, whatever this list says: token
	// authentication (Aurora DSQL, RDS IAM) is [.cleartext_password] with
	// ssl_mode .verify_full. MD5 is not supported.
	allowed_auth []AuthType = [.sasl]
	// ssl_mode: see SslMode. TLS 1.3, negotiated with PostgreSQL's SSLRequest.
	ssl_mode SslMode
	// ssl_root_cert is the PEM file of trusted CA certificates for .verify_ca
	// and .verify_full; '' = the system's bundle (tls.system_ca_file:
	// $SSL_CERT_FILE, else /etc/ssl/certs/ca-certificates.crt and the like).
	ssl_root_cert string
	// connect_timeout_ms bounds the TCP connect to each resolved address on
	// the blocking bring-up path (over TLS, also the TLS handshake and the
	// authentication after it), and one whole re-dial attempt (connect +
	// handshake) on the non-blocking path. 0 = no bound on bring-up.
	connect_timeout_ms int = 5000
	// tcp_nodelay disables Nagle on the connection (what libpq does). Without
	// it a pipelined query written while an earlier one is unacknowledged can
	// wait for the server's delayed ACK (~40 ms on Linux). The cost is one TCP
	// segment per query flush instead of coalesced ones: a few µs of server CPU
	// per request under deep pipelining on loopback.
	tcp_nodelay bool = true
	// TCP keepalive: after tcp_keepalive_idle_s seconds without traffic, probe
	// every tcp_keepalive_interval_s; tcp_keepalive_count unanswered probes
	// drop the connection, so an idle pooled connection whose server vanished
	// (no FIN/RST: a host down, a NAT or firewall that forgot it) is found
	// broken instead of swallowing the next query. idle 0 = keepalive off.
	tcp_keepalive_idle_s     int = 30
	tcp_keepalive_interval_s int = 10
	tcp_keepalive_count      int = 3
	// tcp_user_timeout_ms (Linux): how long sent data may stay unacknowledged
	// before the kernel drops the connection. 0 = the OS default (~15 min of
	// retransmissions).
	tcp_user_timeout_ms int = 30_000
	// max_lifetime_ms (PgPool) recycles a pooled connection once it has been
	// up this long: it is taken out of the pool, its pipelined queries drain,
	// it says goodbye (Terminate) and is re-dialed in place without blocking
	// (a fresh password_fn credential), one connection at a time. Set it below
	// a server's own cap (Aurora DSQL closes every connection after 60 min), so
	// a query never meets the server's close. Driven by maintain(): run
	// start_maintenance (or call maintain() from your own timer). 0 = off.
	max_lifetime_ms int
	// lifetime_jitter_ms takes a random share of up to this much off each
	// connection's lifetime, so the connections every worker opened at startup
	// do not all come due in the same tick. max_lifetime_ms stays the bound.
	lifetime_jitter_ms int
}

// check_startup_params refuses run-time parameters the StartupMessage cannot
// carry as given: a NUL would end a name or value early (and let the rest be
// read as other parameters), an empty name ends the list, and user /
// database would override the fields of the same name.
fn check_startup_params(params map[string]string) ! {
	for name, value in params {
		if name == '' {
			return error('pg: startup parameter with an empty name')
		}
		if name.index_u8(0) >= 0 || value.index_u8(0) >= 0 {
			return error('pg: startup parameter `${name.replace('\0', '\\0')}` holds a NUL byte')
		}
		if name == 'user' || name == 'database' {
			return error('pg: set ConnConfig.${name}, not the `${name}` startup parameter')
		}
	}
}

// attempt_password is the password for one connection attempt: what
// password_fn answers when it is set, else the static password.
fn attempt_password(cfg &ConnConfig) !string {
	if cfg.password_fn != unsafe { nil } {
		return cfg.password_fn() or { return error('pg: password_fn failed: ${err.msg()}') }
	}
	return cfg.password
}

// LinkState is a connection's health. A live connection is .ready. It turns
// .broken the moment it is known lost: EOF, a socket error (a TLS error
// included), a FATAL/PANIC ErrorResponse, an exclusive borrower releasing
// it with a query still in flight (its reply stream can no longer be matched
// to queries), or a ROLLBACK queued at release that failed or got no answer
// (PgPool.finish_rollback). A broken connection takes no new query and fails what is still
// in flight — after delivering every reply already buffered — and its pool
// then re-dials it through .connecting (over TLS, .ssl_request and
// .tls_handshake) and .starting back to .ready, without blocking (redial.v).
enum LinkState {
	ready
	broken
	connecting    // re-dial: non-blocking connect() in flight
	ssl_request   // re-dial over TLS: SSLRequest sent, waiting for the server's one-byte answer
	tls_handshake // re-dial over TLS: the TLS handshake under way
	starting      // re-dial: StartupMessage sent, authenticating until ReadyForQuery
}

pub struct PgConn {
mut:
	fd       int = -1 // the raw socket fd
	state    LinkState
	fatal    PgError // the FATAL/PANIC that ended the session (sqlstate '' if none)
	loss     string  // why the connection was lost, as seen from this side
	recv_buf []u8
	recv_pos int // async read cursor: [recv_pos, recv_buf.len) is received-but-unframed
	// In-flight non-blocking query state. The connection pipelines up to
	// max_inflight queries: async_submit appends each query's wire bytes to the
	// fixed send buffer and pushes a PendingQuery onto the FIFO; async_on_readable
	// frames replies (Postgres returns them in submit order) into the front
	// PendingQuery and pops it at ReadyForQuery. One query in flight is just the
	// degenerate N=1 case.
	send_buf []u8 // fixed-capacity (send_buf_cap), allocated once, never realloc'd
	send_off int  // [0, send_off) already sent
	send_len int  // [send_off, send_len) written, still to send
	inflight []PendingQuery
	// ready_status is the transaction status byte of the last ReadyForQuery
	// that completed a query: tx_idle, tx_in_block or tx_failed (tx.v). A
	// fresh session starts idle.
	ready_status u8 = tx_idle
	// rollback_deadline is set while the ROLLBACK release() queued for a
	// connection left in a transaction is in flight (monotonic ns; 0 = none):
	// the pool hands the connection out again only once that ROLLBACK's
	// ReadyForQuery reports it idle (PgPool.finish_rollback).
	rollback_deadline u64
	// Per-connection reply-accumulator pool: max_inflight buffers (frame_buf_cap each)
	// allocated ONCE and reused round-robin via frame_ring, so a pipelined query never
	// allocates its accumulator per submit — essential under `-gc none`, where a
	// per-query allocation would leak. async_on_readable writes the (possibly grown)
	// buffer back to its slot on completion so growth is preserved across reuse.
	frame_pool [][]u8
	frame_ring int
	// Per-connection reusable wire-frame scratch for async_submit: one query's
	// Parse+Bind+Describe+Execute+Sync is serialized here, then copied into send_buf.
	// Allocated once (lazy), reset to len 0 each submit, grows to a high-water mark —
	// so a submit never allocates a throwaway frame (which would leak under -gc none).
	submit_scratch []u8
	// Re-dial bookkeeping (redial.v), touched only while the connection is not
	// .ready: the SCRAM exchange in progress, the earliest next attempt after a
	// failed one, and the deadline of the attempt in flight (monotonic ns).
	scram         ScramClient
	retry_at      u64
	dial_deadline u64
	// addr_cursor is the resolved address the next re-dial starts at: a failed
	// attempt moves it on, so a dead address (an IPv6 one on an IPv4-only path,
	// a failed-over primary) is not retried first forever.
	addr_cursor int
	// scram_cache is the pool's PBKDF2 cache (ScramCache), shared by its
	// connections so a bring-up derives once and a re-dial not at all; nil
	// for a standalone connection.
	scram_cache &ScramCache = unsafe { nil }
	// tls is the TLS session over fd (ssl_mode != .disable), else the zero
	// Session: the one field every send and recv branches on (transport.v).
	// It and the rest of the TLS state sit after the plaintext path's fields,
	// so adding them moved none of those.
	tls tls.Session
	// TLS bookkeeping (transport.v): the client config the session comes from
	// (the pool's, or this connection's own when owns_tls), the readiness a
	// blocked TLS call waits for (POLLIN / POLLOUT), the length a write Mbed
	// TLS could not finish must be retried with, and whether a read is
	// blocked until the socket takes a write (async_wants_write).
	tls_cfg          &tls.Config = unsafe { nil }
	owns_tls         bool
	tls_wait         int
	tls_wlen         int
	tls_read_blocked bool
	// io_deadline bounds the waits of the blocking bring-up over TLS
	// (monotonic ns; 0 = wait as long as it takes).
	io_deadline u64
	// What cancel() needs (cancel.v): the BackendKeyData of the session (its
	// process id, and its secret key as bytes: 4 on protocol 3.0, up to 256
	// on 3.2), refreshed by every bring-up and re-dial; the host TLS sessions
	// are started for (SNI and verify_full); the CancelRequest in flight.
	backend_pid int
	cancel_key  []u8
	tls_host    string
	cancel      PgCancel
	// expires_at is when a pooled connection is due for recycling
	// (max_lifetime_ms, monotonic ns; max_u64 = never), set each time it
	// comes up (lifetime_deadline).
	expires_at u64 = max_u64
}

struct Msg {
	typ     u8
	payload []u8
}

// PgConn.connect opens a TCP connection — TLS over it unless ssl_mode is
// .disable — and runs the startup and authentication (SCRAM-SHA-256, or a
// cleartext password over TLS: allowed_auth), returning once the server
// reports ReadyForQuery.
pub fn PgConn.connect(cfg ConnConfig) !PgConn {
	check_startup_params(cfg.params)!
	mut c := PgConn{
		recv_buf: []u8{cap: 16 * 1024}
	}
	if cfg.ssl_mode != .disable {
		c.tls_cfg = new_tls_config(&cfg)!
		c.owns_tls = true
	}
	c.bring_up(&cfg) or {
		c.teardown()
		return err
	}
	return c
}

// bring_up dials and authenticates, blocking: the attempt's password first
// (start_auth: password_fn), then the TCP connect, over TLS the SSLRequest and
// the TLS handshake (on a non-blocking socket, every wait bounded by
// connect_timeout_ms), then the startup and authentication.
fn (mut c PgConn) bring_up(cfg &ConnConfig) ! {
	c.start_auth(cfg)!
	c.fd = dial(cfg, false, 0)!
	if c.tls_cfg != unsafe { nil } {
		if cfg.connect_timeout_ms > 0 {
			c.io_deadline = time.sys_mono_now() + u64(cfg.connect_timeout_ms) * u64(time.millisecond)
		}
		c.set_nonblocking()!
		for !c.send_ssl_request()! {
			c.wait_io(C.POLLOUT)!
		}
		for !c.ssl_answer()! {
			c.wait_io(C.POLLIN)!
		}
		c.tls_attach(cfg)!
		for !c.tls_step(cfg)! {
			c.wait_io(c.tls_wait)!
		}
	}
	c.handshake(cfg)!
	c.io_deadline = 0
}

// close sends a best-effort Terminate (and, over TLS, close_notify) and closes
// the socket.
pub fn (mut c PgConn) close() {
	if c.fd >= 0 && c.state == .ready {
		c.send_terminate()
	}
	c.teardown()
}

// terminate_msg is a Terminate ('X'): the whole message, Int32 length 4.
const terminate_msg = [u8(`X`), 0, 0, 0, 4]!

// send_terminate tells the server the session ends: one attempt, never waiting
// on a peer to close, nothing allocated.
fn (mut c PgConn) send_terminate() {
	c.send_some(&terminate_msg[0], terminate_msg.len)
}

// teardown frees the TLS session (sending close_notify while the socket is
// still open) and the connection's own TLS config, then closes the socket.
// The connection is left broken; over TLS it also has no config left, so a
// later re-dial fails before it dials (redial_start) instead of reaching
// freed memory.
fn (mut c PgConn) teardown() {
	if c.tls.active() {
		c.tls.free()
		c.tls = tls.Session{}
	}
	c.cancel_teardown() // before the TLS config its session comes from goes
	if c.owns_tls && c.tls_cfg != unsafe { nil } {
		c.tls_cfg.free()
	}
	c.tls_cfg = unsafe { nil }
	if c.fd >= 0 {
		C.close(c.fd)
		c.fd = -1
	}
	c.state = .broken
}

// is_broken reports whether the connection is unusable: lost (EOF, socket
// error, a FATAL/PANIC from the server) or still being re-dialed by its pool.
// After a query error it tells a lost connection — retry on another one; the
// pool re-dials this one — from a statement error on a healthy connection
// (see PgError for the SQLSTATE).
pub fn (c &PgConn) is_broken() bool {
	return c.state != .ready
}

// lose marks a live connection broken, recording why. The first cause wins:
// a later symptom (the EOF after a FATAL) does not overwrite it.
fn (mut c PgConn) lose(reason string) {
	if c.state == .ready {
		c.state = .broken
		c.loss = reason
	}
}

// loss_error is the error a lost connection reports for a query that cannot
// complete: the FATAL the server ended the session with, when it sent one.
fn (c &PgConn) loss_error() IError {
	if c.fatal.sqlstate != '' {
		return c.fatal
	}
	return error('pg: ${c.loss}')
}

// send writes all of data, waiting while the socket is full — except during a
// re-dial, which must never block the worker (its messages are small, on an
// empty socket: a full one fails the attempt instead).
fn (mut c PgConn) send(data []u8) ! {
	mut sent := 0
	for sent < data.len {
		n := c.send_some(unsafe { &u8(data.data) + sent }, data.len - sent)
		if n > 0 {
			sent += n
			continue
		}
		if n == io_again && c.state == .ready {
			c.wait_io(c.io_wait(C.POLLOUT))!
			continue
		}
		return error('pg: send failed')
	}
}

// read_msg blocks until one complete backend message is buffered, returns it,
// and consumes it from the receive buffer.
fn (mut c PgConn) read_msg() !Msg {
	for {
		if hdr := next_message(c.recv_buf) {
			typ := c.recv_buf[0]
			payload := c.recv_buf[5..hdr.total].clone()
			c.recv_buf.delete_many(0, hdr.total)
			return Msg{
				typ:     typ
				payload: payload
			}
		}
		mut tmp := []u8{len: 16 * 1024}
		if c.tls.active() {
			c.tls.mark_readable()
		}
		n := c.recv_some(tmp.data, tmp.len)
		if n == io_again {
			c.wait_io(c.io_wait(C.POLLIN))!
			continue
		}
		if n <= 0 {
			return error('pg: connection closed by server')
		}
		c.recv_buf << tmp[..n]
	}
	return error('pg: unreachable')
}

// handshake sends the StartupMessage and answers the authentication with
// c.scram (start_auth), blocking until ReadyForQuery.
fn (mut c PgConn) handshake(cfg ConnConfig) ! {
	mut startup := []u8{}
	write_startup(mut startup, cfg.user, cfg.database, cfg.params)
	c.send(startup)!
	for {
		msg := c.read_msg()!
		if c.on_startup_msg(msg.typ, msg.payload, &cfg, mut c.scram)! {
			return
		}
	}
}

// on_startup_msg handles one backend message of the startup / authentication
// exchange, answering the authentication requests cfg allows; true once
// ReadyForQuery arrives. Shared by the blocking handshake and the
// non-blocking re-dial (redial.v).
fn (mut c PgConn) on_startup_msg(typ u8, payload []u8, cfg &ConnConfig, mut scram ScramClient) !bool {
	match typ {
		bt_authentication {
			c.handle_auth(payload, cfg, mut scram)!
		}
		bt_error_response {
			info := parse_error_response(payload)
			return error('pg: startup failed: ${info.message.bytestr()} (SQLSTATE ${info.code.bytestr()})')
		}
		bt_ready_for_query {
			return true
		}
		bt_backend_key_data {
			c.set_backend_key(payload)
		}
		else {
			// ParameterStatus / NoticeResponse — ignored.
		}
	}
	return false
}

// handle_auth answers one Authentication request. `scram` carries the
// attempt's password, for SCRAM and for a cleartext request alike.
fn (mut c PgConn) handle_auth(payload []u8, cfg &ConnConfig, mut scram ScramClient) ! {
	sub := auth_subtype(payload)
	data := if payload.len > 4 { payload[4..] } else { []u8{} }
	match sub {
		0 {
			// AuthenticationOk — ReadyForQuery follows.
		}
		3 {
			// AuthenticationCleartextPassword — the password itself, so only
			// when allowed and only inside TLS: on a plaintext connection
			// anyone on the path would read it, and a man in the middle could
			// ask for it in place of the server's SCRAM.
			if AuthType.cleartext_password !in cfg.allowed_auth {
				return error('pg: the server asks for a cleartext password, which allowed_auth does not allow (token authentication: allowed_auth [.cleartext_password] with ssl_mode .verify_full)')
			}
			if !c.tls.active() {
				return error('pg: refusing to send a cleartext password over an unencrypted connection (set ssl_mode, e.g. .verify_full)')
			}
			c.send_password(scram.password)!
		}
		10 {
			// AuthenticationSASL — offer SCRAM-SHA-256, send the client-first message.
			if AuthType.sasl !in cfg.allowed_auth {
				return error('pg: the server asks for SASL (SCRAM-SHA-256) authentication, which allowed_auth does not allow')
			}
			mut m := []u8{}
			write_sasl_initial(mut m, scram_sha_256, scram.client_first())
			c.send(m)!
		}
		11 {
			// AuthenticationSASLContinue — server-first → client-final.
			client_final := scram.handle_server_first(data)!
			mut m := []u8{}
			write_sasl_response(mut m, client_final)
			c.send(m)!
		}
		12 {
			// AuthenticationSASLFinal — verify the server signature.
			scram.handle_server_final(data)!
		}
		else {
			return error('pg: unsupported authentication method (code ${sub}); pg_async implements SCRAM-SHA-256 and, over TLS, cleartext password')
		}
	}
}

// send_password answers AuthenticationCleartextPassword with a
// PasswordMessage, then zeroes the buffer that held the password.
fn (mut c PgConn) send_password(password string) ! {
	if password.index_u8(0) >= 0 {
		return error('pg: the password holds a NUL byte')
	}
	mut m := []u8{cap: password.len + 6}
	write_password(mut m, password)
	c.send(m) or {
		wipe(mut m)
		return err
	}
	wipe(mut m)
}

// query runs one extended-protocol query (Parse/Bind/Describe/Execute/Sync,
// binary results) and returns the collected Result. Blocking. Parameters are
// text-format and bind to $1, $2, … (a null option element is SQL NULL).
pub fn (mut c PgConn) query(query_text string, params []?[]u8) !Result {
	mut out := []u8{}
	write_parse(mut out, '', query_text)
	write_bind(mut out, '', '', params)
	write_describe_portal(mut out, '')
	write_execute(mut out, '', 0)
	write_sync(mut out)
	c.send(out)!

	mut frames := []u8{}
	mut rows_affected := u64(0)
	mut server_error := PgError{}
	mut failed := false
	for {
		msg := c.read_msg() or {
			c.lose('connection closed by server')
			if failed {
				return server_error // the statement's own error came before the close
			}
			return err
		}
		match msg.typ {
			bt_ready_for_query {
				if msg.payload.len > 0 {
					c.ready_status = msg.payload[0]
				}
				break
			}
			bt_command_complete {
				rows_affected = parse_command_complete(msg.payload)
			}
			bt_error_response {
				info := parse_error_response(msg.payload)
				server_error = PgError{
					severity: info.severity.bytestr()
					sqlstate: info.code.bytestr()
					message:  info.message.bytestr()
				}
				failed = true
				if ends_session(info.severity) {
					c.fatal = server_error
					c.lose('connection closed by server')
					return server_error // no ReadyForQuery follows a FATAL/PANIC
				}
			}
			else {}
		}

		// Re-frame the message into the result region so Result.rows()
		// (FrameIter) can walk the DataRows.
		mut framed := [msg.typ]
		put_u32(mut framed, u32(4 + msg.payload.len))
		framed << msg.payload
		frames << framed
	}
	if failed {
		return server_error
	}
	return Result{
		frames:        frames
		rows_affected: rows_affected
	}
}
