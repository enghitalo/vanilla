module main

// SOLUTION 4: injected clock => deterministic time-based test, no sleeps.
// Because allow() takes `now` as a parameter, we drive the token bucket through
// time precisely and assert exact allow/deny transitions. This is how anything
// time-dependent (rate limits, timeouts, idle reaping) should be tested.
//
// The E2E tests below feed raw request bytes to handle() through the serve()
// adapter (BEST_PRACTICES §9) — no listening socket. handle() reads the real
// monotonic clock, so E2E limiters use rate 0.0 (no refill) to stay
// deterministic; refill-over-time is covered by the injected-clock unit tests.
// (`${}` here is TEST scaffolding — the example code itself never
// concatenates; see main.v.)

const sec = i64(1_000_000_000) // 1s in nanoseconds

fn test_token_bucket_burst_then_deny() {
	mut l := Limiter{
		rate:     1.0 // 1 token/s refill
		capacity: 2.0 // burst of 2
	}
	t := i64(0)
	a1, _ := l.allow('ip', t) // 2 -> 1
	a2, _ := l.allow('ip', t) // 1 -> 0
	a3, _ := l.allow('ip', t) // 0 -> DENY
	assert a1 && a2 && !a3
}

fn test_refill_over_time() {
	mut l := Limiter{
		rate:     1.0
		capacity: 2.0
	}
	mut t := i64(0)
	l.allow('ip', t)
	l.allow('ip', t) // bucket drained to 0
	denied, _ := l.allow('ip', t)
	assert !denied // still empty at t=0

	t += sec // advance 1s -> +1 token (deterministic, no real waiting)
	allowed, _ := l.allow('ip', t)
	assert allowed
}

fn test_per_client_isolation() {
	mut l := Limiter{
		rate:     1.0
		capacity: 1.0
	}
	t := i64(0)
	a, _ := l.allow('alice', t)
	b, _ := l.allow('bob', t) // different bucket, not affected by alice
	assert a && b
	a2, _ := l.allow('alice', t)
	assert !a2 // alice's single token is spent
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect. fd = -1 makes
// socket.peer_addr fail => the no-XFF identity is 'unknown'.
fn serve(req string, mut l Limiter) !string {
	mut out := []u8{}
	handle(req.bytes(), -1, mut out, mut l)!
	return out.bytestr()
}

fn test_e2e_200_has_remaining_and_exact_framing() ! {
	mut l := Limiter{
		rate:     0.0
		capacity: 10.0
	}
	resp := serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n', mut l)!
	// The whole response is deterministic: prefix + remaining(9) + tail.
	assert resp == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nRateLimit-Remaining: 9\r\nContent-Length: 11\r\n\r\n{"ok":true}'
}

fn test_e2e_capacity_exhaustion_returns_const_429() ! {
	mut l := Limiter{
		rate:     0.0 // no refill => exhaustion is deterministic under the real clock
		capacity: 2.0
	}
	req := 'GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 9.9.9.9\r\n\r\n'
	assert serve(req, mut l)!.starts_with('HTTP/1.1 200')
	assert serve(req, mut l)!.starts_with('HTTP/1.1 200')
	denied := serve(req, mut l)!
	assert denied == response_429.bytestr() // exactly the const bytes
	assert denied.contains('Retry-After: 1')
}

fn test_e2e_xff_identities_get_isolated_buckets() ! {
	mut l := Limiter{
		rate:     0.0
		capacity: 1.0
	}
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: alice\r\n\r\n', mut l)!.starts_with('HTTP/1.1 200')
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: bob\r\n\r\n', mut l)!.starts_with('HTTP/1.1 200') // bob unaffected by alice
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: alice\r\n\r\n', mut l)!.starts_with('HTTP/1.1 429') // alice's token is spent
}

fn test_e2e_xff_comma_chain_uses_leftmost_hop() ! {
	mut l := Limiter{
		rate:     0.0
		capacity: 1.0
	}
	// "client, proxy1, proxy2" — identity must be the left-most hop, OWS-trimmed.
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For:  1.1.1.1 , 2.2.2.2\r\n\r\n', mut l)!.starts_with('HTTP/1.1 200')
	// Same left-most hop, different chain => SAME bucket => denied.
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 1.1.1.1\r\n\r\n', mut l)!.starts_with('HTTP/1.1 429')
	// The second hop was never the identity => its bucket is untouched.
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 2.2.2.2\r\n\r\n', mut l)!.starts_with('HTTP/1.1 200')
}

fn test_e2e_empty_xff_falls_back_to_shared_bucket() ! {
	mut l := Limiter{
		rate:     0.0
		capacity: 1.0
	}
	// Whitespace-only XFF falls through to peer_addr(-1) = '' => 'unknown' —
	// the same bucket a request WITHOUT the header lands in.
	assert serve('GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For:   \r\n\r\n', mut l)!.starts_with('HTTP/1.1 200')
	assert serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n', mut l)!.starts_with('HTTP/1.1 429')
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
