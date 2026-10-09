module main

// static_assets hot-path micro-benchmark — measurable WITHOUT wrk.
//
// `respond()` is a pure function (request bytes -> response bytes), so we can
// measure ns/op directly instead of a noisy loopback load test. It exercises
// the real hot path: parse the request, route the path, negotiate encoding,
// and return the precomputed response. Run before/after any change and keep the
// numbers from regressing.
//
//   v -prod run bench/static_assets_bench/static_assets_bench.v
//
// (Use -prod: the default debug build is not representative.)
import benchmark
import os
import static_assets

const bench_root = os.join_path(os.temp_dir(), 'vanilla_sa_bench')

fn setup() static_assets.AssetServer {
	os.rmdir_all(bench_root) or {}
	os.mkdir_all(os.join_path(bench_root, 'assets')) or { panic(err) }
	os.write_file(os.join_path(bench_root, 'index.html'), '<!doctype html><title>app</title>') or {
		panic(err)
	}
	os.write_file(os.join_path(bench_root, 'app.abc123.js'), 'export const x = 1') or { panic(err) }
	os.write_file(os.join_path(bench_root, 'app.abc123.js.br'), 'BROTLI-APP-JS-BYTES') or {
		panic(err)
	}
	os.write_file(os.join_path(bench_root, 'app.abc123.js.gz'), 'GZIP-APP-JS-BYTES') or {
		panic(err)
	}
	// a 256 KiB wasm so the body-copy cost is realistic
	mut wasm := []u8{len: 256 * 1024, init: u8(index & 0xff)}
	wasm[0], wasm[1], wasm[2], wasm[3] = u8(0x00), `a`, `s`, `m`
	os.write_file_array(os.join_path(bench_root, 'core.9f3a1c.wasm'), wasm) or { panic(err) }
	// Preload everything (sendfile_min_bytes: 0) so this measures the in-memory
	// respond() hot path — apples-to-apples with the pre-sendfile A/B numbers.
	// The sendfile path is correctness-verified live, not in this micro-bench.
	return static_assets.new(static_assets.Config{ root: bench_root, sendfile_min_bytes: 0 }) or {
		panic(err)
	}
}

fn r(line string) []u8 {
	return (line + '\r\n\r\n').bytes()
}

fn main() {
	s := setup()

	// Loop count: BENCH_ITERS env if set (CI uses a smaller value for speed),
	// else 5M for stable local numbers. See bench/ci_bench.sh.
	env_iters := os.getenv('BENCH_ITERS').int()
	iterations := if env_iters > 0 { env_iters } else { 5_000_000 }

	// Realistic requests with the headers a browser actually sends.
	req_wasm :=
		r('GET /core.9f3a1c.wasm HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nAccept-Encoding: gzip, deflate, br')
	req_js :=
		r('GET /app.abc123.js HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nAccept-Encoding: gzip, deflate, br')
	req_fallback :=
		r('GET /users/42/profile HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html')
	req_404 := r('GET /missing.deadbeef.wasm HTTP/1.1\r\nHost: example.com')
	req_index := r('GET / HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: br')

	// Sanity-print once so we know we measure correct behavior.
	println('wasm    -> ${s.respond(req_wasm)![..15].bytestr()} ...')
	println('js (br) -> ${s.respond(req_js)![..40].bytestr()} ...')
	println('iterations = ${iterations}\n')

	mut acc := 0 // accumulator defeats dead-code elimination

	mut b := benchmark.start()

	for _ in 0 .. iterations {
		acc += (s.respond(req_wasm) or { panic(err) }).len
	}
	b.measure('respond  200 wasm  (no encoding)')

	for _ in 0 .. iterations {
		acc += (s.respond(req_js) or { panic(err) }).len
	}
	b.measure('respond  200 js    (br negotiated)')

	for _ in 0 .. iterations {
		acc += (s.respond(req_index) or { panic(err) }).len
	}
	b.measure('respond  200 index (/ -> index.html)')

	for _ in 0 .. iterations {
		acc += (s.respond(req_fallback) or { panic(err) }).len
	}
	b.measure('respond  SPA fallback -> index')

	for _ in 0 .. iterations {
		acc += (s.respond(req_404) or { panic(err) }).len
	}
	b.measure('respond  404')

	// Full handler path: the server copies the response into the per-connection
	// write buffer (`out << ...`). This is the body-copy cost a precomputed
	// response can't avoid without sendfile(2). 256 KiB body.
	//
	// Generation (parse/route/encode) is already measured at the FULL count in the
	// sections above; this section adds only the body copy on top. That copy is
	// memcpy-bandwidth-bound (~40 GB/s) — a CPU/libc property, not vanilla's code,
	// so it can't regress from a code change and needs few samples. Scale it to
	// iters/50 (e.g. 1M -> 20k ~0.1s, 5M -> 100k) so it neither dominates the
	// bench's wall time (it was ~90% at full count) nor reports a misleading
	// memcpy figure. The label prints the actual count used.
	copy_iters := if iterations > 100_000 { iterations / 50 } else { iterations }
	mut out := []u8{cap: 300 * 1024}
	for _ in 0 .. copy_iters {
		out.clear()
		out << (s.respond(req_wasm) or { panic(err) })
		acc += out.len
	}
	b.measure('handler  200 wasm + copy into out (256 KiB, ${copy_iters} iters)')

	os.rmdir_all(bench_root) or {}
	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
