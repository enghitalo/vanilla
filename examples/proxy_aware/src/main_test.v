module main

import core
import http1_1.request_parser
import net

// SOLUTION: the trust rule is pure over an INJECTED peer — real_client_ip
// takes the peer address explicitly, so every branch (trusted, untrusted,
// unknown) is unit-testable. The live path feeds it `socket.peer_ipv4(fd)`,
// the shipped core API; serve() below passes fd -1, which makes that real
// call return none — driving the untrusted/'unknown' branch end to end — and
// the loopback tests give it a real, trusted 127.0.0.1 peer.

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect (BEST_PRACTICES §9).
fn serve(req []u8) ![]u8 {
	return serve_fd(req, -1)
}

fn serve_fd(req []u8, fd int) ![]u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle(req, mut out, fd, unsafe { nil }, mut event_loop) == .close {
		return error('handler closed the connection')
	}
	return out
}

fn must_parse(s string) u32 {
	return parse_ipv4(s) or { panic('parse_ipv4 rejected valid input ${s}') }
}

fn test_parse_ipv4() {
	assert must_parse('0.0.0.0') == 0
	assert must_parse('255.255.255.255') == u32(0xffffffff)
	assert must_parse('10.1.2.3') == u32(0x0a010203)
	assert must_parse('127.0.0.1') == u32(0x7f000001)
	for bad in ['', '1.2.3', '1.2.3.4.5', '256.0.0.1', '10.0.0.', '.1.2.3', 'a.b.c.d', '10..0.1',
		'1.2.3.4 ', '0010.0.0.1'] {
		if _ := parse_ipv4(bad) {
			assert false, 'parse_ipv4 must reject ${bad}'
		}
	}
}

fn test_cidr_membership() {
	assert ip_in_cidrs(must_parse('10.0.0.1'), trusted_cidrs)
	assert ip_in_cidrs(must_parse('127.0.0.1'), trusted_cidrs)
	assert !ip_in_cidrs(must_parse('1.2.3.4'), trusted_cidrs)
	// REAL masking, pinned: 10.1.2.3 is inside 10.0.0.0/8 (the old string-
	// prefix sketch got this wrong) and /12 spans 172.16.0.0–172.31.255.255.
	assert ip_in_cidrs(must_parse('10.1.2.3'), trusted_cidrs)
	assert ip_in_cidrs(must_parse('172.31.255.254'), trusted_cidrs)
	assert !ip_in_cidrs(must_parse('172.32.0.1'), trusted_cidrs)
	// /32 is exact-host (the old sketch also matched 127.0.0.2).
	assert !ip_in_cidrs(must_parse('127.0.0.2'), trusted_cidrs)
}

fn test_write_ipv4_and_its_length() {
	for addr in ['0.0.0.0', '255.255.255.255', '10.1.2.3', '127.0.0.1', '192.168.100.9', '1.22.133.4',
		'203.0.113.70'] {
		ip := must_parse(addr)
		mut out := []u8{}
		write_ipv4(mut out, ip)
		assert out.bytestr() == addr
		assert ipv4_len(ip) == addr.len, addr
	}
	// It appends: what is already in `out` stays.
	mut out := 'x='.bytes()
	write_ipv4(mut out, must_parse('8.8.4.4'))
	assert out.bytestr() == 'x=8.8.4.4'
}

fn test_trusted_peer_takes_rightmost_untrusted_hop() ! {
	// Trusted-LB peer => XFF is believed. Chain is client, internal-proxy;
	// the client is the right-most NON-trusted hop.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('1.2.3.4')
	// An attacker pre-seeding the left of the chain changes nothing.
	req2 := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert real_client_ip(req2, must_parse('10.0.0.5'))? == must_parse('1.2.3.4')
}

fn test_non_ipv4_client_hop_reports_the_proxy() ! {
	// The right-most untrusted hop is the client, but it has no IPv4 address
	// to report. Everything left of it is client-written, so the answer must
	// NOT come from there (6.6.6.6 is a forgery): it is the proxy.
	for hop in ['2001:db8::7', 'unknown', '10.0.0.999', 'not-an-ip'] {
		req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, ${hop}, 10.0.0.1\r\n\r\n')
		assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('10.0.0.5'), hop
	}
}

fn test_all_hops_trusted_returns_leftmost() ! {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 10.0.0.9, 172.16.3.4\r\n\r\n')
	assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('10.0.0.9')
}

fn test_empty_hops_are_skipped() ! {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4,, 10.0.0.1,\r\n\r\n')
	assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('1.2.3.4')
}

fn test_whitespace_only_xff_falls_back_to_peer() ! {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For:    \r\n\r\n')
	assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('10.0.0.5')
}

fn test_trusted_peer_without_xff_is_the_client() ! {
	req := mkreq('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	assert real_client_ip(req, must_parse('10.0.0.5'))? == must_parse('10.0.0.5')
}

// SECURITY invariant: when the peer is NOT trusted, forwarding headers are
// ignored entirely — a direct attacker's forged XFF must never stick.
fn test_untrusted_peer_ignores_xff() ! {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert real_client_ip(req, must_parse('203.0.113.7'))? == must_parse('203.0.113.7')
}

fn test_unknown_peer_is_untrusted() {
	// peer_ipv4 returns none on getpeername failure and on a non-IPv4 peer;
	// none must resolve to the untrusted 'unknown' identity, never be trusted.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert real_client_ip(req, none) == none
}

// ---- raw-request E2E through the real handler (fd -1 => no peer) -----------

fn test_e2e_untrusted_peer_full_framing() ! {
	// fd -1 drives the REAL socket.peer_ipv4 call: getpeername(-1) fails, so
	// the peer is none -> untrusted 'unknown' -> the forged XFF is ignored.
	// Exact-byte compare guards the computed Content-Length framing.
	req := 'GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\nX-Forwarded-Proto: https\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	body := '{"client_ip":"unknown","scheme":"https"}'
	assert out == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'
}

fn test_e2e_default_proto() ! {
	req := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	out := serve(req)!.bytestr()
	body := '{"client_ip":"unknown","scheme":"http"}'
	assert out == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'
}

// ---- E2E over a real loopback connection: a trusted 127.0.0.1 peer --------

fn test_e2e_trusted_loopback_peer() ! {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	fd := s.sock.handle
	// 127.0.0.1/32 is a trusted proxy: its XFF is believed (right-most
	// untrusted hop), and without one the peer itself is the client.
	for req, ip in {
		'GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, 203.0.113.70\r\n\r\n': '203.0.113.70'
		'GET / HTTP/1.1\r\nHost: x\r\n\r\n':                                '127.0.0.1'
	} {
		body := '{"client_ip":"${ip}","scheme":"http"}'
		assert serve_fd(req.bytes(), fd)!.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	}
}

// Every outcome — a forwarded client, the trusted peer itself, an unknown
// peer — runs 20k times through one reused buffer, as a worker serves them:
// the collector's allocation counter must not move.
fn test_proxy_aware_allocates_nothing() ! {
	$if gcboehm ? {
		mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
		defer { l.close() or {} }
		mut c := net.dial_tcp(l.addr()!.str())!
		defer { c.close() or {} }
		mut s := l.accept()!
		defer { s.close() or {} }
		fd := s.sock.handle
		forwarded := 'GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, 203.0.113.70, 10.0.0.1\r\nX-Forwarded-Proto: https\r\n\r\n'.bytes()
		direct := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		handle(forwarded, mut out, fd, unsafe { nil }, mut event_loop) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			handle(forwarded, mut out, fd, unsafe { nil }, mut event_loop)
			unsafe {
				out.len = 0
			}
			handle(direct, mut out, fd, unsafe { nil }, mut event_loop)
			unsafe {
				out.len = 0
			}
			handle(direct, mut out, -1, unsafe { nil }, mut event_loop)
		}
		grown := gc_heap_usage().total_bytes - before
		assert out.bytestr().ends_with('{"client_ip":"unknown","scheme":"http"}')
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * 3} requests'
	}
}

fn test_malformed_request_errors() {
	// Malformed input must surface as a handler error, never a response.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
}
