module main

// IP blocking (denylist) — reference design.
//
// Rejects requests from denied client IPs with 403 Forbidden, using the socket
// peer address exposed by Phase 2 (`socket.peer_addr(fd)`). The handler keeps
// the unified `core.Handler` contract — it just reads the client fd's peer
// (client_fd) when it needs to decide.
//
// SECURITY / DESIGN notes:
//   - Blocks by the SOCKET peer. Behind a proxy/CDN the peer IS the proxy, so
//     the real client is in `X-Forwarded-For` — and that header is only
//     trustworthy from known proxies (see examples/proxy_aware). This example
//     blocks the direct peer, which is correct when the server faces clients
//     directly. Swap `socket.peer_addr(fd)` for the proxy-aware real-client-ip
//     when you sit behind a trusted proxy.
//   - The check is a map lookup (O(1), read-mostly under an RwMutex). For large
//     lists or CIDR ranges use a prefix/trie; for a true firewall, block in the
//     kernel (nftables/iptables) — app-level blocking still pays an accept + a
//     getpeername syscall per connection.
//   - The most efficient block is at CONNECTION time (drop on accept). That
//     needs a core accept-hook; here we answer 403 per request at handler level.
import http_server
import http_server.core
import http_server.socket
import sync

// Blocklist is the only shared state: a set of denied IPs, read-mostly.
struct Blocklist {
mut:
	mu  &sync.RwMutex = sync.new_rwmutex()
	ips map[string]bool
}

fn (mut b Blocklist) block(ip string) {
	b.mu.lock()
	b.ips[ip] = true
	b.mu.unlock()
}

fn (mut b Blocklist) unblock(ip string) {
	b.mu.lock()
	b.ips.delete(ip)
	b.mu.unlock()
}

fn (mut b Blocklist) is_blocked(ip string) bool {
	b.mu.rlock()
	blocked := ip in b.ips
	b.mu.runlock()
	return blocked
}

const forbidden_response = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\nallowed'.bytes()

fn handle(_req_bufferreq_buffer []u8, mut out []u8, client_fd int, _worker_stateworker_state voidptr, mut _event_loopevent_loop core.EventLoop, mut blocklist Blocklist) core.Step {
	ip := socket.peer_addr(client_fd)
	if blocklist.is_blocked(ip) {
		eprintln('[ip-block] denied ${ip}')
		out << forbidden_response
		return .done
	}
	out << ok_response
	return .done
}

fn main() {
	mut blocklist := &Blocklist{}
	// Configure denied IPs (from a file/db/env in a real app).
	blocklist.block('10.0.0.5')
	blocklist.block('192.168.1.100')

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
		handler:         fn [mut blocklist] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut
				blocklist)
		}
	})!
	println('IP-block demo on http://localhost:3000/  (denied IPs get 403)')
	server.run()
}
