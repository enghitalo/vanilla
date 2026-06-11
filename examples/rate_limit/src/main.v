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
//   "Per client" means per real client IP. Behind a proxy/CDN the socket peer
//   is the proxy, so the true IP is in `X-Forwarded-For` — but that header is
//   trivially spoofed unless you ONLY trust it from known proxies. See
//   examples/proxy_aware. Getting this wrong makes the limiter either useless
//   (everyone shares the proxy's bucket) or bypassable (spoofed XFF).
//
// CORRECT RESPONSE: 429 Too Many Requests + `Retry-After` + the
//   `RateLimit-*` headers (draft standard) so clients can self-throttle.
//
// WORKS TODAY except real-client-IP extraction, which depends on the core
// exposing the peer address (and on proxy_aware for the XFF trust logic).
import http_server
import http_server.http1_1.request_parser
import sync
import time

struct Bucket {
mut:
	tokens  f64
	last_ns i64
}

struct Limiter {
	rate     f64 // tokens added per second
	capacity f64 // max burst
mut:
	mu      &sync.Mutex = sync.new_mutex()
	buckets map[string]Bucket
}

// allow refills the client's bucket based on elapsed time, then tries to spend
// one token. Returns (allowed, tokens_remaining).
//
// SOLUTION 4 — the clock is INJECTED (`now`, nanoseconds), not read inside.
// Tests pass a fake clock and advance it deterministically: no sleeps, no
// flakiness. main() passes `time.now().unix_nano()`.
fn (mut l Limiter) allow(client string, now i64) (bool, int) {
	l.mu.lock()
	defer { l.mu.unlock() }
	mut b := l.buckets[client] or {
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

fn math_min(a f64, b f64) f64 {
	return if a < b { a } else { b }
}

// ASPIRATIONAL: real client IP. Until the core exposes the peer address and
// proxy_aware validates X-Forwarded-For, this falls back to a constant — which
// makes the limiter global. Wire `client_key` to the true IP when available.
fn client_key(req request_parser.HttpRequest) string {
	if xff := req.get_header_value_slice('X-Forwarded-For') {
		// ONLY trust this if the connection came from a known proxy (see
		// proxy_aware). Take the left-most hop as the client.
		s := xff.to_string(req.buffer)
		return s.all_before(',').trim_space()
	}
	return 'unknown' // <-- replace with socket peer IP from the core
}

fn handle(req_buffer []u8, _ int, mut limiter Limiter) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	key := client_key(req)

	allowed, remaining := limiter.allow(key, time.now().unix_nano())
	if !allowed {
		return ('HTTP/1.1 429 Too Many Requests\r\n' + 'Retry-After: 1\r\n' +
			'RateLimit-Limit: 10\r\n' + 'RateLimit-Remaining: 0\r\n' + 'Content-Length: 0\r\n\r\n').bytes()
	}
	body := '{"ok":true}'
	return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nRateLimit-Remaining: ${remaining}\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
}

fn main() {
	mut limiter := &Limiter{
		rate:     10.0 // 10 req/s sustained
		capacity: 20.0 // burst up to 20
	}
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
		request_handler: fn [mut limiter] (req_buffer []u8, fd int) ![]u8 {
			return handle(req_buffer, fd, mut limiter)
		}
	})!
	println('Rate-limit demo on http://localhost:3000/  (token bucket; needs real client IP from core)')
	server.run()
}
