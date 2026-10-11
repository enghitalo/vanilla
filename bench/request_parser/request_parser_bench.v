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
import http1_1.request_parser

// A realistic request: method + path with a query string + the headers a real
// client sends. The Host header makes it valid HTTP/1.1.
const raw_request = ('GET /users/42/posts?id=123&format=json&page=2 HTTP/1.1\r\n' +
	'Host: example.com\r\n' + 'User-Agent: wrk/4.1\r\n' + 'Accept: application/json\r\n' +
	'Accept-Encoding: gzip, deflate\r\n' + 'Connection: keep-alive\r\n' + '\r\n').bytes()

// A chunked upload: three chunks (one with an extension) and the last chunk,
// without and with a trailer section.
const chunked_request = ('POST /upload HTTP/1.1\r\n' + 'Host: example.com\r\n' +
	'Transfer-Encoding: chunked\r\n' + '\r\n' + '4\r\nWiki\r\n' + '5;ext=1\r\npedia\r\n' +
	'E\r\n in\r\n\r\nchunks.\r\n' + '0\r\n\r\n').bytes()
const chunked_trailer_request = ('POST /upload HTTP/1.1\r\n' + 'Host: example.com\r\n' +
	'Transfer-Encoding: chunked\r\n' + '\r\n' + '4\r\nWiki\r\n' + '5;ext=1\r\npedia\r\n' +
	'E\r\n in\r\n\r\nchunks.\r\n' + '0\r\n' + 'X-Checksum: sha256=abc\r\n' + 'X-Sig: 1\r\n' +
	'\r\n').bytes()

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
	chunked_total := request_parser.frame_request_length(chunked_request) or { panic(err) }
	if chunked_total != chunked_request.len {
		panic('chunked framing: ${chunked_total} != ${chunked_request.len}')
	}
	trailer_total := request_parser.frame_request_length(chunked_trailer_request) or {
		panic(err)
	}
	if trailer_total != chunked_trailer_request.len {
		panic('chunked + trailer framing: ${trailer_total} != ${chunked_trailer_request.len}')
	}
	println('chunked framed  = ${chunked_total} bytes (+ trailer: ${trailer_total})')
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

	// 3b) Presence check for the last parameter (walks every element).
	page := 'page'.bytes()
	for _ in 0 .. iterations {
		acc += int(req.has_query(page))
	}
	b.measure('has_query')

	// 3c) Percent-decoding a 38-byte query value (6 escapes, 2 '+') into a
	// reused buffer.
	encoded := 'caf%C3%A9+au+lait%2C%20sans%20sucre%21'.bytes()
	mut decoded := []u8{cap: encoded.len}
	for _ in 0 .. iterations {
		decoded.clear()
		request_parser.percent_decode_into(encoded, mut decoded, true)
		acc += decoded.len
	}
	b.measure('percent_decode_into')

	// 4) Request framing — the per-request cost framing adds to read_request.
	// This worst-cases the no-body fast path: full header walk, CL/TE rejected.
	for _ in 0 .. iterations {
		acc += request_parser.frame_request_length(raw_request) or { -1 }
	}
	b.measure('frame_request_length')

	// 5) Chunked framing — the frame_chunked_total walk (size lines, extensions,
	// data CRLFs, last chunk).
	for _ in 0 .. iterations {
		acc += request_parser.frame_request_length(chunked_request) or { -1 }
	}
	b.measure('frame_request_length (chunked)')

	// 6) The same body plus a trailer section (two trailer fields).
	for _ in 0 .. iterations {
		acc += request_parser.frame_request_length(chunked_trailer_request) or { -1 }
	}
	b.measure('frame_request_length (chunked + trailer)')

	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
