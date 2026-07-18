module main

// http1_1/client hot-path micro-benchmark — measurable WITHOUT a network.
//
// The codec claims zero allocation on both directions (serialize + frame +
// decode); this proves the ns/op AND the claim: run under `-gc none` and
// watch RSS stay flat — any per-op allocation would grow it monotonically
// across the millions of iterations (the BEST_PRACTICES §2 methodology).
//
//   v -prod run bench/client_codec/client_codec_bench.v
//   v -prod -gc none run bench/client_codec/client_codec_bench.v
//
// (Use -prod: the default debug build is not representative.)
import benchmark
import os
import http1_1.client

const cl_response = ('HTTP/1.1 200 OK\r\n' + 'Content-Type: application/json\r\n' +
	'ETag: "abc123"\r\n' + 'Content-Length: 45\r\n' + 'Connection: keep-alive\r\n' + '\r\n' +
	'{"svc":"backend","msg":"hello from the mesh"}').bytes()

const chunked_response = ('HTTP/1.1 200 OK\r\n' + 'Content-Type: application/json\r\n' +
	'Transfer-Encoding: chunked\r\n' + '\r\n' + '1c\r\n{"svc":"backend","msg":"hell\r\n' +
	'11\r\no from the mesh"}\r\n' + '0\r\n\r\n').bytes()

fn main() {
	env_iters := os.getenv('BENCH_ITERS').int()
	iterations := if env_iters > 0 { env_iters } else { 5_000_000 }

	// Sanity: both fixtures frame completely and decode to the same body.
	// `panic`, not `assert` — asserts are compiled OUT under -prod, and a
	// benchmark that silently measures the error path is worse than none.
	cl_total := client.frame_response(cl_response)
	if cl_total != cl_response.len {
		panic('CL fixture does not frame: ${cl_total}')
	}
	ch_total := client.frame_response(chunked_response)
	if ch_total != chunked_response.len {
		panic('chunked fixture does not frame: ${ch_total}')
	}
	mut probe := []u8{cap: 64}
	client.append_body(mut probe, chunked_response, ch_total)
	if probe.bytestr() != '{"svc":"backend","msg":"hello from the mesh"}' {
		panic('de-chunk mismatch: "${probe.bytestr()}"')
	}
	println('chunked body    = "${probe.bytestr()}"')
	println('iterations      = ${iterations}\n')

	mut acc := i64(0) // accumulator prevents dead-code elimination
	mut out := []u8{cap: 4096} // reused, like a pooled conn's scratch

	mut b := benchmark.start()

	for _ in 0 .. iterations {
		out.clear()
		client.write_get(mut out, '/users/42?fmt=json', 'svc.local')
		acc += out.len
	}
	b.measure('write_get (serialize)')

	for _ in 0 .. iterations {
		out.clear()
		client.write_request(mut out, 'POST', '/ingest', 'svc.local',
			'Accept: application/json\r\n', cl_response[cl_total - 45..])
		acc += out.len
	}
	b.measure('write_request POST+body')

	for _ in 0 .. iterations {
		acc += i64(client.frame_response(cl_response))
	}
	b.measure('frame_response (Content-Length)')

	for _ in 0 .. iterations {
		acc += i64(client.frame_response(chunked_response))
	}
	b.measure('frame_response (chunked)')

	for _ in 0 .. iterations {
		out.clear()
		client.append_body(mut out, cl_response, cl_total)
		acc += out.len
	}
	b.measure('append_body (Content-Length)')

	for _ in 0 .. iterations {
		out.clear()
		client.append_body(mut out, chunked_response, ch_total)
		acc += out.len
	}
	b.measure('append_body (chunked de-chunk)')

	println('\nacc = ${acc} (ignore)')
}
