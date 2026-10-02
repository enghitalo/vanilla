module main

// Rate limiting — reference design (token bucket per client).
//
// Protects against abuse and accidental floods. The token-bucket algorithm is
// the standard: each client has a bucket that refills at a fixed rate up to a
// cap; each request spends one token; an empty bucket means 429.
//
// WHY TOKEN BUCKET: it allows short bursts (up to bucket size) while bounding
// the sustained rate — the behavior real APIs want. Sliding-window-log is more
// precise but costs more memory; fixed-window is cheap but allows 2x bursts at
// window edges. Token bucket is the sweet spot.
//
// THE HARD PART IS IDENTITY, NOT THE ALGORITHM:
//   The key MUST NOT be client-controlled. `X-Forwarded-For` is a request
//   header: a client can send any value, a new value per request is a new
//   bucket, and a limiter keyed on it never limits. Proxies APPEND to it, so
//   its LEFT-MOST hop is whatever the client wrote. The key is therefore:
//     - the socket peer IP (`socket.peer_addr(fd)`), unless that peer is a
//       proxy YOU run (`trusted_proxies`); then
//     - the RIGHT-MOST `X-Forwarded-For` hop that is not one of your proxies —
//       examples/proxy_aware's trust rule, copied here verbatim.
//   `trusted_proxies` is empty by default (nothing in front of the server), so
//   `X-Forwarded-For` is ignored until you list your own proxies. Trusting too
//   much makes the limiter bypassable; trusting nothing behind a proxy makes
//   every client share the proxy's bucket.
//
// BOUNDED STATE: every new key is a map entry, so an unbounded table is a
//   memory-exhaustion vector. A bucket that has refilled to capacity is
//   identical to a fresh one, so an idle sweep drops it with no effect on any
//   decision; `max_buckets` caps the table on top, failing CLOSED (429) for new
//   keys while it is full.
//
// CORRECT RESPONSE: 429 Too Many Requests + `Retry-After` + the
//   `RateLimit-*` headers (draft standard) so clients can self-throttle.
//
// WORKS TODAY end to end: the core exposes `socket.peer_addr(fd)` for the
// direct peer IP.
import server
import core
import http1_1.request_parser
import http1_1.response
import socket
import strconv
import sync
import time

struct Bucket {
mut:
	tokens  f64
	last_ns i64
}

struct Limiter {
	rate        f64 // tokens added per second
	capacity    f64 // max burst
	max_buckets int = 100_000 // hard cap on tracked clients (~100 B each)
mut:
	mu         &sync.Mutex = sync.new_mutex()
	buckets    map[string]Bucket
	next_sweep i64 // monotonic ns of the next idle sweep
}

// allow refills the client's bucket based on elapsed time, then tries to spend
// one token. Returns (allowed, tokens_remaining).
//
// SOLUTION 4 — the clock is INJECTED (`now`, nanoseconds), not read inside.
// Tests pass a fake clock and advance it deterministically: no sleeps, no
// flakiness. main() passes `i64(time.sys_mono_now())`.
fn (mut l Limiter) allow(client string, now i64) (bool, int) {
	l.mu.lock()
	defer { l.mu.unlock() }
	// Idle sweep, at most once per refill period (`capacity / rate` seconds,
	// the longest an empty bucket takes to refill): its O(n) walk is amortized
	// over every request in that period. rate 0 never refills: nothing to drop.
	if l.rate > 0 && now >= l.next_sweep {
		l.sweep(now)
		l.next_sweep = now + i64(l.capacity / l.rate * 1e9)
	}
	mut b := l.buckets[client] or {
		if l.buckets.len >= l.max_buckets {
			// Table full: fail CLOSED until a sweep frees room. Failing open
			// would hand the bypass back to whoever filled it.
			return false, 0
		}
		Bucket{
			tokens:  l.capacity
			last_ns: now
		}
	}
	elapsed := f64(now - b.last_ns) / 1e9
	b.tokens = math_min(l.capacity, b.tokens + elapsed * l.rate)
	b.last_ns = now
	mut ok := false
	if b.tokens >= 1.0 {
		b.tokens -= 1.0
		ok = true
	}
	l.buckets[client] = b
	return ok, int(b.tokens)
}

// sweep drops every bucket that has refilled to capacity by `now`. A full
// bucket is exactly what allow() creates for a new key, so dropping it changes
// no decision. Caller holds `mu`. Deleting inside the loop is safe: V iterates
// a snapshot of the map (one copy per sweep, not per request).
fn (mut l Limiter) sweep(now i64) {
	for key, b in l.buckets {
		if b.tokens + f64(now - b.last_ns) / 1e9 * l.rate >= l.capacity {
			l.buckets.delete(key)
		}
	}
}

fn math_min(a f64, b f64) f64 {
	return if a < b { a } else { b }
}

// ---- responses (consts — the hot path appends, never builds) ----------------
// The 429 is FULLY static; the 200 only varies in `RateLimit-Remaining`, so it
// splits into two consts around one decimal write. The body `{"ok":true}` is
// fixed (11 bytes), which makes Content-Length a compile-time constant too.
const response_429 = 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nRateLimit-Limit: 10\r\nRateLimit-Remaining: 0\r\nContent-Length: 0\r\n\r\n'.bytes()
const response_200_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nRateLimit-Remaining: '.bytes()
const response_200_tail = '\r\nContent-Length: 11\r\n\r\n{"ok":true}'.bytes()

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

// ---- client identity (examples/proxy_aware's trust rule, verbatim) ----------
// Trusted proxy networks: `X-Forwarded-For` is believed ONLY when the socket
// peer is inside one of these. List only proxies you operate — your load
// balancer's subnet, '127.0.0.1/32' for nginx on the same host — never a range
// clients can connect from. Empty: nothing in front, `X-Forwarded-For` ignored.
const trusted_proxies = []string{}

// Parsed ONCE at module init into (network, mask) pairs: per-request membership
// is a parse + mask-and-compare, with zero substring allocations.
const trusted_cidrs = parse_cidrs(trusted_proxies)

struct Cidr {
	net  u32 // network address, pre-masked at init
	mask u32
}

// parse_ipv4 converts dotted-quad text to a host-order u32, or `none` when the
// text is not a valid IPv4 address. A zero-allocation byte scan; rejection
// doubles as hop validation — a non-IP token never matches a trusted network.
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

// parse_cidrs expands 'a.b.c.d/bits' entries. Runs once at init (and in
// tests), so its substring allocations never touch the hot path. Panics on a
// bad entry: a malformed trust list is a deployment error.
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
// A non-IP `ip` (including '') is never trusted.
fn ip_in_cidrs(ip string, cidrs []Cidr) bool {
	addr := parse_ipv4(ip) or { return false }
	for c in cidrs {
		if (addr & c.mask) == c.net {
			return true
		}
	}
	return false
}

// client_key returns the identity to rate-limit on, over an INJECTED peer and
// trust list (handle() passes `socket.peer_addr(fd)` and `trusted_cidrs`):
//   1. peer NOT trusted: the peer itself. `X-Forwarded-For` is ignored — it is
//      exactly what a spoofing client controls.
//   2. peer trusted: the RIGHT-MOST `X-Forwarded-For` hop that is not a
//      trusted proxy (everything right of it was appended by your proxies; the
//      client can only pre-seed the left). All hops trusted: the left-most.
//      No usable hop: the peer.
//   3. '' peer — Windows (peer_addr returns '' by design) or getpeername
//      failure: 'unknown', one shared bucket. Documented, not hidden.
// `socket.peer_addr` is the DELIBERATE exception to zero-alloc: one
// getpeername syscall + one small string per request.
//
// ZERO-COPY: the XFF value is scanned IN PLACE from the right by offsets
// (comma split + OWS trim); a hop is an `unsafe tos` VIEW into req.buffer,
// valid because it goes straight into allow() and the V map CLONES string
// keys on insert (vlib/builtin/map.v) — nothing retains the view.
@[direct_array_access]
fn client_key(req request_parser.HttpRequest, peer string, trusted []Cidr) string {
	if !ip_in_cidrs(peer, trusted) {
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
		if he > hs { // empty hops (",," / whitespace-only) are skipped
			hop := unsafe { tos(&req.buffer[hs], he - hs) } // view into req.buffer
			if !ip_in_cidrs(hop, trusted) {
				return hop
			}
			leftmost = hop
		}
		end = i
	}
	return if leftmost.len > 0 { leftmost } else { peer }
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut limiter Limiter) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	key := client_key(req, socket.peer_addr(client_fd), trusted_cidrs)

	// sys_mono_now: monotonic ns, no calendar conversion, immune to NTP jumps —
	// exactly what elapsed-time refill needs (time.now() reads CLOCK_REALTIME
	// and pays localtime_r per call).
	allowed, remaining := limiter.allow(key, i64(time.sys_mono_now()))
	if !allowed {
		out << response_429
		return .done
	}
	out << response_200_prefix
	wi(mut out, remaining)
	out << response_200_tail
	return .done
}

fn main() {
	mut limiter := &Limiter{
		rate:     10.0 // 10 req/s sustained
		capacity: 20.0 // burst up to 20
	}
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
		handler:         fn [mut limiter] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut limiter)
		}
	})!
	println('Rate-limit demo on http://localhost:3000/  (token bucket per client IP)')
	srv.run()
}
