// Connection reaping over HTTPS on the epoll TLS worker: a silent TCP connect,
// a stalled handshake, an idle keep-alive connection (after a synchronous
// send, and after a parked response drains), a partial request and a request
// trickled one byte at a time must all be closed by the server's own
// deadlines (Limits), silently — and a connection inside its idle window, or
// with idle reaping opted out, must keep working. These are the TLS twins of
// the check_* reaping scenarios in backend_behaviors_test.v.
//
// Only built with `-d vanilla_tls` on Linux (the TLS worker is the epoll
// backend's; Mbed TLS is opt-in): in a default build every test is a no-op.
//
//   v -cc gcc -d vanilla_tls test tests/tls_timeouts_test.v
//
// Clients: vtest for the raw-TCP cases (no TLS bytes need to flow), and vlib
// net.openssl for a real TLS client. Not net.mbedtls: its bundled Mbed TLS
// objects clash with the system -lmbedtls the server links. The only clocks
// that decide an outcome are the server's; the openssl client's read timeout
// is a hang backstop (a regression fails the elapsed assert instead of
// blocking forever) or, in the trickle test, the attacker's pacing, and the
// stopwatches MEASURE server-clock events after they completed.
import os
import time
import net
import net.openssl
import server
import core
import tls
import vtest

#include <openssl/pem.h>

fn C.BIO_new_mem_buf(buf voidptr, len int) &C.BIO
fn C.PEM_read_bio_X509(bp &C.BIO, x voidptr, cb voidptr, u voidptr) &C.X509

const tt_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
// A request head that stops mid-header (never completes on its own) and the
// bytes that complete it.
const tt_partial_head = 'GET / HTTP/1.1\r\nHo'.bytes()
const tt_head_tail = 'st: x\r\n\r\n'.bytes()
const tt_ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
// GET /big answers with a body larger than loopback can absorb while the
// client is not reading (see tt_unbufferable_len), so the TLS worker must park
// the response and drain it on EPOLLOUT.
const tt_big_req = 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const tt_big_len = tt_unbufferable_len()
const tt_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: ${tt_big_len}\r\nConnection: keep-alive\r\n\r\n'.bytes()
// A TLS handshake record header announcing a 200-byte ClientHello, followed by
// a single byte of it: the handshake can never progress.
const tt_truncated_client_hello = [u8(0x16), 0x03, 0x01, 0x00, 0xc8, 0x01]
// A complete request head, trickled one byte per tt_trickle_gap.
const tt_trickle_head = 'GET / HTTP/1.1\r\nHost: x\r\nUser-Agent: slow\r\n\r\n'.bytes()
const tt_trickle_gap = time.Duration(100 * time.millisecond)
// Hang backstop for the openssl client only (see the header).
const tt_backstop = time.Duration(5 * time.second)
// Every reap below is budgeted a few hundred ms (the trickle test 1000 ms);
// this bound leaves room for one sweep interval (at most 250 ms) plus
// scheduling, and stays far below the backstop.
const tt_reap_bound_ms = 1500

const tt_silent_script = vtest.Script{
	rounds:   [
		vtest.Round{
			send: []u8{}
			want: 0
		},
	]
	then_eof: true
}

fn tt_ok_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.len > 5 && req[5] == `b` { // GET /big
		res << tt_big_head
		old := res.len
		unsafe {
			res.grow_len(tt_big_len)
			vmemset(&res[old], `x`, tt_big_len)
		}
		return .done
	}
	res << tt_ok_response
	return .done
}

// tt_unbufferable_len is a body size loopback cannot hold while the client is
// not reading: more than the largest send buffer plus the largest receive
// buffer TCP autotuning may grow to (the last field of tcp_wmem / tcp_rmem;
// nothing here sets SO_SNDBUF/SO_RCVBUF). Record and skb overhead only shrink
// what fits, so the TLS worker is certain to hit WANT_WRITE and park — also
// on hosts with raised maxima, where a fixed size would be sent at once.
fn tt_unbufferable_len() int {
	mut n := 1 << 20
	for f in ['/proc/sys/net/ipv4/tcp_wmem', '/proc/sys/net/ipv4/tcp_rmem'] {
		mem := (os.read_file(f) or { '' }).fields() // min default max
		n += if mem.len == 3 { mem[2].int() } else { 32 << 20 }
	}
	return n
}

// tt_openssl_parses reports whether OpenSSL (the test client) accepts the
// PEM certificate.
fn tt_openssl_parses(pem string) bool {
	bio := C.BIO_new_mem_buf(pem.str, pem.len)
	if bio == unsafe { nil } {
		return false
	}
	x := C.PEM_read_bio_X509(bio, unsafe { nil }, unsafe { nil }, unsafe { nil })
	C.BIO_free_all(bio)
	if x == unsafe { nil } {
		return false
	}
	C.X509_free(x)
	return true
}

// tt_tls_config is a fresh self-signed identity the openssl client can parse.
// tls.new_self_signed draws a random 12-byte serial and encodes it as is; when
// it starts with 0x00 and a byte < 0x80 the DER INTEGER is not minimal (about
// 1 certificate in 500), and OpenSSL 3 fails the handshake on it ("illegal
// padding") before any timeout logic runs. Draw again rather than flake.
fn tt_tls_config() !&tls.Config {
	for _ in 0 .. 8 {
		cfg := tls.new_self_signed()!
		if tt_openssl_parses(cfg.cert_pem()) {
			return cfg
		}
		cfg.free()
	}
	return error('tls.new_self_signed: no certificate OpenSSL can parse in 8 draws')
}

// tt_start serves tt_ok_handler over HTTPS on one epoll TLS worker. (`.epoll`
// exists only on Linux, hence the gate.)
fn tt_start(limits server.Limits) !&vtest.Harness {
	$if linux {
		return vtest.start(server.ServerConfig{
			io_multiplexing: .epoll
			workers:         1
			tls_config:      tt_tls_config()!
			handler:         tt_ok_handler
			limits:          limits
		})
	} $else {
		return error('the TLS worker is the Linux epoll backend')
	}
}

// --- openssl client helpers (return values; asserts stay in the scenario fn,
// docs/VTEST.md rule 1) -------------------------------------------------------

// tt_dial completes a TLS handshake with the server (self-signed: not
// validated). The backstop is set after dial: connect() resets the read
// timeout to the TCP default (30s), which is the handshake's own backstop.
fn tt_dial(port int) !&openssl.SSLConn {
	mut c := openssl.new_ssl_conn(validate: false)!
	c.dial('127.0.0.1', port)!
	c.set_read_timeout(tt_backstop)
	return c
}

// tt_write sends all of `bytes`.
fn tt_write(mut c openssl.SSLConn, bytes []u8) ! {
	c.write(bytes)!
}

// tt_read_response reads until one complete tt_ok_response arrived.
fn tt_read_response(mut c openssl.SSLConn) !string {
	mut acc := []u8{}
	mut buf := []u8{len: 4096}
	for acc.len < tt_ok_response.len {
		n := c.read(mut buf)!
		if n <= 0 {
			return error('closed after ${acc.len} bytes: ${acc.bytestr()}')
		}
		acc << buf[..n]
	}
	return acc.bytestr()
}

// tt_read_n reads exactly n bytes of plaintext (fewer only if the connection
// ends first) and returns how many arrived.
fn tt_read_n(mut c openssl.SSLConn, n int) int {
	mut got := 0
	mut buf := []u8{len: 64 * 1024}
	for got < n {
		k := c.read(mut buf) or { break }
		if k <= 0 {
			break
		}
		got += k
	}
	return got
}

// tt_get sends one request and returns its response.
fn tt_get(mut c openssl.SSLConn) !string {
	tt_write(mut c, tt_req)!
	return tt_read_response(mut c)
}

// tt_read_until_close reads until the server closes the connection (or the
// backstop fires — the caller's elapsed assert tells them apart) and returns
// whatever plaintext arrived first.
fn tt_read_until_close(mut c openssl.SSLConn) string {
	mut acc := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := c.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		acc << buf[..n]
	}
	return acc.bytestr()
}

// tt_stays_open waits `d` for the server to close the connection and reports
// whether it stayed open (nothing arrived, the read timed out).
fn tt_stays_open(mut c openssl.SSLConn, d time.Duration) bool {
	c.set_read_timeout(d)
	defer {
		c.set_read_timeout(tt_backstop)
	}
	mut buf := []u8{len: 64}
	c.read(mut buf) or { return err.code() == net.err_timed_out_code }
	return false
}

// tt_trickle writes `bytes` one byte (one TLS record) per tt_trickle_gap — a
// slowloris. The gap is spent in a read, so a server close is seen as soon as
// it lands and is never followed by a second write. Returns how many bytes
// were written when the connection ended (bytes.len if it never did during
// the trickle) and any plaintext the server answered with.
fn tt_trickle(mut c openssl.SSLConn, bytes []u8) (int, string) {
	c.set_read_timeout(tt_trickle_gap)
	defer {
		c.set_read_timeout(tt_backstop)
	}
	mut buf := []u8{len: 4096}
	for i in 0 .. bytes.len {
		c.write(bytes[i..i + 1]) or { return i, '' }
		n := c.read(mut buf) or {
			if err.code() == net.err_timed_out_code {
				continue // still open: next byte
			}
			return i + 1, ''
		}
		return i + 1, buf[..n].bytestr()
	}
	return bytes.len, ''
}

fn tt_close(mut c openssl.SSLConn) {
	c.shutdown() or {}
}

// --- scenarios ---------------------------------------------------------------

// A TCP connection that never sends a byte (no ClientHello) is reaped by the
// accept-time deadline: read_timeout_ms, or the idle budget when only
// idle_timeout_ms is set.
fn check_tls_silent_connect(limits server.Limits) ! {
	mut h := tt_start(limits)!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([tt_silent_script])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, 'a silent TLS connection must be closed by the accept-time deadline'
	assert c.raw.len == 0, 'a peer that never spoke must be closed without a response, got ${c.raw.len} bytes'
	assert elapsed < tt_reap_bound_ms, 'silent connection should be reaped promptly, took ${elapsed}ms'
}

// A handshake that stalls (a ClientHello record that never completes) is
// bounded by the accept-time read deadline.
fn check_tls_stalled_handshake() ! {
	mut h := tt_start(server.Limits{
		read_timeout_ms: 400
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: tt_truncated_client_hello
					want: 0
				},
			]
			then_eof: true
		},
	])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, 'a stalled TLS handshake must be closed by the accept-time deadline'
	// Silent: with no complete ClientHello there is no ServerHello to send,
	// and Mbed TLS sends no close_notify before the handshake is over.
	assert c.raw.len == 0, 'a stalled handshake must be closed without a reply, got ${c.raw.len} bytes'
	assert elapsed < tt_reap_bound_ms, 'stalled handshake should be reaped promptly, took ${elapsed}ms'
}

// After a served request, a keep-alive TLS connection whose peer goes quiet
// is closed silently once the idle deadline passes.
fn check_tls_idle_keepalive(limits server.Limits) ! {
	mut h := tt_start(limits)!
	defer {
		h.stop()
	}
	mut c := tt_dial(h.port())!
	defer {
		tt_close(mut c)
	}
	resp := tt_get(mut c)!
	assert resp.starts_with('HTTP/1.1 200'), resp
	sw := time.new_stopwatch()
	after := tt_read_until_close(mut c)
	elapsed := sw.elapsed().milliseconds()
	assert after == '', 'an idle close must be silent, got: ${after}'
	assert elapsed < tt_reap_bound_ms, 'idle TLS connection should be reaped promptly, took ${elapsed}ms (${tt_backstop.milliseconds()}ms = not reaped)'
}

// The production lockout: silent connections fill max_connections; once
// their accept-time deadlines reap them, a TLS request must be SERVED, not
// refused at accept.
fn check_tls_reaped_slots_free_max_connections() ! {
	mut h := tt_start(server.Limits{
		max_connections: 2
		read_timeout_ms: 300
	})!
	defer {
		h.stop()
	}
	silent := h.fire(vtest.repeat(2, tt_silent_script))!
	for i, s in silent.conns {
		assert s.connect_err == '', s.connect_err
		assert s.eof, 'silent conn ${i} must be reaped'
	}
	mut c := tt_dial(h.port())!
	defer {
		tt_close(mut c)
	}
	resp := tt_get(mut c)!
	assert resp.starts_with('HTTP/1.1 200'), 'reaped connections must free their max_connections slots, got: ${resp}'
}

// Keep-alive inside the idle window: the idle deadline armed after response 1
// is cleared by the first plaintext byte of request 2, which then runs on its
// own (longer) read deadline. The witness is the server's clock: connection
// B's idle reap (300ms after ITS response, which comes after A sent part of
// request 2) proves A outlived its own idle deadline — A must still be served.
fn check_tls_keepalive_within_idle() ! {
	mut h := tt_start(server.Limits{
		read_timeout_ms: 3000
		idle_timeout_ms: 300
	})!
	defer {
		h.stop()
	}
	mut a := tt_dial(h.port())!
	defer {
		tt_close(mut a)
	}
	first := tt_get(mut a)!
	assert first.starts_with('HTTP/1.1 200'), first
	tt_write(mut a, tt_partial_head)!
	mut b := tt_dial(h.port())!
	defer {
		tt_close(mut b)
	}
	witness := tt_get(mut b)!
	assert witness.starts_with('HTTP/1.1 200'), witness
	sw := time.new_stopwatch()
	b_after := tt_read_until_close(mut b)
	b_elapsed := sw.elapsed().milliseconds()
	assert b_after == ''
	assert b_elapsed < tt_reap_bound_ms, 'the idle witness must be reaped, took ${b_elapsed}ms'
	tt_write(mut a, tt_head_tail)!
	second := tt_read_response(mut a) or {
		assert false, 'a request started inside the idle window must be served, the read ended with "${err}" (empty = EOF)'
		return
	}
	assert second.starts_with('HTTP/1.1 200'), second
	third := tt_get(mut a)!
	assert third.starts_with('HTTP/1.1 200'), 'keep-alive must keep serving, got: ${third}'
}

// A response too large for the socket buffers is parked and drained on
// EPOLLOUT; the idle deadline must be armed when that drain completes (not
// only on the synchronous send path), and never while the response is parked.
// The client does not read until a silent witness has been reaped by the
// server's accept-time deadline — by then the response has long been parked
// with nothing armed on it but write_timeout_ms (0 here). Then it reads the
// whole response and goes quiet: the idle deadline must reap it.
fn check_tls_idle_after_parked_drain() ! {
	mut h := tt_start(server.Limits{
		read_timeout_ms: 300
	})!
	defer {
		h.stop()
	}
	mut c := tt_dial(h.port())!
	defer {
		tt_close(mut c)
	}
	tt_write(mut c, tt_big_req)!
	witness := h.fire([tt_silent_script])!
	assert witness.conns[0].eof, 'the silent witness must be reaped by read_timeout_ms'
	want := tt_big_head.len + tt_big_len
	got := tt_read_n(mut c, want)
	assert got == want, 'a parked response must not be reaped before it drains: got ${got} of ${want} bytes'
	sw := time.new_stopwatch()
	after := tt_read_until_close(mut c)
	elapsed := sw.elapsed().milliseconds()
	assert after == '', 'an idle close must be silent, got ${after.len} bytes'
	assert elapsed < tt_reap_bound_ms, 'idle must be armed once a parked response drains, took ${elapsed}ms (${tt_backstop.milliseconds()}ms = not reaped)'
}

// idle_timeout_ms: -1 opts out of idle reaping even with a read timeout set.
// The witness is a silent connection fired after A went idle: its accept-time
// read deadline fires at least read_timeout_ms later, and A must still serve
// its next request.
fn check_tls_idle_opt_out() ! {
	mut h := tt_start(server.Limits{
		read_timeout_ms: 400
		idle_timeout_ms: -1
	})!
	defer {
		h.stop()
	}
	mut a := tt_dial(h.port())!
	defer {
		tt_close(mut a)
	}
	first := tt_get(mut a)!
	assert first.starts_with('HTTP/1.1 200'), first
	witness := h.fire([tt_silent_script])!
	assert witness.conns[0].eof, 'the silent witness must still be reaped by read_timeout_ms'
	second := tt_get(mut a) or {
		assert false, 'idle_timeout_ms: -1 must keep an idle TLS connection open, the read ended with "${err}" (empty = EOF)'
		return
	}
	assert second.starts_with('HTTP/1.1 200'), second
}

// A partial HTTP head over an established TLS connection is still reaped by
// read_timeout_ms, silently — for the first request (the deadline armed at
// accept) and for a later one (armed at its first byte; idle is opted out so
// only the read deadline can fire).
fn check_tls_partial_request(limits server.Limits, served_first bool) ! {
	mut h := tt_start(limits)!
	defer {
		h.stop()
	}
	mut c := tt_dial(h.port())!
	defer {
		tt_close(mut c)
	}
	if served_first {
		resp := tt_get(mut c)!
		assert resp.starts_with('HTTP/1.1 200'), resp
	}
	sw := time.new_stopwatch()
	tt_write(mut c, tt_partial_head)!
	after := tt_read_until_close(mut c)
	elapsed := sw.elapsed().milliseconds()
	assert after == '', 'a partial request over TLS must be closed silently, got: ${after}'
	assert elapsed < tt_reap_bound_ms, 'partial TLS request should be reaped promptly, took ${elapsed}ms (${tt_backstop.milliseconds()}ms = not reaped)'
}

// A request trickled one byte at a time is still cut at read_timeout_ms: the
// read deadline is never refreshed by progress. For the first request
// (served_first false) it is the deadline armed at accept, which the
// handshake does not clear — the client waits most of the budget before its
// first byte, so a clock that only started at that byte would run past the
// bound. For a later request it starts at the first byte (idle is opted out,
// so only the read deadline can fire).
fn check_tls_trickled_request(served_first bool) ! {
	mut h := tt_start(server.Limits{
		read_timeout_ms: 1000
		idle_timeout_ms: -1
	})!
	defer {
		h.stop()
	}
	mut c := tt_dial(h.port())!
	defer {
		tt_close(mut c)
	}
	if served_first {
		resp := tt_get(mut c)!
		assert resp.starts_with('HTTP/1.1 200'), resp
	}
	sw := time.new_stopwatch()
	if !served_first {
		assert tt_stays_open(mut c, 800 * time.millisecond), 'the accept-time deadline must not fire before read_timeout_ms'
	}
	sent, reply := tt_trickle(mut c, tt_trickle_head)
	elapsed := sw.elapsed().milliseconds()
	assert sent < tt_trickle_head.len, 'progress must not refresh the read deadline: the whole ${sent}-byte head was trickled in, reply: ${reply}'
	assert reply == '', 'a trickled request must be closed silently, got: ${reply}'
	assert elapsed < tt_reap_bound_ms, 'a trickled TLS request should be reaped at read_timeout_ms, took ${elapsed}ms'
}

// --- tests -------------------------------------------------------------------

fn test_tls_silent_connect_reaped() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_silent_connect(server.Limits{
				read_timeout_ms: 400
			})!
			check_tls_silent_connect(server.Limits{
				idle_timeout_ms: 400
			})!
		}
	}
}

fn test_tls_stalled_handshake_reaped() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_stalled_handshake()!
		}
	}
}

fn test_tls_idle_keepalive_reaped() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_idle_keepalive(server.Limits{
				read_timeout_ms: 400
			})!
			check_tls_idle_keepalive(server.Limits{
				idle_timeout_ms: 400
			})!
		}
	}
}

fn test_tls_reaped_slots_free_max_connections() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_reaped_slots_free_max_connections()!
		}
	}
}

fn test_tls_keepalive_within_idle_window() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_keepalive_within_idle()!
		}
	}
}

fn test_tls_idle_after_parked_drain() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_idle_after_parked_drain()!
		}
	}
}

fn test_tls_idle_opt_out() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_idle_opt_out()!
		}
	}
}

fn test_tls_partial_request_reaped() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_partial_request(server.Limits{
				read_timeout_ms: 400
			}, false)!
			check_tls_partial_request(server.Limits{
				read_timeout_ms: 400
				idle_timeout_ms: -1
			}, true)!
		}
	}
}

fn test_tls_trickled_request_reaped() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_trickled_request(false)!
			check_tls_trickled_request(true)!
		}
	}
}
