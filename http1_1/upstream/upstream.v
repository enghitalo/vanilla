module upstream

// upstream — a pooled HTTP/1.1 + HTTPS client for handlers on the worker
// reactor (#229): call a third-party API from a request without blocking the
// worker, the way pg_async calls PostgreSQL.
//
// One Pool per origin per worker, built in make_state (no locks: the worker
// owns it). A handler acquire()s an Exchange (one pooled connection), writes
// the request into it and send()s it; the exchange parks on its socket with
// watch_fd_persistent and the handler returns .suspend. The continuation
// finds the exchange by its fd (exchange_of) and advance()s it until it is
// .ready (status, headers and body are views into the exchange's buffer) or
// .failed (failure() says why), answers, and release()s it.
//
//   fn charge(req []u8, mut out []u8, client_fd int, ws voidptr, mut el core.EventLoop) core.Step {
//       mut st := unsafe { &App(ws) }
//       mut x := st.pay.acquire() or { out << resp_503; return .done }
//       x.request('POST', '/v1/charges')
//       x.header('authorization', st.pay_auth)
//       mut b := x.body()
//       b << ... // the JSON, appended in place
//       if x.send(mut el, on_charge, unsafe { nil }) == .pending {
//           return .suspend
//       }
//       x.release()
//       out << resp_502
//       return .done
//   }
//
//   fn on_charge(mut out []u8, fd int, fd_err bool, payload voidptr, ws voidptr, mut el core.EventLoop) core.Step {
//       mut st := unsafe { &App(ws) }
//       mut x := st.pay.exchange_of(fd) or { out << resp_502; return .done }
//       match x.advance(fd_err, mut el, on_charge, payload) {
//           .pending { return .suspend }
//           .failed { ... x.release(); out << resp_502 / resp_504; return .done }
//           .ready {}
//       }
//       // x.status(), x.header_value('content-type'), x.body_view()
//       x.release()
//       return .done
//   }
//
// What it does per exchange: a non-blocking dial to the origin's next
// address (transport.dial_addr), the TLS 1.3 handshake on the slot's own
// session (verify-full + SNI with tls.Verify.full), the request written as
// the socket takes it, the response framed as it arrives (client.Framer: HEAD,
// 1xx, close-delimited bodies, keep-alive), and on release the connection is
// kept only when HTTP allows it. A kept connection is probed before reuse (an
// upstream that closed it while idle costs a re-dial, not a 502), and an
// idempotent or retryable request whose reused connection died before any
// response byte is sent once more on a fresh one. Deadlines (connect + TLS,
// then the response) and idle / lifetime expiry run from the pool's
// maintenance timer (start_maintenance, from on_worker_start); a Resolver
// thread can follow DNS changes. Nothing is allocated per exchange once the
// slot buffers reach their high-water mark.
//
// One exchange per parked request: do not start a second exchange from a
// continuation (on a client that disconnected meanwhile, the runtime only
// re-arms the fd the continuation woke on, so a watch on another pool's fd
// would never fire).
//
// Platform: the Linux epoll plaintext worker (the one that parks requests and
// runs on_worker_start). Run TLS-terminating workers in front, as for
// pg_async. TLS needs the `-d vanilla_tls` build.
import tls
import time
import transport
import http1_1.client
import core

#include "@VMODROOT/http1_1/upstream/upstream_shim.h"

fn C.upstream_dup_onto(fd int, onto int) int
fn C.upstream_send(fd int, p1 voidptr, n1 usize, p2 voidptr, n2 usize) i64
fn C.upstream_recv(fd int, p voidptr, n usize) i64
fn C.upstream_peek(fd int) int
fn C.close(fd int) int
fn C.shutdown(fd int, how int) int

// Origin is one upstream server and the limits its pool keeps to.
pub struct Origin {
pub:
	// host is the name dialed, sent as the Host header, and — over HTTPS — the
	// SNI and the name the certificate must carry (tls.Verify.full). An IPv4
	// or IPv6 literal is dialed as is (plain HTTP only, for now: tls sends no
	// SNI for it and checks it against iPAddress SANs since #233, but this
	// pool has no HTTPS-to-IP tests yet).
	host  string
	port  int  = 443
	https bool = true // false: plain HTTP (an internal or link-local endpoint)
	// max_conns is this worker's connection cap for the origin: acquire()
	// answers none past it (shed with 503).
	max_conns int = 8
	// connect_timeout_ms bounds the TCP connect plus the TLS handshake;
	// response_timeout_ms the wait from the connection being ready to the last
	// byte of the response. Enforced by the maintenance timer.
	connect_timeout_ms  int = 3000
	response_timeout_ms int = 15_000
	// idle_timeout_ms closes a connection idle this long: keep it below the
	// provider's own keep-alive timeout, so the provider never closes first.
	idle_timeout_ms int = 20_000
	// max_lifetime_ms retires a connection this old at its next release (or
	// idle tick), so the pool follows DNS changes.
	max_lifetime_ms    int = 300_000
	max_request_bytes  int = 1 << 20 // head + body; larger requests fail with .invalid
	max_response_bytes int = 1 << 20 // larger responses fail with .too_large
	// tcp tunes every dialed socket (TCP_NODELAY, keepalive, TCP_USER_TIMEOUT).
	tcp transport.TcpOpts
	// resolve maps host:port to addresses, at Pool.new and on a Resolver's
	// thread (never on a worker); nil: the system resolver (getaddrinfo).
	resolve ResolveFn = unsafe { nil }
}

// ResolveFn resolves host:port to the addresses to dial, in order: empty when
// it cannot. It runs at startup and on a Resolver's thread, so it may block
// and allocate.
pub type ResolveFn = fn (host string, port int) []transport.Addr

// Poll is where an exchange stands after send() / advance().
pub enum Poll {
	pending // a watch is armed: return .suspend; the continuation calls advance()
	ready   // the response is complete: status(), header_value(), body_view()
	failed  // failure() says why; answer (502 / 504) and release()
}

// Failure is why an exchange failed.
pub enum Failure {
	none_
	invalid    // refused before sending: a request line or header that would inject a line, an over-long request, or a worker that cannot park
	dns        // no address to dial
	connect    // every address refused or was unreachable
	tls_verify // the server's certificate failed verification
	tls        // the TLS handshake failed otherwise
	send       // the connection failed while the request was being sent
	closed     // the connection closed before any byte of the response
	truncated  // the connection closed mid-response (over TLS, also: a close-delimited body without close_notify)
	timeout    // connect_timeout_ms or response_timeout_ms passed
	malformed  // the response is not valid HTTP/1.1
	too_large  // the response is larger than max_response_bytes
}

enum Phase {
	idle       // no exchange: the slot's connection (fd >= 0) sits in the pool, or there is none
	connecting // the TCP connect is in flight
	handshake  // the TLS handshake
	sending    // writing the request
	reading    // reading the response
	ready      // the response is complete
	failed     // failure says why
}

// io results of write_some / read_some besides a byte count.
const io_again = -1 // nothing can move now: wait for the socket (wait_write says which way)
const io_eof = -2 // the peer closed (over TLS: see Exchange.close_notify)
const io_failed = -3 // reset, or a TLS error
const io_answered = -4 // write_some: the server answered before the request was sent

// max_addrs bounds the addresses an origin keeps (a resolver answer's tail is dropped).
const max_addrs = 16

// Stats counts what a pool did, for tests and metrics.
pub struct Stats {
pub mut:
	dials    u64 // TCP connects started
	reuses   u64 // exchanges sent on a kept connection
	retries  u64 // requests sent again on a fresh connection
	timeouts u64 // exchanges failed by a deadline
	probes   u64 // kept connections found closed (or unusable) before reuse
}

// Pool is one origin's connections on one worker. Build it in make_state
// (Pool.new) and keep it in the worker state; it must outlive the worker.
@[heap]
pub struct Pool {
mut:
	origin    Origin
	tls_cfg   &tls.Config = unsafe { nil }
	host_hdr  []u8 // 'Host: <host>[:<port>]\r\n', built once
	slots     []&Exchange
	addrs     []transport.Addr // the addresses to dial, max_addrs capacity
	cursor    int              // where the next dial starts in addrs
	staging   []transport.Addr // a resolver update being received
	stage_seq u32
	// maintenance (maintenance_*.c.v) and the resolver hand-off (resolver.v)
	timer_fd  int = -1
	timer_due u64 // monotonic ns the timer is armed for (0: not armed)
	feed_fd   int       = -1 // the resolver pipe's read end (follow)
	resolver  &Resolver = unsafe { nil }
	sub_id    int       = -1
	closed    bool
pub mut:
	stats Stats
}

// Exchange is one pooled connection and the request / response on it while a
// handler holds it (acquire() to release()). Views it returns (header_value,
// body_view) borrow its buffer: copy what must outlive release().
@[heap]
pub struct Exchange {
mut:
	pool  &Pool = unsafe { nil }
	fd    int   = -1
	sess  tls.Session
	phase Phase
	busy  bool
	// the connection
	born       u64 // monotonic ns it was dialed
	idle_since u64
	served     int // exchanges completed on it: > 0 is a kept connection
	// the request
	head       []u8
	body       []u8
	head_ok    bool
	invalid    bool
	is_head    bool
	idempotent bool
	retry_ok   bool
	retried    bool
	conn_close bool // the request said `Connection: close`
	no_reuse   bool // the exchange went in a way that leaves the connection unusable
	off        int  // bytes of head + body written
	tls_wlen   int  // a TLS record to retry with the same length
	wait_write bool // io_again: the socket must turn writable (else readable)
	dials      int  // addresses tried for this exchange
	base       int  // the pool's cursor when it started: where its first dial went
	addr_i     int  // the address of the connect in flight
	limit      u64  // a retry's bound: the original deadline (0: none)
	// the response
	resp      []u8
	framer    client.Framer
	end       int
	eof       bool
	failure   Failure
	timed_out bool
	deadline  u64 // monotonic ns; 0: none
}

// Pool.new builds an origin's pool for this worker: validates the origin,
// resolves it (blocking — make_state runs before the worker serves; a Resolver
// refreshes it later off the worker), and allocates every slot's buffers.
// `tls_cfg` is the client TLS config for an HTTPS origin (tls.new_client), and
// may be shared by every worker's pools: it is only read. nil for plain HTTP.
pub fn Pool.new(o Origin, tls_cfg &tls.Config) !&Pool {
	if !valid_host(o.host) {
		return error('upstream: invalid host "${o.host}"')
	}
	if o.port < 1 || o.port > 65535 {
		return error('upstream: invalid port ${o.port}')
	}
	if o.max_conns < 1 {
		return error('upstream: max_conns must be >= 1')
	}
	literal := transport.ip_addr(o.host, o.port)
	if o.https {
		if tls_cfg == unsafe { nil } {
			return error('upstream: an HTTPS origin needs a client TLS config (tls.new_client)')
		}
		if literal != none {
			return error('upstream: HTTPS to an IP literal (${o.host}) is not supported yet: use a host name')
		}
	}
	mut p := &Pool{
		origin:  o
		tls_cfg: unsafe { tls_cfg } // read-only, outlives the pool (the caller's)
		addrs:   []transport.Addr{cap: max_addrs}
		staging: []transport.Addr{cap: max_addrs}
	}
	if a := literal {
		p.addrs << a
	} else {
		found := if o.resolve != unsafe { nil } {
			o.resolve(o.host, o.port)
		} else {
			resolve_system(o.host,
				o.port)
		}
		for a in found {
			if p.addrs.len < max_addrs {
				p.addrs << a
			}
		}
		if p.addrs.len == 0 {
			return error('upstream: cannot resolve ${o.host}:${o.port}')
		}
	}
	// Host = uri-host [ ":" port ] (RFC 9110 §7.2): the port only when it is
	// not the scheme's default, an IPv6 literal in brackets.
	mut h := []u8{cap: 16 + o.host.len}
	h << 'Host: '.bytes()
	v6 := o.host.contains(':')
	if v6 {
		h << `[`
	}
	h << o.host.bytes()
	if v6 {
		h << `]`
	}
	if o.port != if o.https { 443 } else { 80 } {
		h << `:`
		h << o.port.str().bytes()
	}
	h << '\r\n'.bytes()
	p.host_hdr = h
	for _ in 0 .. o.max_conns {
		p.slots << &Exchange{
			pool: p
			head: []u8{cap: 1024}
			resp: []u8{cap: 16 * 1024}
		}
	}
	return p
}

// valid_host reports whether s can be the origin's host: a DNS name or an IP
// literal, visible ASCII, nothing that would end the Host header or the
// authority early.
fn valid_host(s string) bool {
	if s.len == 0 || s.len > 253 {
		return false
	}
	for c in s {
		if c <= 0x20 || c >= 0x7f || c == `/` || c == `?` || c == `#` || c == `@` || c == `[`
			|| c == `]` || c == `,` || c == `\\` {
			return false
		}
	}
	return true
}

// acquire takes a free slot for one exchange: a kept connection that is still
// usable (probed now: closed while idle, or past max_lifetime_ms, it is
// dropped and the slot re-dials), else one with no connection. none when all
// max_conns are in use: shed the request (503).
pub fn (mut p Pool) acquire() ?&Exchange {
	now := time.sys_mono_now()
	lifetime := u64(p.origin.max_lifetime_ms) * u64(time.millisecond)
	mut empty := -1
	for i, mut x in p.slots {
		if x.busy {
			continue
		}
		if x.fd >= 0 {
			if now - x.born < lifetime && x.idle_alive() {
				x.start()
				p.stats.reuses++
				return x
			}
			p.stats.probes++
			x.drop_conn()
		}
		if empty < 0 {
			empty = i
		}
	}
	if empty < 0 {
		return none
	}
	mut x := p.slots[empty]
	x.start()
	return x
}

// exchange_of maps a continuation's ready_fd back to the exchange parked on it.
pub fn (mut p Pool) exchange_of(fd int) ?&Exchange {
	for mut x in p.slots {
		if x.busy && x.fd == fd {
			return x
		}
	}
	return none
}

// start resets the slot's per-exchange state, keeping every buffer's capacity.
fn (mut x Exchange) start() {
	x.busy = true
	x.phase = .idle
	x.head.clear()
	x.body.clear()
	x.resp.clear()
	x.head_ok = false
	x.invalid = false
	x.is_head = false
	x.idempotent = false
	x.retry_ok = false
	x.retried = false
	x.conn_close = false
	x.no_reuse = false
	x.off = 0
	x.tls_wlen = 0
	x.wait_write = false
	x.dials = 0
	x.limit = 0
	x.end = 0
	x.eof = false
	x.failure = .none_
	x.timed_out = false
	x.deadline = 0
}

// idle_alive probes a kept connection without blocking: false if the upstream
// closed it, reset it, or sent bytes nobody asked for (an idle HTTP/1.1
// connection carries none). Over TLS the bytes are read through the session:
// a raw peek sees ciphertext (a TLS 1.3 ticket, a close_notify alert), and a
// ticket is consumed there.
fn (mut x Exchange) idle_alive() bool {
	if x.sess.active() {
		x.sess.mark_readable()
		mut b := [16]u8{}
		n := x.sess.read_into(&b[0], b.len)
		return n == tls.want || n == tls.want_write
	}
	return C.upstream_peek(x.fd) == -1
}

// drop_conn closes the slot's connection, first detaching its TLS session so
// nothing it does later can reach that fd number once the kernel reuses it.
fn (mut x Exchange) drop_conn() {
	if x.fd >= 0 {
		if x.sess.active() {
			x.sess.reset(-1)
		}
		C.close(x.fd)
		x.fd = -1
	}
	x.served = 0
}

const idempotent_methods = ['GET', 'HEAD', 'OPTIONS', 'TRACE', 'PUT', 'DELETE']

// request starts the request: `method` (a token, e.g. 'GET') and `target`
// (origin-form, e.g. '/v1/charges?limit=3'; visible ASCII only). false — and
// the exchange fails with .invalid at send() — if either would inject a line.
pub fn (mut x Exchange) request(method string, target string) bool {
	x.head.clear()
	x.head_ok = false
	if !client.valid_token(method) || !client.valid_target(target) {
		x.invalid = true
		return false
	}
	core.append_str(mut x.head, method)
	x.head << ` `
	core.append_str(mut x.head, target)
	core.append_str(mut x.head, ' HTTP/1.1\r\n')
	x.head << x.pool.host_hdr
	x.is_head = method == 'HEAD'
	x.idempotent = method in idempotent_methods
	x.head_ok = true
	return true
}

// header adds a field line: `name` a token, `value` with no CR, LF, NUL or
// other control byte (HTAB aside). false — and the exchange fails with
// .invalid at send() — otherwise, or for the fields the client owns: Host
// (from the origin), Content-Length (from body()) and Transfer-Encoding.
pub fn (mut x Exchange) header(name string, value []u8) bool {
	if !x.head_ok || !client.valid_token(name) || !client.valid_field_value(value)
		|| eq_ci(name, 'host') || eq_ci(name, 'content-length')
		|| eq_ci(name, 'transfer-encoding') {
		x.invalid = true
		return false
	}
	if eq_ci(name, 'connection') && has_ci(value, 'close') {
		x.conn_close = true
	}
	core.append_str(mut x.head, name)
	core.append_str(mut x.head, ': ')
	x.head << value
	core.append_str(mut x.head, '\r\n')
	return true
}

// body is the request body buffer: append the content in place (its
// Content-Length is set at send()).
pub fn (mut x Exchange) body() &[]u8 {
	return &x.body
}

// retryable marks a request that is safe to send twice although its method is
// not idempotent (e.g. a POST carrying an Idempotency-Key): when its kept
// connection turns out to be dead before any response byte, it is sent once
// more on a fresh connection. Idempotent methods are retryable already.
pub fn (mut x Exchange) retryable(yes bool) {
	x.retry_ok = yes
}

// status is the response's status code (.ready).
pub fn (x &Exchange) status() int {
	return x.framer.status
}

// header_value is the value of the response's first `name` field (lowercase
// name), as a view into the exchange's buffer; empty when absent. Valid until
// release().
pub fn (x &Exchange) header_value(name string) []u8 {
	s, l := x.framer.header_value(x.resp, name)
	if s < 0 || l == 0 {
		return client.no_body
	}
	return unsafe { (&u8(x.resp.data) + s).vbytes(l) }
}

// body_view is the response body, decoded (a chunked body is de-chunked in
// place), as a view into the exchange's buffer. Valid until release().
pub fn (mut x Exchange) body_view() []u8 {
	if x.phase != .ready {
		return client.no_body
	}
	return x.framer.body_in_place(mut x.resp)
}

// failure says why the exchange failed (.none_ unless it did).
pub fn (x &Exchange) failure() Failure {
	return x.failure
}

// release ends the exchange: the connection stays pooled when HTTP allows it
// (the response said keep-alive and was framed by length or chunks, nothing
// arrived behind it, the request did not ask to close, it did not fail or time
// out, and it is younger than max_lifetime_ms); otherwise it is closed. Call
// it once send() or advance() returned .ready or .failed, on every path.
pub fn (mut x Exchange) release() {
	if !x.busy {
		return
	}
	now := time.sys_mono_now()
	keep := x.phase == .ready && x.fd >= 0 && x.framer.keep_alive && !x.eof && !x.no_reuse
		&& x.end == x.resp.len && !x.conn_close && !x.timed_out
		&& now - x.born < u64(x.pool.origin.max_lifetime_ms) * u64(time.millisecond)
	if keep {
		x.served++
		x.idle_since = now
	} else {
		x.drop_conn()
	}
	x.busy = false
	x.phase = .idle
	x.deadline = 0
	x.limit = 0
}

// eq_ci reports whether s equals `lower` (lowercase), ignoring ASCII case.
fn eq_ci(s string, lower string) bool {
	if s.len != lower.len {
		return false
	}
	for i in 0 .. s.len {
		mut c := s[i]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != lower[i] {
			return false
		}
	}
	return true
}

// has_ci reports whether v contains `lower` (lowercase), ignoring ASCII case.
fn has_ci(v []u8, lower string) bool {
	if v.len < lower.len {
		return false
	}
	for i in 0 .. v.len - lower.len + 1 {
		mut ok := true
		for j in 0 .. lower.len {
			mut c := v[i + j]
			if c >= `A` && c <= `Z` {
				c += 32
			}
			if c != lower[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
