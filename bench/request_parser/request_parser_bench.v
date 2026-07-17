module main

// Hot-path micro-benchmark — measurable WITHOUT wrk.
//
// These are the zero-copy, zero-allocation functions the 510k req/s number
// rests on. They're pure (bytes -> Slice), so we can measure ns/op directly
// instead of needing a network load test. Run before/after any change to the
// parser and keep the numbers from regressing.
//
//   v -prod run bench/request_parser_bench.v
//
// (Use -prod: the default debug build is not representative.)
import benchmark
import os
import http1.request_parser

// A realistic request: method + path with a query string + the headers a real
// client sends. The Host header makes it valid HTTP/1.1.
const raw_request = ('GET /users/42/posts?id=123&format=json&page=2 HTTP/1.1\r\n' +
	'Host: example.com\r\n' + 'User-Agent: wrk/4.1\r\n' + 'Accept: application/json\r\n' +
	'Accept-Encoding: gzip, deflate\r\n' + 'Connection: keep-alive\r\n' + '\r\n').bytes()

fn main() {
	// Loop count: BENCH_ITERS env if set (CI uses a smaller value for speed),
	// else 5M for stable local numbers. See bench/ci_bench.sh.
	env_iters := os.getenv('BENCH_ITERS').int()
	iterations := if env_iters > 0 { env_iters } else { 5_000_000 }

	// Sanity-print once so we know we're measuring correct behavior.
	req0 := request_parser.decode_http_request(raw_request) or { panic('decode: ${err}') }
	println('path            = "${req0.path.to_string(req0.buffer)}"')
	enc := req0.get_header_value_slice('Accept-Encoding') or { panic('header lookup failed') }
	println('Accept-Encoding = "${enc.to_string(req0.buffer)}"')
	fmt := req0.get_query_slice('format'.bytes()) or { panic('query lookup failed') }
	println('?format         = "${fmt.to_string(req0.buffer)}"')
	println('iterations      = ${iterations}\n')

	mut acc := 0 // accumulator prevents dead-code elimination

	mut b := benchmark.start()

	// 1) Full parse: request line + header/body split (the per-request cost).
	for _ in 0 .. iterations {
		req := request_parser.decode_http_request(raw_request) or { panic(err) }
		acc += req.path.len
	}
	b.measure('decode_http_request  (full parse)')

	// 2) Header value lookup — zero-copy Slice, case-sensitive memcmp scan.
	req := request_parser.decode_http_request(raw_request) or { panic(err) }
	for _ in 0 .. iterations {
		s := req.get_header_value_slice('Accept-Encoding') or { request_parser.Slice{} }
		acc += s.len
	}
	b.measure('get_header_value_slice')

	// 3) Query parameter lookup — zero-copy Slice, memchr-driven.
	key := 'format'.bytes()
	for _ in 0 .. iterations {
		s := req.get_query_slice(key) or { request_parser.Slice{} }
		acc += s.len
	}
	b.measure('get_query_slice')

	// 4) Request framing — the per-request cost added to read_request in Phase 1.
	// This worst-cases the no-body fast path: full header walk, CL/TE rejected.
	for _ in 0 .. iterations {
		acc += request_parser.frame_request_length(raw_request) or { -1 }
	}
	b.measure('frame_request_length')

	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
