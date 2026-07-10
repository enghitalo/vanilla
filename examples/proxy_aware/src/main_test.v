module main

import http_server.core
import http_server.http1_1.request_parser

// SOLUTION: the trust rule is pure over an INJECTED peer — real_client_ip
// takes the peer string explicitly, so every branch (trusted, untrusted,
// unknown) is unit-testable. The live path feeds it `socket.peer_addr(fd)`,
// the shipped core API; serve() below passes fd -1, which makes that real
// call fail into '' — driving the untrusted/'unknown' branch end to end.

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect (BEST_PRACTICES §9).
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .close {
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
	assert ip_in_cidrs('10.0.0.1', trusted_cidrs)
	assert ip_in_cidrs('127.0.0.1', trusted_cidrs)
	assert !ip_in_cidrs('1.2.3.4', trusted_cidrs)
	// REAL masking, pinned: 10.1.2.3 is inside 10.0.0.0/8 (the old string-
	// prefix sketch got this wrong) and /12 spans 172.16.0.0–172.31.255.255.
	assert ip_in_cidrs('10.1.2.3', trusted_cidrs)
	assert ip_in_cidrs('172.31.255.254', trusted_cidrs)
	assert !ip_in_cidrs('172.32.0.1', trusted_cidrs)
	// /32 is exact-host (the old sketch also matched 127.0.0.2).
	assert !ip_in_cidrs('127.0.0.2', trusted_cidrs)
	// Non-IP tokens are never trusted — parse failure doubles as validation.
	assert !ip_in_cidrs('', trusted_cidrs)
	assert !ip_in_cidrs('not-an-ip', trusted_cidrs)
	assert !ip_in_cidrs('10.0.0.999', trusted_cidrs)
}

fn test_trusted_peer_takes_rightmost_untrusted_hop() {
	// Trusted-LB peer => XFF is believed. Chain is client, internal-proxy;
	// the client is the right-most NON-trusted hop.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert real_client_ip(req, '10.0.0.5') == '1.2.3.4'
	// An attacker pre-seeding the left of the chain changes nothing.
	req2 := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert real_client_ip(req2, '10.0.0.5') == '1.2.3.4'
}

fn test_all_hops_trusted_returns_leftmost() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 10.0.0.9, 172.16.3.4\r\n\r\n')
	assert real_client_ip(req, '10.0.0.5') == '10.0.0.9'
}

fn test_empty_hops_are_skipped() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4,, 10.0.0.1,\r\n\r\n')
	assert real_client_ip(req, '10.0.0.5') == '1.2.3.4'
}

fn test_whitespace_only_xff_falls_back_to_peer() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For:    \r\n\r\n')
	assert real_client_ip(req, '10.0.0.5') == '10.0.0.5'
}

fn test_trusted_peer_without_xff_is_the_client() {
	req := mkreq('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	assert real_client_ip(req, '10.0.0.5') == '10.0.0.5'
}

// SECURITY invariant: when the peer is NOT trusted, forwarding headers are
// ignored entirely — a direct attacker's forged XFF must never stick.
fn test_untrusted_peer_ignores_xff() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert real_client_ip(req, '203.0.113.7') == '203.0.113.7'
}

fn test_unknown_peer_is_untrusted() {
	// peer_addr returns '' on Windows (by design) and on getpeername failure;
	// '' must resolve to the untrusted 'unknown' identity, never be trusted.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert real_client_ip(req, '') == 'unknown'
}

// ---- raw-request E2E through the real handler (fd -1 => peer_addr '') ------

fn test_e2e_untrusted_peer_full_framing() ! {
	// fd -1 drives the REAL socket.peer_addr call: getpeername(-1) fails, so
	// the peer is '' -> untrusted 'unknown' -> the forged XFF is ignored.
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

fn test_malformed_request_errors() {
	// Malformed input must surface as a handler error, never a response.
	if _ := serve('garbage'.bytes()) {
		assert false, 'garbage request must not produce a response'
	}
}
