module main

// Middleware hot-path micro-benchmark — measurable WITHOUT wrk.
//
// The middleware pattern (examples/middleware) makes two perf claims; this
// measures both in ns/op so a change can't silently regress them:
//
//   1. insert_after_status_line (an in-place splice into the reused write
//      buffer, zero allocations) is materially cheaper than building a new
//      array per response — both the single-allocation `inject_headers` the
//      example used before and the naive `resp.bytestr()` + string concat +
//      `.bytes()` round-trip. Each variant decorates a response sitting in a
//      reused `out` exactly as its decorator did, and `out` is cleared with
//      clear() after each response, as the epoll worker does after each flush.
//      The allocating variants also slice `out` (`out[start..]`), which marks
//      it as shared, so `trim()` and `clear()` drop it and it is reallocated.
//   2. chain() composition adds only the cost of the (inlinable) wrapper calls
//      — composing N middlewares is ~free versus calling the handler directly.
//
//   v -prod run bench/middleware/middleware_bench.v
//
// (Use -prod: the default debug build is not representative.)
import benchmark
import os
import core
import http1_1.request_parser

fn C.memchr(buf voidptr, c int, n usize) voidptr

const raw_request = 'GET /users/42/posts?id=123&format=json HTTP/1.1\r\nHost: example.com\r\nUser-Agent: wrk/4.1\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n'.bytes()

const base_resp = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}'.bytes()

const headers = ('X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n").bytes()

const headers_str = 'X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n"

// ── approach 1: in-place splice (examples/middleware, examples/security_headers) ─

@[direct_array_access]
fn insert_after_status_line(mut out []u8, start int, hdrs []u8) {
	if hdrs.len == 0 {
		return
	}
	mut end := -1
	for i in start .. out.len - 1 {
		if out[i] == `\r` && out[i + 1] == `\n` {
			end = i + 2
			break
		}
	}
	if end < 0 {
		return
	}
	tail := out.len - end
	out << hdrs
	unsafe {
		p := &u8(out.data)
		vmemmove(p + end + hdrs.len, p + end, tail)
		vmemcpy(p + end, hdrs.data, hdrs.len)
	}
}

// ── approach 2: a new array per response (the old examples/middleware) ────────

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

// ── approach 3: the string round-trip (three allocations) ─────────────────────

fn inject_headers_string(resp []u8, hdrs string) []u8 {
	s := resp.bytestr()
	idx := s.index('\r\n') or { return resp }
	return (s[..idx + 2] + hdrs + s[idx + 2..]).bytes()
}

// ── chain composition (mirrors examples/middleware) ───────────────────────────

type Handler = fn (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step

type Middleware = fn (Handler) Handler

fn chain(app Handler, mw ...Middleware) Handler {
	mut h := app
	for i := mw.len - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}

fn passthrough(next Handler) Handler {
	return fn [next] (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		return next(req, mut out, client_fd, worker_state, mut event_loop)
	}
}

// ── access log line production: old (decode + interpolate) vs new (memchr) ─────

// build_log_line is the access_log.record() body without the fwrite — it measures
// the CPU work of producing one line: one memchr-found prefix copied into a stack
// buffer + the status of the response at out[start] + newline. Zero heap
// allocation, no header parse. Returns the line length.
fn build_log_line(req_buffer []u8, out []u8, start int) int {
	if req_buffer.len < 4 || start < 0 || out.len - start < 12 {
		return 0
	}
	unsafe {
		sp1 := C.memchr(&req_buffer[0], ` `, usize(req_buffer.len))
		if sp1 == nil {
			return 0
		}
		after_method := int(&u8(sp1) - &req_buffer[0]) + 1
		if after_method >= req_buffer.len {
			return 0
		}
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
		vmemcpy(&line[n], &out[start + 9], 3)
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

	// Sanity-print once so we know all three injectors produce the same result.
	mut spliced := base_resp.clone()
	insert_after_status_line(mut spliced, 0, headers)
	a := spliced.bytestr()
	b := inject_headers(base_resp, headers).bytestr()
	c := inject_headers_string(base_resp, headers_str).bytestr()
	println('in-place == single-alloc == string-roundtrip : ${a == b && b == c}')
	println('injected response:\n${a}')
	println('iterations      = ${iterations}\n')

	mut acc := 0 // accumulator prevents dead-code elimination

	mut bm := benchmark.start()

	// 1) in-place splice — zero allocations; `out` keeps its buffer.
	mut out1 := []u8{cap: 4096}
	for _ in 0 .. iterations {
		start := out1.len
		out1 << base_resp
		insert_after_status_line(mut out1, start, headers)
		acc += out1.len
		out1.clear()
	}
	bm.measure('insert_after_status_line (in place, 0 allocs, recommended)')

	// 2) the old decorator: a new array per response, then trim + copy back.
	mut out2 := []u8{cap: 4096}
	for _ in 0 .. iterations {
		start := out2.len
		out2 << base_resp
		injected := inject_headers(out2[start..], headers)
		out2.trim(start)
		out2 << injected
		acc += out2.len
		out2.clear()
	}
	bm.measure('inject_headers           (new array + out[start..], old)')

	// 3) string round-trip — bytestr + concat + bytes, then trim + copy back.
	mut out3 := []u8{cap: 4096}
	for _ in 0 .. iterations {
		start := out3.len
		out3 << base_resp
		injected := inject_headers_string(out3[start..], headers_str)
		out3.trim(start)
		out3 << injected
		acc += out3.len
		out3.clear()
	}
	bm.measure('inject_headers_string    (3 allocs + out[start..], naive)')

	// 4) direct handler call — the baseline for the chain overhead.
	base := fn (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		out << base_resp
		return .done
	}
	// One persistent buffer, cleared per call — mirrors the server's reused
	// per-connection write buffer, so the loop measures call overhead only.
	mut out_buf := []u8{cap: base_resp.len}
	mut event_loop := core.EventLoop{}
	for _ in 0 .. iterations {
		out_buf.clear()
		base([]u8{}, mut out_buf, -1, unsafe { nil }, mut event_loop)
		acc += out_buf.len
	}
	bm.measure('direct handler call      (no middleware)')

	// 5) 3-deep chain — same call through three composed wrappers.
	wrapped := chain(base, passthrough, passthrough, passthrough)
	for _ in 0 .. iterations {
		out_buf.clear()
		wrapped([]u8{}, mut out_buf, -1, unsafe { nil }, mut event_loop)
		acc += out_buf.len
	}
	bm.measure('3-deep chain call        (3 middlewares)')

	// 6) access log line — OLD: full decode + 2× to_string + status + interpolate.
	for _ in 0 .. iterations {
		req := request_parser.decode_http_request(raw_request) or { continue }
		method := req.method.to_string(req.buffer)
		path := req.path.to_string(req.buffer)
		status := base_resp#[9..12].bytestr()
		line := 'method=${method} path=${path} status=${status}\n'
		acc += line.len
	}
	bm.measure('access log line  (old: decode + interpolate)')

	// 7) access log line — NEW: one memchr + assemble in a stack buffer, no parse,
	// no heap allocation (the access_log.record() CPU work, minus the fwrite).
	for _ in 0 .. iterations {
		acc += build_log_line(raw_request, base_resp, 0)
	}
	bm.measure('access log line  (new: memchr + assemble)')

	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
