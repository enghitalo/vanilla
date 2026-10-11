module main

// SOLUTION 4: injected clock => deterministic time-based test, no sleeps.
// Because allow() takes `now` as a parameter, we drive the token bucket through
// time precisely and assert exact allow/deny transitions. This is how anything
// time-dependent (rate limits, timeouts, idle reaping) should be tested.
//
// The identity is pure too: client_key() takes the peer and the trust list as
// parameters, so the spoofing cases run with injected peers. The E2E tests
// below feed raw request bytes to handle() through the serve() adapter
// (BEST_PRACTICES §9) — no listening socket. handle() reads the real monotonic
// clock, so E2E limiters use rate 0.0 (no refill) to stay deterministic;
// refill-over-time is covered by the injected-clock unit tests.
// (`${}` here is TEST scaffolding — the example code itself never
// concatenates; see main.v.)
import core
import http1_1.request_parser
import net

const sec = i64(1_000_000_000) // 1s in nanoseconds

// Bucket keys are IPv4 addresses as u32; any u32 will do for the algorithm.
const alice = u32(1)
const bob = u32(2)

// ip parses a test address into the u32 form client_key returns.
fn ip(s string) u32 {
	return parse_ipv4(s) or { panic('bad test address ${s}') }
}

fn test_token_bucket_burst_then_deny() {
	mut l := Limiter{
		rate:     1.0 // 1 token/s refill
		capacity: 2.0 // burst of 2
	}
	t := i64(0)
	a1, _ := l.allow(alice, t) // 2 -> 1
	a2, _ := l.allow(alice, t) // 1 -> 0
	a3, _ := l.allow(alice, t) // 0 -> DENY
	assert a1 && a2 && !a3
}

fn test_refill_over_time() {
	mut l := Limiter{
		rate:     1.0
		capacity: 2.0
	}
	mut t := i64(0)
	l.allow(alice, t)
	l.allow(alice, t) // bucket drained to 0
	denied, _ := l.allow(alice, t)
	assert !denied // still empty at t=0

	t += sec // advance 1s -> +1 token (deterministic, no real waiting)
	allowed, _ := l.allow(alice, t)
	assert allowed
}

fn test_per_client_isolation() {
	mut l := Limiter{
		rate:     1.0
		capacity: 1.0
	}
	t := i64(0)
	a, _ := l.allow(alice, t)
	b, _ := l.allow(bob, t) // different bucket, not affected by alice
	assert a && b
	a2, _ := l.allow(alice, t)
	assert !a2 // alice's single token is spent
}

// ---- bounded state ----------------------------------------------------------

fn test_idle_sweep_drops_refilled_buckets() {
	mut l := Limiter{
		rate:     1.0
		capacity: 2.0 // refill period = capacity / rate = 2s
	}
	for i in 0 .. 50 {
		l.allow(u32(i), 0)
	}
	assert l.buckets.len == 50
	// Half a period later nothing has refilled, and no sweep is due yet.
	late := u32(1000)
	l.allow(late, sec)
	assert l.buckets.len == 51
	// One full period after the first request: the 50 buckets have refilled to
	// capacity (indistinguishable from fresh ones) and the sweep drops them.
	// `late` spent its token at 1s, so at 2s it is still short of capacity.
	l.allow(late, 2 * sec)
	assert l.buckets.len == 1
	assert late in l.buckets
}

fn test_sweep_never_changes_a_decision() {
	mut l := Limiter{
		rate:     1.0
		capacity: 2.0
	}
	l.allow(alice, 0)
	l.allow(alice, 0) // drained at t=0
	// At 2s the bucket is full again whether or not it was swept: a fresh one
	// allows the same burst of 2, then denies.
	a1, _ := l.allow(alice, 2 * sec)
	a2, _ := l.allow(alice, 2 * sec)
	a3, _ := l.allow(alice, 2 * sec)
	assert a1 && a2 && !a3
}

fn test_bucket_table_is_capped_and_fails_closed() {
	mut l := Limiter{
		rate:        0.0 // no refill => no sweep: the cap alone bounds the table
		capacity:    5.0
		max_buckets: 3
	}
	for i in 0 .. 1000 {
		allowed, _ := l.allow(u32(i), 0)
		assert allowed == (i < 3), 'client ${i}'
	}
	assert l.buckets.len == 3
	// Clients already tracked keep their own buckets while the table is full.
	allowed, _ := l.allow(0, 0)
	assert allowed
}

// ---- identity: the key is never client-controlled --------------------------

fn mkreq(s string) request_parser.HttpRequest {
	return request_parser.decode_http_request(s.bytes()) or { panic(err) }
}

const lb_cidrs = parse_cidrs(['10.0.0.0/8'])

fn test_default_trust_list_is_empty() {
	assert trusted_proxies.len == 0
	// Even a loopback/private peer's XFF is ignored until you list your proxies.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert client_key(req, ip('127.0.0.1'), trusted_cidrs) == ip('127.0.0.1')
	assert client_key(req, ip('10.0.0.5'), trusted_cidrs) == ip('10.0.0.5')
}

fn test_untrusted_peer_ignores_xff() {
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert client_key(req, ip('203.0.113.7'), lb_cidrs) == ip('203.0.113.7')
}

fn test_unknown_peer_is_untrusted() {
	// No peer address (getpeername failed, a UDS listener): key 0, the one
	// shared 'unknown' bucket — never the forged header.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n')
	assert client_key(req, none, lb_cidrs) == 0
}

fn test_trusted_proxy_takes_rightmost_untrusted_hop() {
	// "spoofed, client, internal-proxy": the client is the right-most hop the
	// trusted chain did not add; the pre-seeded left-most hop is ignored.
	req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, 1.2.3.4, 10.0.0.1\r\n\r\n')
	assert client_key(req, ip('10.0.0.5'), lb_cidrs) == ip('1.2.3.4')
	// OWS trimmed, empty hops skipped.
	req2 := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For:  1.2.3.4 ,, 10.0.0.1,\r\n\r\n')
	assert client_key(req2, ip('10.0.0.5'), lb_cidrs) == ip('1.2.3.4')
}

fn test_non_ipv4_client_hop_keys_on_the_proxy() {
	// The right-most untrusted hop is the client, but an IPv6 address (or
	// `unknown`, or garbage) has no u32 key. Everything left of it is the
	// client's to write, so the key must NOT come from there: it is the proxy.
	for hop in ['2001:db8::7', 'unknown', '1.2.3.4.5', '_hidden'] {
		req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 6.6.6.6, ${hop}, 10.0.0.1\r\n\r\n')
		assert client_key(req, ip('10.0.0.5'), lb_cidrs) == ip('10.0.0.5'), hop
	}
}

fn test_trusted_proxy_edge_cases() {
	// No XFF, or nothing usable in it: the proxy itself.
	assert client_key(mkreq('GET / HTTP/1.1\r\nHost: x\r\n\r\n'), ip('10.0.0.5'), lb_cidrs) == ip('10.0.0.5')
	assert client_key(mkreq('GET / HTTP/1.1\r\nX-Forwarded-For:   \r\n\r\n'), ip('10.0.0.5'),
		lb_cidrs) == ip('10.0.0.5')
	// Every hop trusted: the left-most is the closest thing to a client.
	assert client_key(mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 10.0.0.9, 10.1.2.3\r\n\r\n'),
		ip('10.0.0.5'), lb_cidrs) == ip('10.0.0.9')
}

fn test_spoofed_xff_behind_trusted_proxy_shares_one_bucket() {
	// The bypass from #193: a fresh X-Forwarded-For per request. Behind a
	// trusted proxy the client controls only the LEFT part — the proxy appends
	// the real address — so every request lands in the same bucket.
	mut l := Limiter{
		rate:     0.0
		capacity: 3.0
	}
	for i in 0 .. 50 {
		req := mkreq('GET / HTTP/1.1\r\nX-Forwarded-For: 198.51.100.${i}, 192.0.2.7\r\n\r\n')
		allowed, _ := l.allow(client_key(req, ip('10.0.0.5'), lb_cidrs), 0)
		assert allowed == (i < 3), 'request ${i}'
	}
	assert l.buckets.len == 1
	assert ip('192.0.2.7') in l.buckets
}

// ---- E2E through the real handler (fd -1 => no peer => 'unknown') -----------

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect. fd = -1 makes
// socket.peer_ipv4 return none => the key is 0, 'unknown'.
fn serve(req string, mut l Limiter) !string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop, mut l) == .close {
		return error('handler closed the connection')
	}
	return out.bytestr()
}

fn test_e2e_200_has_remaining_and_exact_framing() ! {
	mut l := Limiter{
		rate:     0.0
		capacity: 10.0
	}
	resp := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n', mut l)!
	// The whole response is deterministic: prefix + remaining(9) + tail.
	assert resp == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nRateLimit-Remaining: 9\r\nContent-Length: 11\r\n\r\n{"ok":true}'
}

fn test_e2e_capacity_exhaustion_returns_const_429() ! {
	mut l := Limiter{
		rate:     0.0 // no refill => exhaustion is deterministic under the real clock
		capacity: 2.0
	}
	req := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
	assert serve(req, mut l)!.starts_with('HTTP/1.1 200')
	assert serve(req, mut l)!.starts_with('HTTP/1.1 200')
	denied := serve(req, mut l)!
	assert denied == response_429 // exactly the const bytes
	assert denied.contains('Retry-After: 1')
}

fn test_e2e_spoofed_xff_does_not_bypass_the_limit() ! {
	// N requests from ONE peer, each with a different forged X-Forwarded-For:
	// limited after `capacity`, and the table holds one bucket, not N.
	mut l := Limiter{
		rate:     0.0
		capacity: 5.0
	}
	for i in 0 .. 100 {
		resp := serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.${i}\r\n\r\n', mut
			l)!
		want := if i < 5 { 'HTTP/1.1 200' } else { 'HTTP/1.1 429' }
		assert resp.starts_with(want), 'request ${i}: ${resp}'
	}
	assert l.buckets.len == 1
}

fn test_e2e_malformed_request_is_an_error() {
	mut l := Limiter{
		rate:     0.0
		capacity: 1.0
	}
	// Malformed input must surface as a handler error, never a response.
	if _ := serve('garbage', mut l) {
		assert false, 'garbage bytes must not produce a response'
	}
	if _ := serve('GET / HT', mut l) {
		assert false, 'truncated request line must not produce a response'
	}
}

// ---- the steady state allocates nothing ------------------------------------

// A client that already has a bucket — allowed or denied, keyed on the real
// socket peer — runs 20k times through one reused buffer, as a worker serves
// it; so does the trusted-proxy XFF scan. The collector's allocation counter
// must not move. (Under `-gc none`, the production build, any allocation here
// would be a permanent leak.)
fn test_rate_limit_allocates_nothing() ! {
	$if gcboehm ? {
		mut ln := net.listen_tcp(.ip, '127.0.0.1:0')!
		defer { ln.close() or {} }
		mut c := net.dial_tcp(ln.addr()!.str())!
		defer { c.close() or {} }
		mut s := ln.accept()!
		defer { s.close() or {} }
		fd := s.sock.handle
		mut open := Limiter{
			rate:     0.0
			capacity: 1e9 // stays allowed: the 200 path
		}
		mut full := Limiter{
			rate:     0.0
			capacity: 1.0 // denied after the first request: the 429 path
		}
		req := 'GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 6.6.6.6, 1.2.3.4, 10.0.0.1\r\n\r\n'.bytes()
		parsed := mkreq(req.bytestr())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for _ in 0 .. 2 { // warm-up: the buckets exist, `out` is at its high-water mark
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut open)
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut full)
		}
		assert open.buckets.len == 1 && ip('127.0.0.1') in open.buckets
		mut keys := u64(0)
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut open)
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut full)
			keys += client_key(parsed, ip('10.0.0.5'), lb_cidrs)
		}
		grown := gc_heap_usage().total_bytes - before
		assert out.bytestr() == response_429
		assert keys == u64(rounds) * ip('1.2.3.4')
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * 3} calls'
	}
}
