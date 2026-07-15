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
// WORKS TODAY end to end: the core exposes `socket.peer_addr(fd)` — the
// connection's peer IP for exactly this kind of decision. It costs one
// getpeername syscall plus one small string per request: the same DELIBERATE
// exception to zero-alloc that examples/rate_limit documents. handle() feeds
// it to the pure trust logic (`real_client_ip`), which tests drive directly
// with injected peers. On Windows peer_addr returns '' by design (as it does
// on getpeername failure); '' is an UNTRUSTED peer with identity 'unknown'.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import http_server.socket
import strconv

// Trusted proxy networks. Only forwarding headers from these are believed.
const trusted_proxies = ['10.0.0.0/8', '172.16.0.0/12', '127.0.0.1/32']

// Parsed ONCE at module init into (network, mask) pairs: per-request membership
// is a parse + mask-and-compare, with zero substring allocations. Real masking
// also fixes what a string-prefix sketch gets wrong — 10.1.2.3 IS inside
// 10.0.0.0/8, and 172.16.0.0/12 spans 172.16.0.0–172.31.255.255.
const trusted_cidrs = parse_cidrs(trusted_proxies)

struct Cidr {
	net  u32 // network address, pre-masked at init
	mask u32
}

// parse_ipv4 converts dotted-quad text to a host-order u32, or `none` when the
// text is not a valid IPv4 address. A byte scan with zero allocations — it runs
// per XFF hop on the hot path — and rejection doubles as hop validation: a
// token that is not an IP can never match a trusted network.
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

// ip_in_cidrs — true when `ip` (dotted-quad text) falls inside any CIDR.
// Parse + mask-compare only; a non-IP `ip` (including '') is never trusted.
fn ip_in_cidrs(ip string, cidrs []Cidr) bool {
	addr := parse_ipv4(ip) or { return false }
	for c in cidrs {
		if (addr & c.mask) == c.net {
			return true
		}
	}
	return false
}

// real_client_ip applies the trust rule over an INJECTED peer — the seam the
// tests drive directly; handle() passes `socket.peer_addr(fd)`. Believe XFF
// only when the peer is a trusted proxy, then take the right-most hop the
// trusted chain didn't add.
//
// ZERO-COPY: the XFF value is scanned IN PLACE from the RIGHT by offsets
// (comma split + OWS trim, numeric u8 comparisons); each hop is an `unsafe
// tos` VIEW into req.buffer — no to_string, no split/map garbage. The views
// are safe because handle() writes the result into `out` synchronously,
// before the request buffer recycles; nothing retains them past this request.
@[direct_array_access]
fn real_client_ip(req request_parser.HttpRequest, peer string) string {
	if !ip_in_cidrs(peer, trusted_cidrs) {
		// Untrusted or unknown peer ('' — Windows by design, or getpeername
		// failure): forwarding headers are not believable.
		return if peer.len > 0 { peer } else { 'unknown' }
	}
	s := req.get_header_value_slice('X-Forwarded-For') or { return peer }
	mut leftmost := '' // left-most valid hop, for the all-hops-trusted case
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
			hop := unsafe { tos(&req.buffer[hs], he - hs) } // view into req.buffer
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
	// client. A whitespace-only XFF leaves no hop at all — fall back to peer.
	return if leftmost.len > 0 { leftmost } else { peer }
}

// ---- response (consts + ws/wi — BEST_PRACTICES §3b) -------------------------
// Only two fields vary (client, scheme). Content-Length = const overhead plus
// their lengths, so the body is framed ONCE, straight into `out` — never built
// as an intermediate string.
const response_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()
const body_pre = '{"client_ip":"'
const body_mid = '","scheme":"'
const body_tail = '"}'
const body_overhead = body_pre.len + body_mid.len + body_tail.len
const default_proto = 'http'

// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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

fn handle(req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	// socket.peer_addr: the deliberate one-syscall/one-string exception — see
	// the header comment. The trust logic itself stays pure.
	client := real_client_ip(req, socket.peer_addr(client_fd))
	// X-Forwarded-Proto as a zero-copy view (len > 0 guard), const fallback.
	// It is client-settable like XFF — a production service should gate it on
	// the same peer trust; the demo echoes it to show the read.
	mut proto := default_proto
	if p := req.get_header_value_slice('X-Forwarded-Proto') {
		if p.len > 0 {
			proto = unsafe { tos(&req.buffer[p.start], p.len) } // view
		}
	}
	out << response_prefix
	wi(mut out, body_overhead + client.len + proto.len)
	ws(mut out, '\r\n\r\n')
	ws(mut out, body_pre)
	ws(mut out, client) // views land in `out` now, before the buffer recycles
	ws(mut out, body_mid)
	ws(mut out, proto)
	ws(mut out, body_tail)
	return .done
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
		handler:         handle
	})!
	println('Proxy-aware demo on http://localhost:3000/  (trust rule: see header comment)')
	server.run()
}
