module main

// Middleware hot-path micro-benchmark — measurable WITHOUT wrk.
//
// The middleware pattern (examples/middleware) makes two perf claims; this
// measures both in ns/op so a change can't silently regress them:
//
//   1. inject_headers (single allocation) is materially cheaper than the naive
//      `resp.bytestr()` + string concat + `.bytes()` (three allocations) that
//      the older security_headers example used to decorate every response.
//   2. chain() composition adds only the cost of the (inlinable) wrapper calls
//      — composing N middlewares is ~free versus calling the handler directly.
//
//   v -prod run bench/middleware/middleware_bench.v
//
// (Use -prod: the default debug build is not representative.)
import benchmark
import os
import http_server.http1_1.request_parser

fn C.memchr(buf voidptr, c int, n usize) voidptr

const raw_request = 'GET /users/42/posts?id=123&format=json HTTP/1.1\r\nHost: example.com\r\nUser-Agent: wrk/4.1\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n'.bytes()

const base_resp = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}'.bytes()

const headers = ('X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n").bytes()

const headers_str = 'X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n"

// ── approach 1: single allocation (the recommended primitive) ─────────────────

@[inline]
fn index_after_status_line(b []u8) int {
	for i in 0 .. b.len - 1 {
		if b[i] == `\r` && b[i + 1] == `\n` {
			return i + 2
		}
	}
	return -1
}

fn inject_headers(resp []u8, hdrs []u8) []u8 {
	nl := index_after_status_line(resp)
	if nl < 0 || hdrs.len == 0 {
		return resp
	}
	mut out := []u8{cap: resp.len + hdrs.len}
	out << resp[..nl]
	out << hdrs
	out << resp[nl..]
	return out
}

// ── approach 2: the string round-trip (what security_headers does) ────────────

fn inject_headers_string(resp []u8, hdrs string) []u8 {
	s := resp.bytestr()
	idx := s.index('\r\n') or { return resp }
	return (s[..idx + 2] + hdrs + s[idx + 2..]).bytes()
}

// ── chain composition (mirrors examples/middleware) ───────────────────────────

type Handler = fn (req []u8, fd int, mut out []u8) !

type Middleware = fn (Handler) Handler

fn chain(app Handler, mw ...Middleware) Handler {
	mut h := app
	for i := mw.len - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}

fn passthrough(next Handler) Handler {
	return fn [next] (req []u8, fd int, mut out []u8) ! {
		next(req, fd, mut out)!
	}
}

// ── access log line production: old (decode + interpolate) vs new (memchr) ─────

// build_log_line is the access_log.record() body without the fwrite — it measures
// the CPU work of producing one line: one memchr-found prefix copied into a stack
// buffer + status + newline. Zero heap allocation, no header parse. Returns the
// line length.
fn build_log_line(req_buffer []u8, resp []u8) int {
	if req_buffer.len < 4 || resp.len < 12 {
		return 0
	}
	unsafe {
		sp1 := C.memchr(&req_buffer[0], ` `, usize(req_buffer.len))
		if sp1 == nil {
			return 0
		}
		after_method := int(&u8(sp1) - &req_buffer[0]) + 1
		sp2 := C.memchr(&req_buffer[after_method], ` `, usize(req_buffer.len - after_method))
		if sp2 == nil {
			return 0
		}
		prefix_len := int(&u8(sp2) - &req_buffer[0])
		mut line := [512]u8{}
		if prefix_len + 5 > line.len {
			return 0
		}
		vmemcpy(&line[0], &req_buffer[0], prefix_len)
		mut n := prefix_len
		line[n] = ` `
		n++
		vmemcpy(&line[n], &resp[9], 3)
		n += 3
		line[n] = `\n`
		n++
		return n
	}
}

fn main() {
	// Loop count: BENCH_ITERS env if set (CI uses a smaller value for speed),
	// else 5M for stable local numbers. See bench/ci_bench.sh.
	env_iters := os.getenv('BENCH_ITERS').int()
	iterations := if env_iters > 0 { env_iters } else { 5_000_000 }

	// Sanity-print once so we know both injectors produce the same result.
	a := inject_headers(base_resp, headers).bytestr()
	b := inject_headers_string(base_resp, headers_str).bytestr()
	println('single-alloc == string-roundtrip : ${a == b}')
	println('injected response:\n${a}')
	println('iterations      = ${iterations}\n')

	mut acc := 0 // accumulator prevents dead-code elimination

	mut bm := benchmark.start()

	// 1) inject_headers — single allocation.
	for _ in 0 .. iterations {
		out := inject_headers(base_resp, headers)
		acc += out.len
	}
	bm.measure('inject_headers        (1 alloc, recommended)')

	// 2) string round-trip — three allocations (bytestr + concat + bytes).
	for _ in 0 .. iterations {
		out := inject_headers_string(base_resp, headers_str)
		acc += out.len
	}
	bm.measure('inject_headers_string (3 allocs, naive)')

	// 3) direct handler call — the baseline for the chain overhead.
	base := fn (req []u8, fd int, mut out []u8) ! {
		out << base_resp
	}
	// One persistent buffer, cleared per call — mirrors the server's reused
	// per-connection write buffer, so the loop measures call overhead only.
	mut out_buf := []u8{cap: base_resp.len}
	for _ in 0 .. iterations {
		out_buf.clear()
		base([]u8{}, -1, mut out_buf) or {}
		acc += out_buf.len
	}
	bm.measure('direct handler call   (no middleware)')

	// 4) 3-deep chain — same call through three composed wrappers.
	wrapped := chain(base, passthrough, passthrough, passthrough)
	for _ in 0 .. iterations {
		out_buf.clear()
		wrapped([]u8{}, -1, mut out_buf) or {}
		acc += out_buf.len
	}
	bm.measure('3-deep chain call     (3 middlewares)')

	// 5) access log line — OLD: full decode + 2× to_string + status + interpolate.
	for _ in 0 .. iterations {
		req := request_parser.decode_http_request(raw_request) or { continue }
		method := req.method.to_string(req.buffer)
		path := req.path.to_string(req.buffer)
		status := base_resp#[9..12].bytestr()
		line := 'method=${method} path=${path} status=${status}\n'
		acc += line.len
	}
	bm.measure('access log line  (old: decode + interpolate)')

	// 6) access log line — NEW: one memchr + assemble in a stack buffer, no parse,
	// no heap allocation (the access_log.record() CPU work, minus the fwrite).
	for _ in 0 .. iterations {
		acc += build_log_line(raw_request, base_resp)
	}
	bm.measure('access log line  (new: memchr + assemble)')

	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
