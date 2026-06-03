module main

// SOLUTION 4: injected clock => deterministic time-based test, no sleeps.
// Because allow() takes `now` as a parameter, we drive the token bucket through
// time precisely and assert exact allow/deny transitions. This is how anything
// time-dependent (rate limits, timeouts, idle reaping) should be tested.

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
