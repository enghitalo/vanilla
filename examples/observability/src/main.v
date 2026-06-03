module main

// Observability — reference design (access logs + health + metrics).
//
// A production service must answer three operational questions without a
// debugger: "is it up?", "is it ready for traffic?", and "how is it behaving?".
//
//   /healthz   — LIVENESS. Cheap, dependency-free. "the process is alive."
//                Orchestrators (k8s) restart the pod if this fails.
//   /readyz    — READINESS. "I can serve traffic" — checks deps (db, cache).
//                Failing this pulls the instance OUT of the load balancer
//                WITHOUT restarting it. Keep liveness and readiness separate;
//                conflating them causes restart storms during dependency blips.
//   /metrics   — Prometheus text exposition: counters/histograms scraped over
//                time. The lingua franca of cloud monitoring.
//
// ACCESS LOGGING is the wrapper pattern again (see security_headers): wrap the
// handler, time it, emit one structured line per request. Structured (key=val
// or JSON) so it's machine-parseable, not prose.
//
// WORKS TODAY. The one core dependency for perfect timing is a request-start
// timestamp; we stamp it at handler entry, which is close enough.

import http_server
import http_server.http1_1.request_parser
import sync
import time

// Minimal metrics registry (atomic-ish via mutex; a real one uses atomics).
struct Metrics {
mut:
	mu             &sync.Mutex = sync.new_mutex()
	requests_total u64
	status_2xx     u64
	status_4xx     u64
	status_5xx     u64
}

fn (mut m Metrics) record(status int) {
	m.mu.lock()
	m.requests_total++
	match status / 100 {
		2 { m.status_2xx++ }
		4 { m.status_4xx++ }
		5 { m.status_5xx++ }
		else {}
	}
	m.mu.unlock()
}

fn (mut m Metrics) prometheus() string {
	m.mu.lock()
	defer { m.mu.unlock() }
	return 'http_requests_total ${m.requests_total}\n' +
		'http_responses_total{class="2xx"} ${m.status_2xx}\n' +
		'http_responses_total{class="4xx"} ${m.status_4xx}\n' +
		'http_responses_total{class="5xx"} ${m.status_5xx}\n'
}

fn status_of(resp []u8) int {
	s := resp#[9..12].bytestr() // "HTTP/1.1 NNN ..."
	return s.int()
}

// observed wraps a handler: access log + metrics around every request.
fn observed(next fn ([]u8, int) ![]u8, mut m Metrics) fn ([]u8, int) ![]u8 {
	return fn [next, mut m] (req_buffer []u8, fd int) ![]u8 {
		start := time.now()
		req := request_parser.decode_http_request(req_buffer) or {
			return error('parse')
		}
		method := req.method.to_string(req.buffer)
		path := req.path.to_string(req.buffer)

		resp := next(req_buffer, fd) or {
			m.record(500)
			eprintln('level=error method=${method} path=${path} err=${err}')
			return err
		}
		status := status_of(resp)
		m.record(status)
		dur_us := time.since(start).microseconds()
		// One structured line per request.
		println('level=info method=${method} path=${path} status=${status} dur_us=${dur_us}')
		return resp
	}
}

fn app(req_buffer []u8, _ int, mut m Metrics) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	path := req.path.to_string(req.buffer)
	match path {
		'/healthz' {
			return 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'.bytes()
		}
		'/readyz' {
			// Check dependencies here (db ping, etc). Fail -> 503.
			ready := true
			if ready {
				return 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready'.bytes()
			}
			return 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
		'/metrics' {
			body := m.prometheus()
			return 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
		}
		else {
			return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
	}
}

fn main() {
	mut m := &Metrics{}
	handler := observed(fn [mut m] (req_buffer []u8, fd int) ![]u8 {
		return app(req_buffer, fd, mut m)
	}, mut m)
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: handler
	})!
	println('Observability demo on http://localhost:3000/  (/healthz, /readyz, /metrics)')
	server.run()
}
