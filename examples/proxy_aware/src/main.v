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
// WORKS TODAY end to end: the core exposes `socket.peer_ipv4(fd)` — the
// connection's peer IPv4 address as a u32, for exactly this kind of decision:
// one getpeername syscall, no allocation. handle() feeds it to the pure trust
// logic (`real_client_ip`, `real_scheme`), which tests drive directly with
// injected peers. A peer with no IPv4 address (getpeername failure, a UDS
// listener) is none: an UNTRUSTED peer with identity 'unknown'.
//
// IPv4 ONLY: addresses are u32s end to end, compared to the CIDRs by mask and
// printed straight into the response. A right-most untrusted hop that is not
// IPv4 (an IPv6 client, the `unknown` token) cannot be reported, and every hop
// left of it is the client's to write, so the answer is the proxy itself.
import server
import core
import http1_1.request_parser
import http1_1.response
import socket
import strconv

// Trusted proxy networks. Only forwarding headers from these are believed.
const trusted_proxies = ['10.0.0.0/8', '172.16.0.0/12', '127.0.0.1/32']

// Parsed ONCE at module init into (network, mask) pairs: per-request membership
// is a mask-and-compare on the u32 address. Real masking also fixes what a
// string-prefix sketch gets wrong — 10.1.2.3 IS inside 10.0.0.0/8, and
// 172.16.0.0/12 spans 172.16.0.0–172.31.255.255.
const trusted_cidrs = parse_cidrs(trusted_proxies)

struct Cidr {
	net  u32 // network address, pre-masked at init
	mask u32
}

// parse_ipv4 converts dotted-quad text to a host-order u32 (the form
// socket.peer_ipv4 returns), or `none` when the text is not a valid IPv4
// address. A byte scan with zero allocations — it runs per XFF hop on the hot
// path.
@[direct_array_access]
fn parse_ipv4(s string) ?u32 {
	mut ip := u32(0)
	mut octet := u32(0)
	mut digits := 0
	mut dots := 0
	for i in 0 .. s.len {
		c := s[i]
		if c == `.` {
			if digits == 0 || dots == 3 {
				return none
			}
			ip = ip << 8 | octet
			octet = 0
			digits = 0
			dots++
		} else if c >= `0` && c <= `9` {
			octet = octet * 10 + u32(c - `0`)
			digits++
			if digits > 3 || octet > 255 {
				return none
			}
		} else {
			return none
		}
	}
	if dots != 3 || digits == 0 {
		return none
	}
	return ip << 8 | octet
}

// parse_cidrs expands 'a.b.c.d/bits' entries. Runs once at init, so the
// substring allocations here never touch the hot path. Panics on a bad entry:
// a malformed trust list is a deployment error, not a runtime condition.
fn parse_cidrs(list []string) []Cidr {
	mut out := []Cidr{cap: list.len}
	for c in list {
		net_txt := c.all_before('/')
		bits := c.all_after('/').int()
		if net_txt.len == c.len || bits < 0 || bits > 32 {
			panic('invalid CIDR in trusted_proxies')
		}
		net := parse_ipv4(net_txt) or { panic('invalid network address in trusted_proxies') }
		mask := if bits == 0 { u32(0) } else { u32(0xffffffff) << u32(32 - bits) }
		out << Cidr{
			net:  net & mask
			mask: mask
		}
	}
	return out
}

// ip_in_cidrs — true when `ip` falls inside any CIDR: a mask-and-compare.
fn ip_in_cidrs(ip u32, cidrs []Cidr) bool {
	for c in cidrs {
		if (ip & c.mask) == c.net {
			return true
		}
	}
	return false
}

// real_client_ip applies the trust rule over an INJECTED peer — the seam the
// tests drive directly; handle() passes `socket.peer_ipv4(fd)`. Believe XFF
// only when the peer is a trusted proxy, then take the right-most hop the
// trusted chain didn't add. none: no peer address, the client is 'unknown'.
//
// ZERO-COPY: the XFF value is scanned IN PLACE from the RIGHT by offsets
// (comma split + OWS trim, numeric u8 comparisons); each hop is an `unsafe
// tos` VIEW into req.buffer that parse_ipv4 turns into a u32 — no to_string,
// no split/map garbage, and nothing retains the view.
@[direct_array_access]
fn real_client_ip(req request_parser.HttpRequest, peer ?u32) ?u32 {
	// Unknown peer (none) or untrusted peer: forwarding headers are not
	// believable.
	p := peer or { return none }
	if !ip_in_cidrs(p, trusted_cidrs) {
		return p
	}
	s := req.get_header_value_slice('X-Forwarded-For') or { return p }
	mut leftmost := p // left-most hop, for the all-hops-trusted case
	mut end := s.start + s.len // exclusive end of the hop being scanned
	for i := s.start + s.len - 1; i >= s.start - 1; i-- {
		// A comma at i — or the virtual one just before the value — closes the
		// hop (i+1 .. end).
		if i >= s.start && req.buffer[i] != `,` {
			continue
		}
		mut hs := i + 1
		mut he := end
		for hs < he && (req.buffer[hs] == ` ` || req.buffer[hs] == u8(9)) {
			hs++
		}
		for he > hs && (req.buffer[he - 1] == ` ` || req.buffer[he - 1] == u8(9)) {
			he--
		}
		if he > hs { // guard: empty hops (",," / whitespace-only) are skipped
			// Not IPv4: no u32 to report, and the hops left of it are the
			// client's to write — the answer is the proxy (see header).
			hop := parse_ipv4(unsafe { tos(&req.buffer[hs], he - hs) }) or { return p }
			// First hop NOT in the trusted set (walking right-to-left) is the
			// client: everything to its right was appended by trusted proxies.
			if !ip_in_cidrs(hop, trusted_cidrs) {
				return hop
			}
			leftmost = hop
		}
		end = i
	}
	// Every hop was a trusted proxy: the left-most is the closest thing to a
	// client. A whitespace-only XFF leaves no hop at all — that is the peer.
	return leftmost
}

// real_scheme applies the same trust rule to X-Forwarded-Proto, over the same
// INJECTED peer: the header is believed only from a trusted proxy, and only
// as `http` or `https` in any case (schemes are case-insensitive, RFC 3986
// §3.1). The answer is one of those two literals, never the header bytes, so
// nothing the client writes reaches the response. Anything else (an
// untrusted or unknown peer, no header, `ftp`, `https, http`) is the
// listener's own scheme, default_proto.
fn real_scheme(req request_parser.HttpRequest, peer ?u32) string {
	p := peer or { return default_proto }
	if !ip_in_cidrs(p, trusted_cidrs) {
		return default_proto
	}
	s := req.get_header_value_slice('X-Forwarded-Proto') or { return default_proto }
	if ci_eq(req.buffer, s, 'https') {
		return 'https'
	}
	if ci_eq(req.buffer, s, 'http') {
		return 'http'
	}
	return default_proto
}

// ci_eq reports whether the Slice holds `lit` in any ASCII case, compared IN
// PLACE. `| 0x20` lowercases an ASCII letter and maps no other byte onto a
// lowercase one, so `lit` must be lowercase letters only.
@[direct_array_access]
fn ci_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if (buf[s.start + i] | 0x20) != lit[i] {
			return false
		}
	}
	return true
}

// ---- response (consts + core.append_str/wi — BEST_PRACTICES §3b) ------------
// Only two fields vary (client, scheme). Content-Length = const overhead plus
// their lengths (ipv4_len for the address), so the body is framed ONCE,
// straight into `out` — never built as an intermediate string.
const response_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const body_pre = '{"client_ip":"'
const body_mid = '","scheme":"'
const body_tail = '"}'
const body_overhead = body_pre.len + body_mid.len + body_tail.len
const default_proto = 'http' // the listener's own scheme: it serves plain HTTP
const unknown_client = 'unknown'

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()` (BEST_PRACTICES §3b).
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// write_ipv4 appends `ip` (host order, as socket.peer_ipv4 returns it) to
// `out` as a dotted quad: four wi calls, no allocation.
fn write_ipv4(mut out []u8, ip u32) {
	wi(mut out, ip >> 24)
	out << u8(`.`)
	wi(mut out, (ip >> 16) & 0xff)
	out << u8(`.`)
	wi(mut out, (ip >> 8) & 0xff)
	out << u8(`.`)
	wi(mut out, ip & 0xff)
}

// ipv4_len is the length of write_ipv4's output (7 to 15 bytes), for
// Content-Length.
fn ipv4_len(ip u32) int {
	mut n := 3 // the dots
	for shift := u32(0); shift < 32; shift += 8 {
		octet := (ip >> shift) & 0xff
		n += if octet >= 100 {
			3
		} else if octet >= 10 {
			2
		} else {
			1
		}
	}
	return n
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	// socket.peer_ipv4: one getpeername syscall, no allocation. The trust
	// logic itself stays pure, and both forwarding headers go through it.
	peer := socket.peer_ipv4(client_fd)
	client := real_client_ip(req, peer)
	proto := real_scheme(req, peer) // 'http' or 'https', never the header bytes
	client_len := if ip := client { ipv4_len(ip) } else { unknown_client.len }
	core.append_str(mut out, response_prefix)
	wi(mut out, body_overhead + client_len + proto.len)
	core.append_str(mut out, '\r\n\r\n')
	core.append_str(mut out, body_pre)
	if ip := client {
		write_ipv4(mut out, ip)
	} else {
		core.append_str(mut out, unknown_client)
	}
	core.append_str(mut out, body_mid)
	core.append_str(mut out, proto)
	core.append_str(mut out, body_tail)
	return .done
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
	})!
	println('Proxy-aware demo on http://localhost:3000/  (trust rule: see header comment)')
	srv.run()
}
