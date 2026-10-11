module main

// IP blocking (denylist) — reference design.
//
// Rejects requests from denied client IPs with 403 Forbidden, using the socket
// peer address (`socket.peer_ipv4(fd)`: the IPv4 address as a u32, no
// allocation). The handler keeps the unified `core.Handler` contract — it just
// reads the client fd's peer (client_fd) when it needs to decide.
//
// SECURITY / DESIGN notes:
//   - Blocks by the SOCKET peer. Behind a proxy/CDN the peer IS the proxy, so
//     the real client is in `X-Forwarded-For` — and that header is only
//     trustworthy from known proxies (see examples/proxy_aware). This example
//     blocks the direct peer, which is correct when the server faces clients
//     directly. Swap `socket.peer_ipv4(fd)` for the proxy-aware real-client-ip
//     when you sit behind a trusted proxy.
//   - The list holds u32 addresses, parsed from text once when configured, so
//     the check is a u32 map lookup (O(1), read-mostly under an RwMutex) and a
//     request allocates nothing. For large lists or CIDR ranges use a
//     prefix/trie; for a true firewall, block in the kernel
//     (nftables/iptables) — app-level blocking still pays an accept + a
//     getpeername syscall per connection.
//   - A peer with no IPv4 address (getpeername failure, a UDS listener) is on
//     no IPv4 list: it is allowed. On UDS, identify callers with
//     `socket.peer_cred` instead.
//   - No log line per denial: a blocked client could otherwise force a stderr
//     write (and, with `${}`, an allocation) on every request it sends. Count
//     denials, or log once per connection, if you need them.
//   - The most efficient block is at CONNECTION time (drop on accept). That
//     needs a core accept-hook; here we answer 403 per request at handler level.
import server
import core
import socket
import sync

// Blocklist is the only shared state: a set of denied IPv4 addresses (host
// order, as socket.peer_ipv4 returns them), read-mostly.
struct Blocklist {
mut:
	mu  &sync.RwMutex = sync.new_rwmutex()
	ips map[u32]bool
}

// block and unblock take dotted-quad text: configuration, not the hot path.
fn (mut b Blocklist) block(ip string) ! {
	addr := parse_ipv4(ip) or { return error('invalid IPv4 address: ${ip}') }
	b.mu.lock()
	b.ips[addr] = true
	b.mu.unlock()
}

fn (mut b Blocklist) unblock(ip string) ! {
	addr := parse_ipv4(ip) or { return error('invalid IPv4 address: ${ip}') }
	b.mu.lock()
	b.ips.delete(addr)
	b.mu.unlock()
}

fn (mut b Blocklist) is_blocked(ip u32) bool {
	b.mu.rlock()
	blocked := ip in b.ips
	b.mu.runlock()
	return blocked
}

// parse_ipv4 converts dotted-quad text to a host-order u32, or `none` when the
// text is not a valid IPv4 address (the parser examples/rate_limit and
// examples/proxy_aware use).
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

const forbidden_response = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\nallowed'

fn handle(_req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut blocklist Blocklist) core.Step {
	if ip := socket.peer_ipv4(client_fd) {
		if blocklist.is_blocked(ip) {
			core.append_str(mut out, forbidden_response)
			return .done
		}
	}
	core.append_str(mut out, ok_response)
	return .done
}

fn main() {
	mut blocklist := &Blocklist{}
	// Configure denied IPs (from a file/db/env in a real app).
	blocklist.block('10.0.0.5')!
	blocklist.block('192.168.1.100')!

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
		handler:         fn [mut blocklist] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut
				blocklist)
		}
	})!
	println('IP-block demo on http://localhost:3000/  (denied IPs get 403)')
	srv.run()
}
