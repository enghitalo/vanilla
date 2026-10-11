module main

// SOLUTION: pure handler test — works today.
// Metrics accounting, the Prometheus exposition format, and the health routes
// are pure given the registry, so they're directly assertable — and the raw
// requests go through the FULL observed() wrapper (the example's core lesson)
// via the serve() adapter, no listening socket required (BEST_PRACTICES §9).
import core
import http1_1.response

fn test_status_of() {
	assert status_of('HTTP/1.1 200 OK\r\n\r\n'.bytes(), 0) == 200
	assert status_of('HTTP/1.1 404 Not Found\r\n\r\n'.bytes(), 0) == 404
	assert status_of('HTTP/1.1 503 Service Unavailable\r\n\r\n'.bytes(), 0) == 503
}

fn test_status_of_guards_short_and_offset() {
	// A wrapped handler that appended fewer than 12 bytes must not be read out
	// of bounds — the guard reports 0 (recorded in no class).
	assert status_of([]u8{}, 0) == 0
	assert status_of('HTTP/1.1 2'.bytes(), 0) == 0
	// `start` addresses the wrapper's slice-free contract: the second response
	// in a shared buffer is read at its own offset.
	two := 'HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 404 Not Found\r\n\r\n'.bytes()
	assert status_of(two, 0) == 204
	assert status_of(two, 27) == 404
	// Truncated tail behind a valid start offset is guarded too.
	assert status_of(two, two.len - 5) == 0
}

fn test_metrics_counts_by_class() {
	mut m := Metrics{}
	m.record(200)
	m.record(201)
	m.record(404)
	m.record(500)
	mut body := []u8{}
	m.snapshot().write_exposition(mut body)
	out := body.bytestr() // test scaffolding: string asserts on the exposition
	assert out.contains('http_requests_total 4')
	assert out.contains('class="2xx"} 2')
	assert out.contains('class="4xx"} 1')
	assert out.contains('class="5xx"} 1')
}

fn test_health_endpoints() ! {
	mut m := &Metrics{}
	assert serve('GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr().contains('200 OK')
	ready := serve('GET /readyz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert ready.contains('200 OK')
	assert ready.ends_with('ready')
	metrics := serve('GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert metrics.contains('http_requests_total')
}

fn test_wrapper_counts_requests() ! {
	mut m := &Metrics{}
	for _ in 0 .. 3 {
		serve('GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!
	}
	// The scrape body is built BEFORE the wrapper records the /metrics request
	// itself, so it reports exactly the 3 wrapped /healthz requests.
	resp := serve('GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert resp.contains('http_requests_total 3')
	assert resp.contains('class="2xx"} 3')
	// ...and afterwards the scrape was recorded too.
	m.mu.lock()
	total := m.requests_total
	m.mu.unlock()
	assert total == 4
}

fn test_metrics_content_length_matches_body() ! {
	mut m := &Metrics{}
	m.record(200)
	resp := serve('GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: ')
	body := resp.all_after('\r\n\r\n')
	declared := resp.all_after('Content-Length: ').all_before('\r\n').int()
	assert declared == body.len
	assert body.ends_with('\n')
}

// The Content-Length is computed before the body is written: it must count
// every digit width a counter can have, up to the largest u64.
fn test_exposition_len_matches_the_bytes_written() {
	for n in [u64(0), 9, 10, 99, 100, 65535, 1_000_000_007, 18_446_744_073_709_551_615] {
		c := Counters{
			requests_total: n
			status_2xx:     n / 3
			status_4xx:     n % 10
			status_5xx:     n
		}
		mut body := []u8{}
		c.write_exposition(mut body)
		assert body.len == c.exposition_len(), 'counter ${n}'
	}
}

// The full /metrics response, byte for byte.
fn test_metrics_response_bytes() {
	mut m := Metrics{}
	for _ in 0 .. 12 {
		m.record(200)
	}
	m.record(503)
	mut out := []u8{}
	app('GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m, mut out) or { panic(err) }
	body := 'http_requests_total 13\nhttp_responses_total{class="2xx"} 12\nhttp_responses_total{class="4xx"} 0\nhttp_responses_total{class="5xx"} 1\n'
	assert out.bytestr() == metrics_head + body.len.str() + '\r\n\r\n' + body
}

// Every route runs 20k times through one reused `out`, as a worker would
// serve them; the collector's lifetime allocation counter must not move.
// (Under `-gc none`, vanilla's production build, the same allocation would be
// a permanent leak.) app() is measured, not the observed() wrapper: the
// wrapper prints an access-log line per request.
fn test_serving_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /readyz HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
			'garbage',
		].map(it.bytes())
		mut m := Metrics{}
		mut out := []u8{cap: 4096}
		rounds := 20_000
		mut before := u64(0)
		for round in 0 .. rounds + 1 {
			if round == 1 { // round 0 was the warm-up
				before = gc_heap_usage().total_bytes
			}
			for r in reqs {
				unsafe {
					out.len = 0
				}
				app(r, mut m, mut out) or {}
				m.record(200) // the counters grow, and so do their digits
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

fn test_unknown_path_gets_empty_200() ! {
	// Day-one contract of this demo: unknown paths answer an empty 200.
	mut m := &Metrics{}
	resp := serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK')
	assert resp.ends_with('Content-Length: 0\r\n\r\n')
}

fn test_malformed_request_is_400_and_counts_4xx() {
	// Malformed input is the client's error: the canned 400, the connection
	// closes, and the metrics count the same 400 the client received.
	mut m := &Metrics{}
	handler := observed(fn [mut m] (req_buffer []u8, mut out []u8) !core.Step {
		return app(req_buffer, mut m, mut out)!
	}, mut m)
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handler('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
	mut body := []u8{}
	m.snapshot().write_exposition(mut body)
	exposition := body.bytestr()
	assert exposition.contains('http_requests_total 1')
	assert exposition.contains('class="4xx"} 1')
	assert exposition.contains('class="5xx"} 0')
}

fn test_internal_error_answers_500_and_counts_5xx() {
	// The wrapped handler fails after appending part of a response: the
	// partial bytes are dropped, the client gets the canned 500 (and the
	// connection closes), and the metrics count the same 500.
	mut m := &Metrics{}
	handler := observed(fn (_req_buffer []u8, mut out []u8) !core.Step {
		out << 'HTTP/1.1 200 OK\r\nContent-Le'.bytes()
		return error('database unavailable')
	}, mut m)
	earlier := 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'
	mut out := earlier.bytes() // a pipelined response already in the buffer
	mut event_loop := core.EventLoop{}
	assert handler('GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut
		event_loop) == .close
	assert out.bytestr() == earlier + resp_internal_error_500
	mut body := []u8{}
	m.snapshot().write_exposition(mut body)
	exposition := body.bytestr()
	assert exposition.contains('http_requests_total 1')
	assert exposition.contains('class="4xx"} 0')
	assert exposition.contains('class="5xx"} 1')
}

// serve routes a raw request through the FULL observed() wrapper — access log
// + metrics + app — and adapts the append-into-out contract to the
// return-a-buffer shape the assertions expect (BEST_PRACTICES §9).
fn serve(req []u8, mut m Metrics) ![]u8 {
	handler := observed(fn [mut m] (req_buffer []u8, mut out []u8) !core.Step {
		return app(req_buffer, mut m, mut out)!
	}, mut m)
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handler(req, mut out, -1, unsafe { nil }, mut event_loop) == .close {
		return error('handler closed the connection')
	}
	return out
}
