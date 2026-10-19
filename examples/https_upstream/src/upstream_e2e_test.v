// vtest build: linux
module main

// End-to-end tests of the http1_1/upstream pooled client (#229), through this
// example's edge server (epoll, one worker) against ../fake_upstream — a
// scriptable fake third-party API written in V, built here and run as its own
// process — over plain HTTP and, built with `-d vanilla_tls`, over TLS 1.3
// with a throwaway test CA (verify-full + SNI). The TLS tests skip without
// openssl (for the test CA) unless VANILLA_REQUIRE_FAKE_PG is set (CI).
import os
import time
import crypto.sha256
import sync.stdatomic
import core
import server
import tls
import testkit
import transport
import vtest
import http1_1.client
import http1_1.upstream

#include <poll.h>

fn C.poll(fds voidptr, n u64, timeout int) int
fn C.recv(fd int, buf voidptr, n usize, flags int) int
fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.listen(fd int, backlog int) int

const fake_src = os.join_path(@DIR, '..', 'fake_upstream', 'main.v')

// Fake is one fake_upstream process.
struct Fake {
mut:
	port  int
	dir   string
	certs string
	proc  &os.Process = unsafe { nil }
}

fn (f &Fake) certs_dir() string {
	return f.certs
}

// fake_bin builds ../fake_upstream (with TLS in a TLS build) with the
// compiler and C compiler that built this test, once per source version: the
// binary is cached under its source hash, so later test runs reuse it.
fn fake_bin() !string {
	src := os.read_file(fake_src)!
	mut flags := ['-no-parallel', '-cc', fake_cc()]
	$if vanilla_tls ? {
		flags << ['-d', 'vanilla_tls']
	}
	key := sha256.hexhash(src + flags.join(' '))[..16]
	bin := os.join_path(os.vtmp_dir(), 'vanilla_fake_upstream_${key}')
	if os.exists(bin) {
		return bin
	}
	tmp := '${bin}.${os.getpid()}'
	res := os.execute('${os.quoted_path(@VEXE)} ${flags.join(' ')} -o ${os.quoted_path(tmp)} ${os.quoted_path(os.dir(fake_src))}')
	if res.exit_code != 0 {
		return error('cannot build fake_upstream: ${res.output}')
	}
	os.mv(tmp, bin)! // atomic: a concurrent build of the same source is the same binary
	return bin
}

fn fake_cc() string {
	$if tinyc {
		return 'tcc'
	} $else $if clang {
		return 'clang'
	}
	return 'gcc'
}

// start_fake starts a fake on 127.0.0.1, serving `cert` over TLS when `certs`
// is set.
fn start_fake(certs string, cert string) !Fake {
	return start_fake_on('127.0.0.1', certs, cert)
}

// start_fake_on is start_fake listening on `ip`.
fn start_fake_on(ip string, certs string, cert string) !Fake {
	return start_fake_args(ip, certs, cert, [])
}

// start_fake_args is start_fake_on with more fake_upstream options. Over TLS
// the fake sends two TLS 1.3 NewSessionTickets after each handshake, as
// OpenSSL-based servers do by default (#236); `extra` may override it.
fn start_fake_args(ip string, certs string, cert string, extra []string) !Fake {
	bin := fake_bin()!
	dir := os.join_path(os.temp_dir(), 'vanilla_fake_upstream_${os.getpid()}_${time.sys_mono_now()}')
	os.mkdir_all(dir)!
	mut p := os.new_process(bin)
	mut a := ['--bind', ip, '--port-file', os.join_path(dir, 'port'), '--stats-file',
		os.join_path(dir, 'stats')]
	if certs != '' {
		a << ['--tls', certs, '--cert', cert, '--tickets', '2']
	}
	a << extra
	p.set_args(a)
	p.run()
	for _ in 0 .. 500 {
		port := (os.read_file(os.join_path(dir, 'port')) or { '' }).int()
		if port > 0 {
			return Fake{
				port:  port
				dir:   dir
				certs: certs
				proc:  p
			}
		}
		if !p.is_alive() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	p.signal_kill()
	return error('fake_upstream did not start')
}

fn (mut f Fake) stop() {
	if f.proc != unsafe { nil } {
		f.proc.signal_kill()
		f.proc.wait()
		f.proc.close()
		f.proc = unsafe { nil }
	}
	os.rmdir_all(f.dir) or {}
}

// stat is one of the fake's counters (accepted, handshakes, held_handshakes,
// tickets, requests, path:<path>), 0 when not seen yet.
fn (f &Fake) stat(key string) int {
	content := os.read_file(os.join_path(f.dir, 'stats')) or { return 0 }
	for line in content.split_into_lines() {
		if line.starts_with(key + '=') {
			return line.all_after('=').int()
		}
	}
	return 0
}

// Env is one test setup: a fake upstream and the edge server relaying to it.
struct Env {
mut:
	fake  Fake
	h     &vtest.Harness = unsafe { nil }
	certs string
	cfg   &tls.Config = unsafe { nil }
}

// variants is the transports to test: plain HTTP, and HTTPS in a TLS build
// (with openssl for the test CA).
fn variants() []bool {
	$if vanilla_tls ? {
		if testkit.test_certs_available() {
			return [false, true]
		}
	}
	return [false]
}

// setup starts the fake (serving `cert` over TLS when https) and an edge whose
// pool uses `o` with the fake's address filled in.
fn setup(https bool, cert string, o upstream.Origin) !Env {
	return setup_limits(https, cert, o, server.Limits{})
}

// setup_limits is setup with the edge's own Limits.
fn setup_limits(https bool, cert string, o upstream.Origin, limits server.Limits) !Env {
	return setup_fake(https, cert, o, limits, [])
}

// setup_fake is setup_limits with more fake_upstream options.
fn setup_fake(https bool, cert string, o upstream.Origin, limits server.Limits, fake_args []string) !Env {
	return setup_handler(https, cert, o, limits, fake_args, edge)
}

// setup_handler is setup_fake with the edge's handler.
fn setup_handler(https bool, cert string, o upstream.Origin, limits server.Limits, fake_args []string, handler core.Handler) !Env {
	mut e := Env{}
	if https {
		e.certs = testkit.test_certs()!
		e.cfg = tls.new_client(os.join_path(e.certs, 'ca.crt'), .full)!
	}
	e.fake = start_fake_args('127.0.0.1', e.certs, cert, fake_args)!
	origin := upstream.Origin{
		...o
		host:  if https { 'localhost' } else { '127.0.0.1' }
		port:  e.fake.port
		https: https
	}
	e.h = start_edge(origin, e.cfg, limits, handler)!
	return e
}

// start_edge starts an edge server (one worker) whose pool goes to `origin`.
fn start_edge(origin upstream.Origin, cfg &tls.Config, limits server.Limits, handler core.Handler) !&vtest.Harness {
	return vtest.start(server.ServerConfig{
		handler:         handler
		workers:         1
		limits:          limits
		on_worker_start: on_worker_start
		make_state:      fn [origin, cfg] () voidptr {
			return new_app(origin, cfg, unsafe { nil })
		}
	})
}

fn (mut e Env) stop() {
	if e.h != unsafe { nil } {
		e.h.stop()
	}
	e.fake.stop()
	if e.certs != '' {
		os.rmdir_all(e.certs) or {}
	}
}

// call sends one raw request to the edge on a fresh connection and returns
// the response (once it frames, or what arrived within wait_ms) and the time
// it took.
fn call(port int, req string, wait_ms int) (string, i64) {
	fd := transport.dial_tcp('127.0.0.1', port) or { return 'dial failed', i64(0) }
	defer {
		transport.close_fd(fd)
	}
	sw := time.new_stopwatch()
	testkit.fd_wait_writable(fd, 1000)
	if !testkit.fd_write_all(fd, req.bytes(), 5000) {
		return 'write failed', sw.elapsed().milliseconds()
	}
	mut acc := []u8{}
	mut buf := []u8{len: 65536}
	read_response(fd, mut acc, mut buf, wait_ms)
	return acc.bytestr(), sw.elapsed().milliseconds()
}

fn get(port int, path string) string {
	r, _ := call(port, 'GET /up${path} HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
	return r
}

// read_response reads one response into acc (cleared) within wait_ms, into a
// reused buffer: no allocation once acc and buf have their capacity.
fn read_response(fd int, mut acc []u8, mut buf []u8, wait_ms int) {
	acc.clear()
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < wait_ms {
		mut p := [2]i32{} // struct pollfd: fd; events | revents << 16
		p[0] = i32(fd)
		p[1] = i32(C.POLLIN)
		if C.poll(voidptr(&p[0]), 1, 20) <= 0 {
			continue
		}
		n := C.recv(fd, buf.data, usize(buf.len), 0)
		if n <= 0 {
			if n < 0 && C.errno == C.EAGAIN {
				continue
			}
			return
		}
		unsafe { acc.push_many(buf.data, n) }
		if client.frame_response(acc) > 0 {
			return
		}
	}
}

// slack widens the upper time bounds under ThreadSanitizer, which slows every
// memory access down.
fn slack() i64 {
	$if race ? {
		return 5
	}
	return 1
}

fn status_of(resp string) int {
	return client.status_code(resp.bytes())
}

fn body_of(resp string) string {
	return resp.all_after('\r\n\r\n')
}

fn failure_of(resp string) string {
	return resp.all_after('X-Upstream-Failure: ').all_before('\r\n')
}

// The <n> of /fill/<n>/ is read in place, with string.int()'s answers: the
// leading digits, 0 without any, saturated at max_fill.
fn test_fill_count_is_read_in_place() {
	for s, want in {
		'16':                   16
		'0':                    0
		'':                     0
		'abc':                  0
		'12x':                  12
		'4194304':              4 << 20
		'2147483647':           max_fill
		'2147483648':           max_fill
		'99999999999999999999': max_fill
	} {
		req := 'POST /fill/${s}/echo HTTP/1.1\r\n'.bytes()
		start := 'POST /fill/'.len
		assert leading_int(req, start, s.len) == want, s
		assert leading_int(req, start, s.len) == s.int(), s
	}
}

// Every response shape comes back with its exact status and decoded body:
// Content-Length, chunked with a trailer, 100 Continue then 201, HEAD, 204, a
// body delimited by the close (over TLS, after close_notify), and a POST body.
fn test_response_shapes() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		mode := if https { 'https' } else { 'http' }
		r1 := get(p, '/ok')
		assert status_of(r1) == 200, '${mode}: ${r1}'
		assert body_of(r1) == '{"status":"paid"}', mode
		assert r1.contains('Content-Type: application/json'), mode
		r2 := get(p, '/chunked')
		assert status_of(r2) == 200 && body_of(r2) == 'hello world', '${mode}: ${r2}'
		r3 := get(p, '/continue')
		assert status_of(r3) == 201 && body_of(r3) == 'ok', '${mode}: ${r3}'
		r4, _ := call(p, 'HEAD /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
		assert status_of(r4) == 200, '${mode}: ${r4}'
		r5 := get(p, '/nocontent')
		assert status_of(r5) == 204, '${mode}: ${r5}'
		r6 := get(p, '/close')
		assert status_of(r6) == 200 && body_of(r6) == 'close-delimited body', '${mode}: ${r6}'
		r7, _ := call(p, 'POST /up/echo HTTP/1.1\r\nHost: edge\r\nContent-Length: 5\r\n\r\nhello', 5000)
		assert status_of(r7) == 200, '${mode}: ${r7}'
		assert body_of(r7) == '5 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824', '${mode}: ${r7}'
	}
}

// Keep-alive reuse: 100 sequential calls cost one upstream accept (and one TLS
// handshake). A `Connection: close` answer, or a body delimited by the close,
// makes the next call re-dial.
fn test_reuse() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		for i in 0 .. 100 {
			r := get(p, '/ok')
			assert status_of(r) == 200, '${i}: ${r}'
		}
		assert e.fake.stat('accepted') == 1
		if https {
			assert e.fake.stat('handshakes') == 1
			assert e.fake.stat('tickets') == 2 // read past ahead of the first answer
		}
		assert status_of(get(p, '/connclose')) == 200
		assert status_of(get(p, '/ok')) == 200
		assert e.fake.stat('accepted') == 2
		assert status_of(get(p, '/close')) == 200
		assert status_of(get(p, '/ok')) == 200
		assert e.fake.stat('accepted') == 3
	}
}

// A kept connection the upstream closed while idle is found before reuse: the
// next call re-dials and succeeds (the #229 repro's /idleclose then /ok gave
// a 502).
fn test_stale_keepalive_is_redialed() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		assert status_of(get(p, '/idleclose')) == 200
		time.sleep(300 * time.millisecond) // the upstream closes the idle connection meanwhile
		r := get(p, '/ok')
		assert status_of(r) == 200, r
		assert e.fake.stat('accepted') == 2
	}
}

// A kept connection that dies after taking the request, before answering: an
// idempotent request (or a POST with an Idempotency-Key) is sent once more on
// a fresh connection; a plain POST is never sent twice.
fn test_retry_only_when_safe() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		// /drop closes without answering: the retry meets it too, so the call
		// fails after exactly two sends.
		assert status_of(get(p, '/ok')) == 200
		r1 := get(p, '/drop')
		assert status_of(r1) == 502 && failure_of(r1) == 'closed', r1
		assert e.fake.stat('path:/drop') == 2
		assert status_of(get(p, '/ok')) == 200
		r2, _ := call(p, 'POST /up/drop HTTP/1.1\r\nHost: edge\r\nContent-Length: 2\r\n\r\nhi', 5000)
		assert status_of(r2) == 502 && failure_of(r2) == 'closed', r2
		assert e.fake.stat('path:/drop') == 3 // sent once
		assert status_of(get(p, '/ok')) == 200
		r3, _ := call(p, 'POST /up/drop HTTP/1.1\r\nHost: edge\r\nIdempotency-Key: k1\r\nContent-Length: 2\r\n\r\nhi',
			5000)
		assert status_of(r3) == 502, r3
		assert e.fake.stat('path:/drop') == 5 // retried once
	}
}

// A close-delimited body cut by a bare FIN: over TLS that is no clean end (no
// close_notify, RFC 9112 §9.8), so .truncated; in plain HTTP the FIN is the end.
fn test_truncated_body() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
		defer {
			e.stop()
		}
		r := get(e.h.port(), '/trunc')
		if https {
			assert status_of(r) == 502 && failure_of(r) == 'truncated', r
		} else {
			assert status_of(r) == 200 && body_of(r) == 'cut sho', r
		}
	}
}

// A certificate that does not name the host, or a client that trusts another
// CA: .tls_verify, and the request is never sent.
fn test_tls_verify_failures() {
	if true !in variants() {
		return
	}
	mut e := setup(true, 'wronghost', upstream.Origin{}) or { panic(err) }
	defer {
		e.stop()
	}
	r := get(e.h.port(), '/ok')
	assert status_of(r) == 502 && failure_of(r) == 'tls_verify', r
	assert e.fake.stat('requests') == 0
	// A client config that trusts other_ca.crt, against the right certificate.
	mut f := start_fake(e.certs, 'server') or { panic(err) }
	defer {
		f.stop()
	}
	other := tls.new_client(os.join_path(e.certs, 'other_ca.crt'), .full) or { panic(err) }
	origin := upstream.Origin{
		host: 'localhost'
		port: f.port
	}
	mut h := vtest.start(server.ServerConfig{
		handler:         edge
		workers:         1
		on_worker_start: on_worker_start
		make_state:      fn [origin, other] () voidptr {
			return new_app(origin, other, unsafe { nil })
		}
	}) or { panic(err) }
	defer {
		h.stop()
	}
	r2 := get(h.port(), '/ok')
	assert status_of(r2) == 502 && failure_of(r2) == 'tls_verify', r2
	assert f.stat('requests') == 0
}

// An HTTPS origin given by IP address, IPv4 and IPv6 (#233): the address must
// be one of the certificate's iPAddress SANs (server.crt: IP:127.0.0.1,
// IP:::1), and the Host header carries it (an IPv6 one in brackets). A
// certificate without it (wronghost.crt: DNS:wrong.example) fails with
// .tls_verify, the request unsent. Each case runs twice, the second time on a
// re-dial, where the slot re-arms its TLS session. (That no SNI is sent for
// an IP is checked by tls/ and pg_async's tests: this fake cannot see it.)
fn test_https_to_an_ip_literal() {
	if true !in variants() {
		return
	}
	certs := testkit.test_certs() or { panic(err) }
	defer {
		os.rmdir_all(certs) or {}
	}
	cfg := tls.new_client(os.join_path(certs, 'ca.crt'), .full) or { panic(err) }
	for ip in ['127.0.0.1', '::1'] {
		if !can_listen(ip) {
			eprintln('https_upstream: cannot listen on ${ip} here; skipping it')
			continue
		}
		for cert in ['server', 'wronghost'] {
			mut f := start_fake_on(ip, certs, cert) or { panic(err) }
			defer {
				f.stop()
			}
			origin := upstream.Origin{
				host: ip
				port: f.port
			}
			mut h := vtest.start(server.ServerConfig{
				handler:         edge
				workers:         1
				on_worker_start: on_worker_start
				make_state:      fn [origin, cfg] () voidptr {
					return new_app(origin, cfg, unsafe { nil })
				}
			}) or { panic(err) }
			defer {
				h.stop()
			}
			p := h.port()
			if cert == 'server' {
				want := if ip.contains(':') { '[${ip}]:${f.port}' } else { '${ip}:${f.port}' }
				r := get(p, '/host')
				assert status_of(r) == 200 && body_of(r) == want, '${ip}: ${r}'
				assert status_of(get(p, '/connclose')) == 200, ip
				r2 := get(p, '/host')
				assert status_of(r2) == 200 && body_of(r2) == want, '${ip}: ${r2}'
				assert f.stat('handshakes') == 2, ip
			} else {
				for _ in 0 .. 2 {
					r := get(p, '/host')
					assert status_of(r) == 502 && failure_of(r) == 'tls_verify', '${ip}: ${r}'
				}
				assert f.stat('requests') == 0, ip
			}
		}
	}
}

// can_listen reports whether a socket can bind to `ip` here (some hosts and
// containers have no IPv6 loopback).
fn can_listen(ip string) bool {
	a := transport.ip_addr(ip, 0) or { return false }
	fd := C.socket(a.family, C.SOCK_STREAM, 0)
	if fd < 0 {
		return false
	}
	ok := C.bind(fd, voidptr(&a.data[0]), a.len) == 0
	C.close(fd)
	return ok
}

// An upstream that answers 413 after the head of a 4 MiB POST and stops
// reading: the answer is relayed (the rest is not sent), and the connection
// is not reused.
fn test_early_response() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_request_bytes: 8 << 20
		}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		r, ms := call(p, 'POST /fill/${4 << 20}/e413 HTTP/1.1\r\nHost: edge\r\n\r\n', 10_000)
		assert status_of(r) == 413, r
		assert ms < 3000 * slack()
		assert status_of(get(p, '/ok')) == 200
		assert e.fake.stat('accepted') == 2
		// The same on a kept connection, where the handler itself writes the
		// request and may meet the whole answer before it returns.
		r2, _ := call(p, 'POST /fill/${4 << 20}/e413 HTTP/1.1\r\nHost: edge\r\n\r\n', 10_000)
		assert status_of(r2) == 413, r2
	}
}

// A 100 Continue arriving mid-upload is no early answer: the body goes on in
// full, and the final answer is relayed.
fn test_interim_answer_mid_upload() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_request_bytes: 8 << 20
		}) or { panic(err) }
		defer {
			e.stop()
		}
		n := 2 << 20
		r, _ := call(e.h.port(), 'POST /fill/${n}/cont100 HTTP/1.1\r\nHost: edge\r\n\r\n', 20_000)
		assert status_of(r) == 200, r
		assert body_of(r).starts_with('${n} '), r
	}
}

// A 4 MiB request body arrives byte-exact (the socket fills: .writable parking,
// and over TLS same-length record retries). The edge generates it (/fill/).
fn test_large_request_body() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_request_bytes: 8 << 20
		}) or { panic(err) }
		defer {
			e.stop()
		}
		mut body := []u8{len: 4 << 20}
		for i in 0 .. body.len {
			body[i] = u8(`a` + i % 26)
		}
		r, _ := call(e.h.port(), 'POST /fill/${body.len}/echo HTTP/1.1\r\nHost: edge\r\n\r\n',
			20_000)
		assert status_of(r) == 200, r
		assert body_of(r) == '${body.len} ${sha256.sum(body).hex()}', r
	}
}

// TLS 1.3 session tickets that arrive while a 4 MiB request body is going out
// (#236): the fake holds its last handshake step for 200 ms, so the client,
// done with its side, is sending the body (and the socket fills) when the two
// tickets come, ahead of the answer. The body arrives byte-exact, and the
// kept connection serves the next exchange.
fn test_tickets_mid_upload() {
	for https in variants() {
		if !https {
			continue
		}
		mut e := setup_fake(https, 'server', upstream.Origin{
			max_request_bytes: 8 << 20
		}, server.Limits{}, ['--ticket-delay-ms', '200']) or { panic(err) }
		defer {
			e.stop()
		}
		mut body := []u8{len: 4 << 20}
		for i in 0 .. body.len {
			body[i] = u8(`a` + i % 26)
		}
		p := e.h.port()
		r, _ := call(p, 'POST /fill/${body.len}/echo HTTP/1.1\r\nHost: edge\r\n\r\n', 20_000)
		assert status_of(r) == 200, r
		assert body_of(r) == '${body.len} ${sha256.sum(body).hex()}', r
		assert status_of(get(p, '/ok')) == 200
		assert e.fake.stat('handshakes') == 1
		assert e.fake.stat('held_handshakes') == 1
		assert e.fake.stat('tickets') == 2
	}
}

// A response over max_response_bytes fails with .too_large.
fn test_response_too_large() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_response_bytes: 64 << 10
		}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		r := get(p, '/big/200000')
		assert status_of(r) == 502 && failure_of(r) == 'too_large', r
		r2 := get(p, '/big/60000')
		assert status_of(r2) == 200 && body_of(r2).len == 60000
	}
	// A limit below the slot's initial 16 KiB buffer holds too, for a response
	// that arrives whole in one read.
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_response_bytes: 4096
		}) or { panic(err) }
		defer {
			e.stop()
		}
		r := get(e.h.port(), '/big/10000')
		assert status_of(r) == 502 && failure_of(r) == 'too_large', r
		assert status_of(get(e.h.port(), '/big/1000')) == 200
	}
}

// A silent upstream: with every Limits timeout at 300 ms the client used to
// get nothing (#229 repro: "<no response> after 3006 ms"). Now the response
// deadline answers 504, and the slot serves the next call.
fn test_response_deadline() {
	for https in variants() {
		mut e := setup_limits(https, 'server', upstream.Origin{
			response_timeout_ms: 500
			max_conns:           1
		}, server.Limits{
			read_timeout_ms:  300
			write_timeout_ms: 300
			idle_timeout_ms:  300
		}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		r, ms := call(p, 'GET /up/slow HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
		assert status_of(r) == 504 && failure_of(r) == 'timeout', r
		assert ms >= 450 && ms < 1500 * slack(), '${ms} ms'
		r2 := get(p, '/ok')
		assert status_of(r2) == 200, r2
	}
}

// A listener that accepts (its backlog does) but never completes the TLS
// handshake: .timeout within connect_timeout_ms.
fn test_connect_deadline() {
	if true !in variants() {
		return
	}
	lfd, port := silent_listener()
	defer {
		C.close(lfd)
	}
	certs := testkit.test_certs() or { panic(err) }
	defer {
		os.rmdir_all(certs) or {}
	}
	cfg := tls.new_client(os.join_path(certs, 'ca.crt'), .full) or { panic(err) }
	origin := upstream.Origin{
		host:               'localhost'
		port:               port
		connect_timeout_ms: 400
		// localhost may resolve to ::1 first: nothing listens there, so that
		// dial is refused at once and the next address is the silent listener.
	}
	mut h := vtest.start(server.ServerConfig{
		handler:         edge
		workers:         1
		on_worker_start: on_worker_start
		make_state:      fn [origin, cfg] () voidptr {
			return new_app(origin, cfg, unsafe { nil })
		}
	}) or { panic(err) }
	defer {
		h.stop()
	}
	r, ms := call(h.port(), 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
	assert status_of(r) == 504 && failure_of(r) == 'timeout', r
	assert ms >= 350 && ms < 1500 * slack(), '${ms} ms'
}

// silent_listener listens on 127.0.0.1 and never accepts: connects complete
// in its backlog, and nothing is ever answered (not even a TLS handshake).
fn silent_listener() (int, int) {
	return listener(16)
}

// listener listens on 127.0.0.1 with `backlog` and never accepts. With
// backlog 0 the accept queue holds one connection: once it does, the kernel
// drops the SYN of every later connect, which stays in SYN_SENT.
fn listener(backlog int) (int, int) {
	lfd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	a := transport.ip_addr('127.0.0.1', 0) or { panic('addr') }
	assert C.bind(lfd, voidptr(&a.data[0]), a.len) == 0
	assert C.listen(lfd, backlog) == 0
	mut sa := transport.Addr{}
	mut sl := u32(sa.data.len)
	C.getsockname(lfd, voidptr(&sa.data[0]), &sl)
	return lfd, (int(sa.data[2]) << 8) | int(sa.data[3])
}

// A client that disconnects while its exchange is still connecting (TLS) or
// waiting for an answer that never comes (plain) does not leak the slot: the
// deadline frees it, and with max_conns: 1 the next call gets the slot (a 504
// from the same silent upstream, not a 503).
fn test_client_disconnect_mid_exchange_frees_the_slot() {
	for https in variants() {
		lfd, port := silent_listener()
		defer {
			C.close(lfd)
		}
		mut certs := ''
		mut cfg := &tls.Config(unsafe { nil })
		if https {
			certs = testkit.test_certs() or { panic(err) }
			cfg = tls.new_client(os.join_path(certs, 'ca.crt'), .full) or { panic(err) }
		}
		defer {
			if certs != '' {
				os.rmdir_all(certs) or {}
			}
		}
		origin := upstream.Origin{
			host:                if https { 'localhost' } else { '127.0.0.1' }
			port:                port
			https:               https
			max_conns:           1
			connect_timeout_ms:  300
			response_timeout_ms: 300
		}
		mut h := vtest.start(server.ServerConfig{
			handler:         edge
			workers:         1
			on_worker_start: on_worker_start
			make_state:      fn [origin, cfg] () voidptr {
				return new_app(origin, cfg, unsafe { nil })
			}
		}) or { panic(err) }
		defer {
			h.stop()
		}
		fd := transport.dial_tcp('127.0.0.1', h.port()) or { panic(err) }
		testkit.fd_wait_writable(fd, 1000)
		assert testkit.fd_write_all(fd, 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
			1000)
		time.sleep(50 * time.millisecond)
		transport.close_fd(fd) // gone mid-exchange
		time.sleep(500 * time.millisecond) // past the deadline
		r, _ := call(h.port(), 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', 3000)
		assert status_of(r) == 504, r
	}
}

fn C.socket(domain int, typ int, protocol int) int
fn C.bind(fd int, addr voidptr, len u32) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.dup(fd int) int
fn C.getsockname(fd int, addr voidptr, len &u32) int
fn C.close(fd int) int

// max_conns: 2 with three slow calls in flight: the third is shed with 503.
fn test_pool_exhaustion_sheds() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_conns: 2
		}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		mut fds := []int{}
		for _ in 0 .. 2 {
			fd := transport.dial_tcp('127.0.0.1', p) or { panic(err) }
			testkit.fd_wait_writable(fd, 1000)
			assert testkit.fd_write_all(fd, 'GET /up/delay/800 HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
				1000)
			fds << fd
		}
		time.sleep(100 * time.millisecond)
		r, ms := call(p, 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', 2000)
		assert status_of(r) == 503, r
		assert ms < 300 * slack()
		mut acc := []u8{}
		mut buf := []u8{len: 4096}
		for fd in fds {
			read_response(fd, mut acc, mut buf, 3000)
			assert client.status_code(acc) == 200, acc.bytestr()
			transport.close_fd(fd)
		}
	}
}

// A client that disconnects while its exchange is reading: the reply is
// drained and the slot released with its connection kept — the next call
// reuses it (no new upstream accept).
fn test_client_disconnect_keeps_the_connection() {
	for https in variants() {
		mut e := setup(https, 'server', upstream.Origin{
			max_conns: 1
		}) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		assert status_of(get(p, '/ok')) == 200
		fd := transport.dial_tcp('127.0.0.1', p) or { panic(err) }
		testkit.fd_wait_writable(fd, 1000)
		assert testkit.fd_write_all(fd, 'GET /up/delay/300 HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
			1000)
		time.sleep(50 * time.millisecond)
		transport.close_fd(fd) // gone while the upstream thinks
		time.sleep(450 * time.millisecond)
		r := get(p, '/ok')
		assert status_of(r) == 200, r
		assert e.fake.stat('accepted') == 1
	}
}

// Resolution off the worker: a resolve that takes 2 s runs on the Resolver's
// thread while /health answers at once, and a changed address reaches the
// pool within one refresh interval; new dials go to it.
fn test_resolver_follows_changes_off_the_worker() {
	if false !in variants() {
		return
	}
	mut a := start_fake('', '') or { panic(err) }
	defer {
		a.stop()
	}
	mut b := start_fake('', '') or { panic(err) }
	defer {
		b.stop()
	}
	mut sw := &Switch{
		port: a.port
	}
	origin := upstream.Origin{
		host:            'upstream.test'
		port:            80 // the addresses carry the fakes' ports
		https:           false
		max_lifetime_ms: 200
		resolve:         fn [sw] (host string, port int) []transport.Addr {
			if stdatomic.load_i64(&sw.slow) != 0 {
				time.sleep(2 * time.second)
			}
			ad := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&sw.port))) or {
				return []
			}
			return [ad]
		}
	}
	mut r := upstream.Resolver.new(100) or { panic(err) }
	r.start()
	defer {
		r.stop()
	}
	rr := r
	mut h := vtest.start(server.ServerConfig{
		handler:         edge
		workers:         1
		on_worker_start: on_worker_start
		make_state:      fn [origin, rr] () voidptr {
			return new_app(origin, unsafe { nil }, rr)
		}
	}) or { panic(err) }
	defer {
		h.stop()
	}
	p := h.port()
	assert status_of(get(p, '/ok')) == 200
	assert a.stat('requests') == 1
	stdatomic.store_i64(&sw.port, b.port)
	time.sleep(400 * time.millisecond) // a refresh, and the kept connection's lifetime
	assert status_of(get(p, '/ok')) == 200
	assert b.stat('requests') == 1, 'the new address was not used'
	// A slow resolver: /health on the worker is not held up.
	stdatomic.store_i64(&sw.slow, 1)
	time.sleep(150 * time.millisecond) // a lookup thread is now in the 2 s resolve
	mut worst := i64(0)
	for _ in 0 .. 20 {
		hr, ms := call(p, 'GET /health HTTP/1.1\r\nHost: edge\r\n\r\n', 2000)
		assert status_of(hr) == 200
		if ms > worst {
			worst = ms
		}
	}
	assert worst < 50 * slack(), '/health took ${worst} ms while the resolver was busy'
	stdatomic.store_i64(&sw.slow, 0)
}

// Four workers, each with its own pool following one Resolver that refreshes
// every 10 ms, under concurrent calls: every call answers, and (run with
// `v -race`) no data race between the workers and the resolver's threads.
fn test_workers_and_resolver_churn() {
	for https in variants() {
		mut f := start_fake(if https { testkit.test_certs() or { panic(err) } } else { '' },
			'server') or { panic(err) }
		certs := f.certs_dir()
		defer {
			f.stop()
			if certs != '' {
				os.rmdir_all(certs) or {}
			}
		}
		mut cfg := &tls.Config(unsafe { nil })
		if https {
			cfg = tls.new_client(os.join_path(certs, 'ca.crt'), .full) or { panic(err) }
		}
		fport := f.port
		origin := upstream.Origin{
			host:      if https { 'localhost' } else { 'upstream.test' }
			port:      f.port
			https:     https
			max_conns: 4
			resolve:   fn [fport] (host string, port int) []transport.Addr {
				a := transport.ip_addr('127.0.0.1', fport) or { return [] }
				return [a]
			}
		}
		mut r := upstream.Resolver.new(10) or { panic(err) }
		r.start()
		defer {
			r.stop()
		}
		rr := r
		mut h := vtest.start(server.ServerConfig{
			handler:         edge
			workers:         4
			on_worker_start: on_worker_start
			make_state:      fn [origin, cfg, rr] () voidptr {
				return new_app(origin, cfg, rr)
			}
		}) or { panic(err) }
		defer {
			h.stop()
		}
		req := 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes()
		mut rounds := []vtest.Round{}
		for _ in 0 .. 10 {
			rounds << vtest.Round{
				send: req
			}
		}
		o := h.fire(vtest.repeat(24, vtest.Script{
			rounds: rounds
		})) or { panic(err) }
		mut ok := 0
		mut busy := 0
		for c in o.conns {
			for fr in c.frames {
				st := client.status_code(fr)
				if st == 200 {
					ok++
				} else if st == 503 {
					busy++ // all 4 of a worker's connections in use: shed
				} else {
					assert false, fr.bytestr()
				}
			}
		}
		assert ok + busy == 240
		assert ok > 0
	}
}

// Switch is the test resolver's answer: written by the test, read by a
// lookup thread (atomics).
@[heap]
struct Switch {
mut:
	port i64
	slow i64
}

// Dns is a provider's DNS for the test resolver: down (no address, after
// slow_ms: a DNS that times out) or the fake's port, and how often it was
// asked (atomics: a lookup thread and the workers' make_state call it).
@[heap]
struct Dns {
mut:
	port    i64
	down    i64
	slow_ms i64
	calls   i64
}

// unresolved_origin is an origin whose name only `d` resolves, allowed to
// start unresolved.
fn unresolved_origin(d &Dns) upstream.Origin {
	return upstream.Origin{
		host:             'provider.test'
		port:             80 // the address carries the fake's port
		https:            false
		allow_unresolved: true
		resolve:          fn [d] (host string, port int) []transport.Addr {
			stdatomic.add_i64(&d.calls, 1)
			if stdatomic.load_i64(&d.down) != 0 {
				slow := stdatomic.load_i64(&d.slow_ms)
				if slow > 0 {
					time.sleep(time.Duration(slow) * time.millisecond)
				}
				return []
			}
			a := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&d.port))) or { return [] }
			return [a]
		}
	}
}

// wait_for waits up to ms for *counter to reach n.
fn wait_for(counter &i64, n i64, ms i64) bool {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < ms {
		if stdatomic.load_i64(counter) >= n {
			return true
		}
		time.sleep(5 * time.millisecond)
	}
	return stdatomic.load_i64(counter) >= n
}

// A provider's DNS is down when the edge boots (#348), and every lookup waits
// 300 ms for nothing: with allow_unresolved the edge starts anyway, once its
// boot lookup has given up, and each call fails at once with .dns, without
// dialing (the fake accepts nothing) or waiting for the DNS. Once the DNS
// answers, the refresh the failing calls ask for fills the pool, and calls
// succeed.
fn test_unresolved_origin_fills_once_it_resolves() {
	mut f := start_fake('', '') or { panic(err) }
	defer {
		f.stop()
	}
	mut dns := &Dns{
		port:    f.port
		down:    1
		slow_ms: 300
	}
	origin := unresolved_origin(dns)
	// No periodic refresh while the test runs: only the failing calls ask.
	mut r := upstream.Resolver.new(60_000) or { panic(err) }
	r.start()
	defer {
		r.stop()
	}
	rr := r
	mut h := vtest.start(server.ServerConfig{
		handler:         edge
		workers:         1
		on_worker_start: on_worker_start
		make_state:      fn [origin, rr] () voidptr {
			return new_app(origin, unsafe { nil }, rr)
		}
	}) or { panic(err) }
	defer {
		h.stop()
	}
	p := h.port()
	// The worker serves once make_state's lookup has given up.
	hr, _ := call(p, 'GET /health HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
	assert status_of(hr) == 200, hr
	for _ in 0 .. 3 {
		r1, ms := call(p, 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', 5000)
		assert status_of(r1) == 502 && failure_of(r1) == 'dns', r1
		assert ms < 100 * slack(), '${ms} ms: a call waited for the DNS'
	}
	assert f.stat('accepted') == 0
	assert wait_for(&dns.calls, 2, 2000 * slack()), 'the failing calls asked for no refresh'
	// The DNS is back: a refresh the failing calls ask for (one gap after the
	// last) answers, and its update reaches the worker.
	stdatomic.store_i64(&dns.down, 0)
	mut r2 := ''
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 3000 * slack() {
		r2 = get(p, '/ok')
		if status_of(r2) == 200 {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert status_of(r2) == 200, 'no call succeeded once the DNS was back: ${r2}'
	assert status_of(get(p, '/ok')) == 200
	assert f.stat('accepted') == 1
}

// A provider's DNS down under load (#348): four workers' pools follow one
// Resolver, 32 connections send 100 calls each, and every call fails at once
// with .dns. Each failing exchange asks for a refresh, and the DNS fails as
// fast as it can (a cached negative answer). The asks still coalesce: the
// Resolver resolves the origin once per refresh gap (1 s), not once per call
// (3044 resolutions for 3200 calls before the gap).
fn test_unresolved_origin_coalesces_refreshes() {
	mut dns := &Dns{
		down: 1
	}
	origin := unresolved_origin(dns)
	mut r := upstream.Resolver.new(60_000) or { panic(err) }
	r.start()
	defer {
		r.stop()
	}
	rr := r
	mut h := vtest.start(server.ServerConfig{
		handler:         edge
		workers:         4
		on_worker_start: on_worker_start
		make_state:      fn [origin, rr] () voidptr {
			return new_app(origin, unsafe { nil }, rr)
		}
	}) or { panic(err) }
	defer {
		h.stop()
	}
	assert wait_for(&dns.calls, 4, 2000 * slack()) // each worker's Pool.new
	boot := stdatomic.load_i64(&dns.calls)
	req := 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes()
	mut rounds := []vtest.Round{}
	for _ in 0 .. 100 {
		rounds << vtest.Round{
			send: req
		}
	}
	sw := time.new_stopwatch()
	o := h.fire(vtest.repeat(32, vtest.Script{
		rounds: rounds
	})) or { panic(err) }
	ms := sw.elapsed().milliseconds()
	resolutions := stdatomic.load_i64(&dns.calls) - boot
	mut failed := 0
	for c in o.conns {
		for fr in c.frames {
			resp := fr.bytestr()
			assert status_of(resp) == 502 && failure_of(resp) == 'dns', resp
			failed++
		}
	}
	assert failed == 3200
	assert resolutions >= 1, 'the failing calls asked for no refresh'
	assert resolutions <= ms / 1000 + 2, '${resolutions} resolutions for ${failed} failing calls in ${ms} ms'
}

// --- Two deadlines on one park (#322) ----------------------------------------
//
// A parked exchange waits under two deadlines: its own (connect_timeout_ms,
// response_timeout_ms), which the pool's maintenance timer enforces, and the
// park's (Limits.park_timeout_ms), which the epoll worker enforces by running
// the continuation with event_loop.timed_out(). Whichever passes first, the
// continuation gets .failed with .timeout once, and the connection is closed
// only once no watch is left on it.

// Probe counts what probe_cont saw, for one edge: its worker thread writes
// it and the test reads it (atomics). Each edge has its own, the watch
// payload of its exchanges: a stopped edge's late runs land in its own.
@[heap]
struct Probe {
mut:
	timeout_runs  i64 // runs with event_loop.timed_out(): the park's deadline passed
	orphaned_runs i64 // runs with event_loop.orphaned(): a tombstone's
	failed        i64 // advance() answered .failed
	failure       i64 // the failure of the last one (an upstream.Failure)
	timeout_fd    i64 // ready_fd of the last timed-out run
	after_timeout i64 // what advance() answered in it (an upstream.Poll)
}

fn new_probe() &Probe {
	return &Probe{
		timeout_fd:    -1
		after_timeout: -1
	}
}

// probe_handler is an edge handler counting into p (probe_edge).
fn probe_handler(p &Probe) core.Handler {
	return fn [p] (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut el core.EventLoop) core.Step {
		return probe_edge(req, mut out, client_fd, worker_state, mut el, p)
	}
}

// probe_edge relays like edge, with probe_cont as the continuation and p as
// its payload: GET /up/<path>, or POST /fill/<n>/<path> with n generated
// bytes. GET /fd answers the client's own fd number.
fn probe_edge(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut el core.EventLoop, p &Probe) core.Step {
	sp1 := index_of(req, 0, ` `)
	sp2 := if sp1 > 0 { index_of(req, sp1 + 1, ` `) } else { -1 }
	if sp2 < 0 {
		core.append_str(mut out, resp_404)
		return .done
	}
	target := view(req, sp1 + 1, sp2 - sp1 - 1)
	if target == '/fd' {
		mut digits := []u8{cap: 20}
		wi(mut digits, client_fd)
		core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Length: ')
		wi(mut out, digits.len)
		core.append_str(mut out, crlf2)
		wb(mut out, digits)
		return .done
	}
	mut fill := 0
	mut up_start := sp1 + up_prefix.len
	if target.starts_with(fill_prefix) {
		slash := index_of(req, sp1 + 1 + fill_prefix.len, `/`)
		if slash < 0 || slash > sp2 {
			core.append_str(mut out, resp_404)
			return .done
		}
		fill = leading_int(req, sp1 + 1 + fill_prefix.len, slash - sp1 - 1 - fill_prefix.len)
		up_start = slash
	} else if !target.starts_with(up_prefix) {
		core.append_str(mut out, resp_404)
		return .done
	}
	mut app := unsafe { &App(worker_state) }
	mut x := app.up.acquire() or {
		core.append_str(mut out, resp_503)
		return .done
	}
	x.request(view(req, 0, sp1), view(req, up_start, sp2 - up_start))
	mut b := x.body()
	for i in 0 .. fill {
		b << u8(`a` + i % 26)
	}
	if x.send(mut el, probe_cont, voidptr(p)) == .pending {
		return .suspend
	}
	failed(mut out, x.failure())
	x.release()
	return .done
}

// probe_cont is on_upstream, counting what each run saw in its payload, a
// Probe.
fn probe_cont(mut out []u8, fd int, fd_err bool, payload voidptr, worker_state voidptr, mut el core.EventLoop) core.Step {
	mut p := unsafe { &Probe(payload) }
	timed_out := el.timed_out()
	if timed_out {
		stdatomic.add_i64(&p.timeout_runs, 1)
		stdatomic.store_i64(&p.timeout_fd, i64(fd))
	}
	if el.orphaned() {
		stdatomic.add_i64(&p.orphaned_runs, 1)
	}
	mut app := unsafe { &App(worker_state) }
	mut x := app.up.exchange_of(fd) or {
		failed(mut out, .closed)
		return .done
	}
	r := x.advance(fd_err, mut el, probe_cont, payload)
	if timed_out {
		stdatomic.store_i64(&p.after_timeout, i64(int(r)))
	}
	match r {
		.pending {
			return .suspend
		}
		.failed {
			stdatomic.add_i64(&p.failed, 1)
			stdatomic.store_i64(&p.failure, i64(int(x.failure())))
			failed(mut out, x.failure())
			x.release()
			return .done
		}
		.ready {}
	}
	body := x.body_view()
	core.append_str(mut out, 'HTTP/1.1 ')
	wi(mut out, x.status())
	core.append_str(mut out, ' \r\nContent-Length: ')
	wi(mut out, body.len)
	core.append_str(mut out, crlf2)
	wb(mut out, body)
	x.release()
	return .done
}

// Stage is where an exchange waits when its deadline passes.
enum Stage {
	connecting // the TCP connect: the origin's accept queue is full, its SYN dropped
	handshake  // the TLS handshake: the origin accepts (in its backlog), never answers
	sending    // the request: the upstream stops reading, and a 4 MiB upload fills the socket
	reading    // the response: the upstream never answers
}

fn stages(https bool) []Stage {
	return if https {
		[Stage.connecting, .handshake, .sending, .reading]
	} else {
		[Stage.connecting, .sending, .reading]
	}
}

// TimeoutCase is one call that waits at `stage` until a deadline passes: the
// park's (300 ms) before the exchange's own (10 s) when park_first, the other
// way round otherwise.
struct TimeoutCase {
	https      bool
	stage      Stage
	park_first bool
mut:
	probe         &Probe = new_probe()
	resp          string
	ms            i64
	next          string // a call made after it (fake stages only)
	accepted      int    // the fake's connections by then (-1: no fake)
	timeout_runs  i64
	orphaned_runs i64
	failed        i64
	failure       i64
	after_timeout i64
}

const deadline_short_ms = 300
const deadline_long_ms = 10_000

// deadline_bound is how long a call that times out after deadline_short_ms
// may take.
fn deadline_bound() i64 {
	return i64(deadline_short_ms) + 1200 * slack()
}

fn (mut c TimeoutCase) run() {
	own := if c.park_first { deadline_long_ms } else { deadline_short_ms }
	o := upstream.Origin{
		max_conns:           1
		connect_timeout_ms:  own
		response_timeout_ms: own
		max_request_bytes:   8 << 20
	}
	limits := server.Limits{
		park_timeout_ms: if c.park_first { deadline_short_ms } else { deadline_long_ms }
	}
	wait := int(deadline_bound()) + 500
	c.accepted = -1
	if c.stage == .connecting || c.stage == .handshake {
		lfd, port := listener(if c.stage == .connecting { 0 } else { 16 })
		defer {
			C.close(lfd)
		}
		// Queued, never accepted: with backlog 0 it fills the accept queue.
		filler := transport.dial_tcp('127.0.0.1', port) or { panic(err) }
		defer {
			transport.close_fd(filler)
		}
		testkit.fd_wait_writable(filler, 1000)
		mut certs := ''
		mut cfg := &tls.Config(unsafe { nil })
		if c.https {
			certs = testkit.test_certs() or { panic(err) }
			cfg = tls.new_client(os.join_path(certs, 'ca.crt'), .full) or { panic(err) }
		}
		defer {
			if certs != '' {
				os.rmdir_all(certs) or {}
			}
		}
		mut h := start_edge(upstream.Origin{
			...o
			host:  '127.0.0.1'
			port:  port
			https: c.https
		}, cfg, limits, probe_handler(c.probe)) or { panic(err) }
		defer {
			h.stop()
		}
		r, ms := call(h.port(), 'GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n', wait)
		c.resp = r
		c.ms = ms
		c.snapshot()
		return
	}
	mut e := setup_handler(c.https, 'server', o, limits, [], probe_handler(c.probe)) or {
		panic(err)
	}
	defer {
		e.stop()
	}
	req := if c.stage == .sending {
		'POST /fill/${4 << 20}/stall HTTP/1.1\r\nHost: edge\r\n\r\n'
	} else {
		'GET /up/slow HTTP/1.1\r\nHost: edge\r\n\r\n'
	}
	r, ms := call(e.h.port(), req, wait)
	c.resp = r
	c.ms = ms
	c.snapshot()
	c.next = get(e.h.port(), '/ok')
	c.accepted = e.fake.stat('accepted')
}

fn (mut c TimeoutCase) snapshot() {
	c.timeout_runs = stdatomic.load_i64(&c.probe.timeout_runs)
	c.orphaned_runs = stdatomic.load_i64(&c.probe.orphaned_runs)
	c.failed = stdatomic.load_i64(&c.probe.failed)
	c.failure = stdatomic.load_i64(&c.probe.failure)
	c.after_timeout = stdatomic.load_i64(&c.probe.after_timeout)
}

fn (c &TimeoutCase) name() string {
	mode := if c.https { 'https' } else { 'http' }
	first := if c.park_first {
		'park ${deadline_short_ms} ms < own ${deadline_long_ms} ms'
	} else {
		'own ${deadline_short_ms} ms < park ${deadline_long_ms} ms'
	}
	return '${mode} ${c.stage}, ${first}'
}

fn (c &TimeoutCase) summary() string {
	after := match c.after_timeout {
		i64(int(upstream.Poll.pending)) { 'pending' }
		i64(int(upstream.Poll.ready)) { 'ready' }
		i64(int(upstream.Poll.failed)) { 'failed' }
		else { '-' }
	}
	mut s := '[${c.name()}] ${brief(c.resp)} after ${c.ms} ms; timed-out runs: ${c.timeout_runs} (advance() answered ${after} in the last), .failed: ${c.failed} (${failure_names[int(c.failure)]}), orphaned runs: ${c.orphaned_runs}'
	if c.accepted >= 0 {
		s += '; next call: ${brief(c.next)}, upstream connections: ${c.accepted}'
	}
	return s
}

// brief is a response in a few words: its status, then its
// X-Upstream-Failure or its body.
fn brief(resp string) string {
	if resp == '' {
		return 'no response'
	}
	if resp.contains('X-Upstream-Failure: ') {
		return '${status_of(resp)} ${failure_of(resp)}'
	}
	return '${status_of(resp)} "${body_of(resp)}"'
}

// check asserts what every timed-out call must show: one 504 for .timeout
// about deadline_short_ms in, one .failed seen by the continuation, no
// tombstone, and the slot free again for a fresh connection.
fn (c &TimeoutCase) check() {
	assert status_of(c.resp) == 504 && failure_of(c.resp) == 'timeout', c.summary()
	assert c.ms >= i64(deadline_short_ms - 50) && c.ms <= deadline_bound(), c.summary()
	assert c.failed == 1 && c.failure == i64(int(upstream.Failure.timeout)), c.summary()
	assert c.orphaned_runs == 0, c.summary()
	if c.park_first {
		// The park's run ended the exchange and kept watching its socket; the
		// .failed came from the run after (the hangup).
		assert c.timeout_runs == 1 && c.after_timeout == i64(int(upstream.Poll.pending)), c.summary()
	} else {
		assert c.timeout_runs == 0, c.summary()
	}
	if c.accepted >= 0 {
		assert status_of(c.next) == 200 && body_of(c.next) == '{"status":"paid"}', c.summary()
		assert c.accepted == 2, c.summary() // the timed-out connection was not reused
	}
}

// Limits.park_timeout_ms shorter than the origin's timeouts (#322): in each
// stage the park's deadline ends the exchange. The continuation that runs with
// event_loop.timed_out() gets .pending from advance(), which shut the socket
// down and kept watching it; the hangup wakes it at once, and that run gets
// .failed with .timeout (504).
fn test_park_deadline_before_the_exchange_deadline() {
	mut cases := []TimeoutCase{}
	for https in variants() {
		for stage in stages(https) {
			mut c := TimeoutCase{
				https:      https
				stage:      stage
				park_first: true
			}
			c.run()
			eprintln(c.summary())
			cases << c
		}
	}
	for c in cases {
		c.check()
	}
}

// The exchange's own deadline shorter than Limits.park_timeout_ms: the
// maintenance timer ends it in each stage, as before, and the continuation
// never sees event_loop.timed_out().
fn test_exchange_deadline_before_the_park_deadline() {
	mut cases := []TimeoutCase{}
	for https in variants() {
		for stage in stages(https) {
			mut c := TimeoutCase{
				https:      https
				stage:      stage
				park_first: false
			}
			c.run()
			eprintln(c.summary())
			cases << c
		}
	}
	for c in cases {
		c.check()
	}
}

// hold_below takes every free fd number below n (as duplicates of fd), so
// the next fd this process gets is n, while n is free. Close them after.
fn hold_below(n int, fd int) []int {
	mut held := []int{}
	for {
		d := C.dup(fd)
		if d < 0 || d >= n {
			if d >= 0 {
				C.close(d)
			}
			return held
		}
		held << d
	}
	return held
}

// A late reply reaches nobody (#322). The park's deadline (500 ms) passes
// before the upstream answers (700 ms): the client gets its 504, and the
// connection that owes the reply is closed, not pooled. With max_conns: 1 the
// next call dials a fresh connection and gets its own answer while the late
// one arrives on the old connection, and a call after that reuses the fresh
// one. A client accepted on the fd number the timed-out exchange freed is
// served: no watch is left on that number to take its events (#342).
fn test_late_reply_after_a_park_deadline_reaches_nobody() {
	for https in variants() {
		mode := if https { 'https' } else { 'http' }
		pr := new_probe()
		mut e := setup_handler(https, 'server', upstream.Origin{
			max_conns:           1
			response_timeout_ms: deadline_long_ms
		}, server.Limits{
			park_timeout_ms: 500
		}, [], probe_handler(pr)) or { panic(err) }
		defer {
			e.stop()
		}
		p := e.h.port()
		// Connected after the timeout, once every lower fd number is taken:
		// the edge then accepts it on the number the timed-out exchange freed.
		s := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
		assert s >= 0
		defer {
			C.close(s)
		}
		a := transport.dial_tcp('127.0.0.1', p) or { panic(err) }
		defer {
			transport.close_fd(a)
		}
		mut acc := []u8{}
		mut buf := []u8{len: 4096}
		sw := time.new_stopwatch()
		testkit.fd_wait_writable(a, 1000)
		assert testkit.fd_write_all(a, 'GET /up/late/700 HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
			1000)
		read_response(a, mut acc, mut buf, 3000)
		r1 := acc.bytestr()
		ms := sw.elapsed().milliseconds()
		eprintln('[${mode} late reply] first call: ${brief(r1)} after ${ms} ms')
		assert status_of(r1) == 504 && failure_of(r1) == 'timeout', '${mode}: ${r1}'
		freed := int(stdatomic.load_i64(&pr.timeout_fd))
		held := hold_below(freed, s)
		ad := transport.ip_addr('127.0.0.1', p) or { panic('addr') }
		assert C.connect(s, voidptr(&ad.data[0]), ad.len) == 0
		assert testkit.fd_write_all(s, 'GET /fd HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(), 1000)
		read_response(s, mut acc, mut buf, 3000)
		rs := acc.bytestr()
		for fd in held {
			C.close(fd)
		}
		eprintln('[${mode} late reply] a client accepted after it: ${brief(rs)} (its fd; the timed-out exchange had ${freed})')
		assert status_of(rs) == 200, '${mode}: a client accepted on the freed fd ${freed} was not served: ${rs}'
		assert body_of(rs) == freed.str(), '${mode}: the edge accepted the client on fd ${body_of(rs)}, not on the freed ${freed}'
		r2 := get(p, '/delay/300') // in flight when the late reply comes
		assert status_of(r2) == 200 && body_of(r2) == '{"status":"paid"}', '${mode}: ${r2}'
		for sw.elapsed().milliseconds() < 900 {
			time.sleep(10 * time.millisecond) // the late reply has come and gone
		}
		r3 := get(p, '/ok')
		assert status_of(r3) == 200 && body_of(r3) == '{"status":"paid"}', '${mode}: ${r3}'
		assert e.fake.stat('accepted') == 2, mode
		assert stdatomic.load_i64(&pr.failed) == 1, mode
		assert stdatomic.load_i64(&pr.orphaned_runs) == 0, mode
	}
}

#include <malloc.h>

struct C.mallinfo2 {
	uordblks usize
	hblkhd   usize
}

fn C.mallinfo2() C.mallinfo2

fn heap_bytes() i64 {
	mi := C.mallinfo2()
	return i64(mi.uordblks) + i64(mi.hblkhd)
}

// No allocation per exchange: under -gc none (nothing is ever freed) the heap
// after 200 warm-up calls and after 4000 more (Content-Length, chunked, and a
// /fill/ upload, over TLS in a TLS build) grows by under 4096 B. The client is
// one keep-alive connection reading into reused buffers.
fn test_no_allocation_per_exchange() {
	$if gcboehm ? {
		return
	}
	$if race ? {
		return
	}
	vs := variants()
	if vs.len == 0 {
		return
	}
	https := vs.last()
	mut e := setup(https, 'server', upstream.Origin{}) or { panic(err) }
	defer {
		e.stop()
	}
	fd := transport.dial_tcp('127.0.0.1', e.h.port()) or { panic(err) }
	defer {
		transport.close_fd(fd)
	}
	testkit.fd_wait_writable(fd, 1000)
	reqs := ['GET /up/ok HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
		'GET /up/chunked HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes(),
		'POST /fill/64/echo HTTP/1.1\r\nHost: edge\r\n\r\n'.bytes()]
	mut acc := []u8{cap: 8192}
	mut buf := []u8{len: 8192}
	run := fn [fd, reqs] (n int, mut acc []u8, mut buf []u8) {
		for i in 0 .. n {
			req := reqs[i % reqs.len]
			C.send(fd, req.data, usize(req.len), 0)
			read_response(fd, mut acc, mut buf, 5000)
			if client.status_code(acc) != 200 {
				panic('call ${i} failed: ${acc.bytestr()}')
			}
		}
	}
	run(200, mut acc, mut buf)
	heap0 := heap_bytes()
	if heap0 == 0 {
		return
	}
	run(4000, mut acc, mut buf)
	growth := heap_bytes() - heap0
	assert growth < 4096, 'the heap grew ${growth} bytes over 4000 exchanges (https: ${https})'
}
