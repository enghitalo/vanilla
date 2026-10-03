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
import time
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

	mut fr := client.Framer{}
	for _ in 0 .. iterations {
		fr.reset(false)
		acc += i64(fr.feed(cl_response, false))
	}
	b.measure('Framer.feed (Content-Length)')

	for _ in 0 .. iterations {
		fr.reset(false)
		acc += i64(fr.feed(chunked_response, false))
	}
	b.measure('Framer.feed (chunked)')

	mut scratch := []u8{cap: chunked_response.len}
	for _ in 0 .. iterations {
		scratch.clear()
		unsafe { scratch.push_many(chunked_response.data, chunked_response.len) }
		fr.reset(false)
		fr.feed(scratch, false)
		acc += fr.body_in_place(mut scratch).len
	}
	b.measure('Framer.body_in_place (chunked, copy + de-chunk)')

	acc += reframing_cost()
	println('\nacc = ${acc} (ignore)')
}

// reframing_cost frames a ~1.44 MB response of 65,536 16-byte chunks (#229's
// repro) after every 4 KiB "recv": frame_response from byte 0 each time
// (quadratic) versus one Framer fed the growing buffer (linear). The best of
// several runs; the Framer must stay within 2× of one feed on the whole buffer.
fn reframing_cost() i64 {
	mut resp := []u8{cap: 1_500_000}
	resp << 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'.bytes()
	for _ in 0 .. 65536 {
		resp << '10\r\n0123456789abcdef\r\n'.bytes()
	}
	resp << '0\r\n\r\n'.bytes()
	mut acc := i64(0)
	mut best_old := i64(-1)
	mut best_inc := i64(-1)
	mut best_one := i64(-1)
	mut fr := client.Framer{}
	for _ in 0 .. 7 {
		mut sw := time.new_stopwatch()
		for cut := 4096; true; cut += 4096 {
			end := if cut > resp.len { resp.len } else { cut }
			got := client.frame_response(unsafe { resp[..end] })
			acc += got
			if got != client.incomplete || end == resp.len {
				break
			}
		}
		best_old = min_ns(best_old, sw.elapsed().nanoseconds())
		sw = time.new_stopwatch()
		fr.reset(false)
		for cut := 4096; true; cut += 4096 {
			end := if cut > resp.len { resp.len } else { cut }
			got := fr.feed(unsafe { resp[..end] }, false)
			acc += got
			if got != client.incomplete || end == resp.len {
				break
			}
		}
		best_inc = min_ns(best_inc, sw.elapsed().nanoseconds())
		sw = time.new_stopwatch()
		fr.reset(false)
		got := fr.feed(resp, false)
		best_one = min_ns(best_one, sw.elapsed().nanoseconds())
		if got != resp.len {
			panic('reframing fixture does not frame: ${got}')
		}
		acc += got
	}
	println('\nre-framing ${resp.len} B (65536 chunks) after every 4 KiB, best of 7:')
	println('  frame_response from byte 0 each time: ${f64(best_old) / 1000.0:10.1f} us')
	println('  Framer.feed, resumed each time:       ${f64(best_inc) / 1000.0:10.1f} us')
	println('  Framer.feed, once on the whole:       ${f64(best_one) / 1000.0:10.1f} us')
	ratio := f64(best_inc) / f64(best_one)
	println('  resumed / once = ${ratio:.2f}x (#229 bound: <= 2x)')
	return acc
}

fn min_ns(best i64, ns i64) i64 {
	return if best < 0 || ns < best { ns } else { best }
}
