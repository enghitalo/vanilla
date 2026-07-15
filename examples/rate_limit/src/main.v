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
// WORKS TODAY end to end: the core exposes `socket.peer_addr(fd)` for the
// direct peer IP, and examples/proxy_aware shows the CIDR-trust + right-most-
// untrusted-hop logic for validating X-Forwarded-For behind proxies.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import http_server.socket
import strconv
import sync
import time

struct Bucket {
mut:
	tokens  f64
	last_ns i64
}

// Buckets are never evicted — fine for a demo; production wants an idle sweep.
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
// flakiness. main() passes `i64(time.sys_mono_now())`.
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

// client_key returns the identity to rate-limit on. Order of trust:
//   1. `X-Forwarded-For`, LEFT-MOST hop — ONLY meaningful when the connection
//      comes from a proxy you trust; the header is trivially spoofed otherwise
//      (examples/proxy_aware shows the CIDR-trust validation).
//   2. `socket.peer_addr(fd)` — the core's API for the direct peer IP. The
//      DELIBERATE exception to zero-alloc: one getpeername syscall + one small
//      string, paid only when there is no XFF header.
//   3. 'unknown' — Windows (peer_addr returns '' by design) or getpeername
//      failure: everyone shares one bucket there. Documented, not hidden.
//
// ZERO-COPY: the XFF value is scanned IN PLACE by offsets (comma split + OWS
// trim); the result is an `unsafe tos` VIEW into req.buffer, valid because it
// goes straight into allow() and the V map CLONES string keys on insert
// (vlib/builtin/map.v) — nothing retains the view past this request.
@[direct_array_access]
fn client_key(req request_parser.HttpRequest, fd int) string {
	if s := req.get_header_value_slice('X-Forwarded-For') {
		// Left-most hop = original client (when the chain is trustworthy).
		mut end := s.start + s.len
		for i in s.start .. s.start + s.len {
			if req.buffer[i] == `,` {
				end = i
				break
			}
		}
		mut start := s.start
		for start < end && (req.buffer[start] == ` ` || req.buffer[start] == u8(9)) {
			start++
		}
		for end > start && (req.buffer[end - 1] == ` ` || req.buffer[end - 1] == u8(9)) {
			end--
		}
		if end > start { // empty / whitespace-only XFF falls through
			return unsafe { tos(&req.buffer[start], end - start) }
		}
	}
	p := socket.peer_addr(fd)
	if p.len > 0 {
		return p
	}
	return 'unknown'
}

fn handle(req_buffer []u8, mut out []u8, client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop, mut limiter Limiter) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	key := client_key(req, client_fd)

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
		handler:         fn [mut limiter] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut limiter)
		}
	})!
	println('Rate-limit demo on http://localhost:3000/  (token bucket per client IP)')
	server.run()
}
