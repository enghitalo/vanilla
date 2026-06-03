module main

// SOLUTION: pure logic test — works today.
// Metrics accounting, the Prometheus exposition format, and the health routes
// are pure given the registry, so they're directly assertable.

fn test_status_of() {
	assert status_of('HTTP/1.1 200 OK\r\n\r\n'.bytes()) == 200
	assert status_of('HTTP/1.1 404 Not Found\r\n\r\n'.bytes()) == 404
	assert status_of('HTTP/1.1 503 Service Unavailable\r\n\r\n'.bytes()) == 503
}

fn test_metrics_counts_by_class() {
	mut m := Metrics{}
	m.record(200)
	m.record(201)
	m.record(404)
	m.record(500)
	out := m.prometheus()
	assert out.contains('http_requests_total 4')
	assert out.contains('class="2xx"} 2')
	assert out.contains('class="4xx"} 1')
	assert out.contains('class="5xx"} 1')
}

fn test_health_endpoints() ! {
	mut m := &Metrics{}
	assert app('GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, mut m)!.bytestr().contains('200 OK')
	assert app('GET /readyz HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, mut m)!.bytestr().contains('200 OK')
	metrics := app('GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, mut m)!.bytestr()
	assert metrics.contains('http_requests_total')
}
