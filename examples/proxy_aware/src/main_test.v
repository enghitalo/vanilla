module main

import http_server.http1_1.request_parser

// SOLUTION: pure logic test — works today.
// The whole security of proxy-awareness is the trust rule, which is pure given
// an injectable peer. peer_ip() is the seam: the example stubs it to a trusted
// LB; once the core exposes getpeername(fd), the same tests drive real peers.

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

fn test_cidr_membership() {
	assert ip_in_cidrs('10.0.0.1', trusted_proxies)
	assert ip_in_cidrs('127.0.0.1', trusted_proxies)
	assert !ip_in_cidrs('1.2.3.4', trusted_proxies)
}

fn test_trusted_peer_takes_rightmost_untrusted_hop() {
	// peer_ip() (stubbed trusted LB) => XFF is believed. Chain is
	// client, internal-proxy; the client is the right-most NON-trusted hop.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert real_client_ip(req, 0) == '1.2.3.4'
}

fn test_forwarded_proto_read() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-Proto: https\r\n\r\n')
	if p := req.get_header_value_slice('X-Forwarded-Proto') {
		assert p.to_string(req.buffer) == 'https'
	} else {
		assert false
	}
}

// SECURITY note encoded as a test expectation: when the peer is NOT trusted,
// forwarding headers must be ignored entirely (can't assert here until the core
// exposes the real peer; peer_ip() is stubbed trusted). Documented for when the
// getpeername(fd) hook lands.
