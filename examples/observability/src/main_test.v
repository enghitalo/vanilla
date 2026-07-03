module main

// SOLUTION: pure handler test — works today.
// Metrics accounting, the Prometheus exposition format, and the health routes
// are pure given the registry, so they're directly assertable — and the raw
// requests go through the FULL observed() wrapper (the example's core lesson)
// via the serve() adapter, no listening socket required (BEST_PRACTICES §9).

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
	mut body := []u8{cap: 160}
	m.prometheus_body(mut body)
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

fn test_unknown_path_gets_empty_200() ! {
	// Day-one contract of this demo: unknown paths answer an empty 200.
	mut m := &Metrics{}
	resp := serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut m)!.bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK')
	assert resp.ends_with('Content-Length: 0\r\n\r\n')
}

fn test_malformed_request_errors_and_counts_5xx() {
	// Malformed input must surface as a handler error, never a response —
	// and the wrapper must record it as a 500.
	mut m := &Metrics{}
	if _ := serve('garbage'.bytes(), mut m) {
		assert false, 'garbage request must not produce a response'
	}
	mut body := []u8{cap: 160}
	m.prometheus_body(mut body)
	out := body.bytestr()
	assert out.contains('http_requests_total 1')
	assert out.contains('class="5xx"} 1')
}

// serve routes a raw request through the FULL observed() wrapper — access log
// + metrics + app — and adapts the append-into-out contract to the
// return-a-buffer shape the assertions expect (BEST_PRACTICES §9).
fn serve(req []u8, mut m Metrics) ![]u8 {
	handler := observed(fn [mut m] (req_buffer []u8, fd int, mut out []u8) ! {
		app(req_buffer, fd, mut m, mut out)!
	}, mut m)
	mut out := []u8{}
	handler(req, -1, mut out)!
	return out
}
