module main

// Proxy / load-balancer awareness — reference design.
//
// Almost every deployed service sits behind something — a CDN, an L7 load
// balancer, an ingress, nginx. When it does, the TCP peer is the PROXY, not the
// user. The real client facts live in forwarding headers, and trusting them
// naively is a security hole.
//
// THE HEADERS:
//   X-Forwarded-For: client, proxy1, proxy2   (left = original client)
//   X-Forwarded-Proto: https                  (was the user's leg encrypted?)
//   X-Forwarded-Host: app.example.com
//   Forwarded: for=...;proto=...;host=...      (RFC 7239, the standard form)
//
// THE TRUST RULE (the whole point):
//   These headers are CLIENT-SETTABLE. A direct attacker can send
//   `X-Forwarded-For: 1.2.3.4` to forge their IP, bypass IP allowlists, or
//   poison your rate limiter (see examples/rate_limit). So:
//     - ONLY honor forwarding headers when the connection's PEER is a trusted
//       proxy (known CIDR list).
//     - Then take the RIGHT-MOST untrusted hop, not the left-most, as the real
//       client (proxies append; attackers can pre-seed the left).
//   If the peer is NOT a trusted proxy, ignore the headers entirely and use the
//   socket peer IP.
//
// ASPIRATIONAL: this needs the core to expose the socket PEER address to the
// handler (it currently passes only the fd). The trust logic is shown; wire
// `peer_ip` to the real source once available. `getpeername(fd)` is the hook.
import http_server
import http_server.http1_1.request_parser

// Trusted proxy networks. Only forwarding headers from these are believed.
const trusted_proxies = ['10.0.0.0/8', '172.16.0.0/12', '127.0.0.1/32']

// ASPIRATIONAL: derive from getpeername(fd). Placeholder shows the shape.
fn peer_ip(fd int) string {
	// addr := socket.getpeername(fd)  // <-- core should expose this
	return '10.0.0.5' // pretend the connection came from a trusted LB
}

fn ip_in_cidrs(ip string, cidrs []string) bool {
	// A real impl parses CIDRs and masks. Sketch: trust by prefix for clarity.
	for c in cidrs {
		net := c.all_before('/')
		// crude prefix check stands in for proper masking
		if ip.starts_with(net.all_before_last('.')) || (c == '127.0.0.1/32' && ip == '127.0.0.1') {
			return true
		}
	}
	return false
}

// real_client_ip applies the trust rule: believe XFF only from trusted peers,
// and take the right-most hop the trusted chain didn't add.
fn real_client_ip(req request_parser.HttpRequest, fd int) string {
	peer := peer_ip(fd)
	if !ip_in_cidrs(peer, trusted_proxies) {
		return peer // untrusted peer: headers are not believable
	}
	xff := if s := req.get_header_value_slice('X-Forwarded-For') {
		s.to_string(req.buffer)
	} else {
		return peer
	}
	hops := xff.split(',').map(it.trim_space())
	// Walk from the right; the first hop NOT in our trusted set is the client.
	for i := hops.len - 1; i >= 0; i-- {
		if !ip_in_cidrs(hops[i], trusted_proxies) {
			return hops[i]
		}
	}
	return hops.first()
}

fn handle(req_buffer []u8, fd int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	client := real_client_ip(req, fd)
	proto := if p := req.get_header_value_slice('X-Forwarded-Proto') {
		p.to_string(req.buffer)
	} else {
		'http'
	}
	body := '{"client_ip":"${client}","scheme":"${proto}"}'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: handle
	})!
	println('Proxy-aware demo — needs core to expose getpeername(fd). See header for the trust rule.')
	server.run()
}
