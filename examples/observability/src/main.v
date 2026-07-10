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
// or JSON) so it's machine-parseable, not prose. The line itself is assembled
// the way examples/middleware/src/access_log.v — the repo's canonical
// zero-alloc access log — does it: "METHOD SP PATH" is the contiguous prefix
// of the request line up to the 2nd space (two memchr calls, headers never
// scanned), copied into a stack buffer around the formatted numbers. That
// example also shows the next step (batched fwrite, no syscall per request);
// here one println per request keeps the demo portable and simple.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - Handlers APPEND into `out` (§1) — no return-a-buffer, no copy.
//   - Fixed responses are compile-time `const ... .bytes()`, sent with `out <<`.
//   - Routing compares the path IN PLACE by offsets (`slice_eq`) — no
//     `.to_string()`, no match-on-string.
//   - The /metrics body is framed with `ws`/`wi`/`wu` (push_many + write_dec
//     into a stack scratch) — zero `${}` in request-serving code.
//   - The wrapper reads the status straight from the three digit bytes already
//     in `out` — no slice expression, no `.bytestr()`, no re-parse.
//
// WORKS TODAY. The one core dependency for perfect timing is a request-start
// timestamp; we stamp it at handler entry, which is close enough.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import strconv
import sync
import time

fn C.memchr(buf voidptr, c int, n usize) voidptr

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

// prometheus_body appends the text exposition into `body`: literal metric
// names + counters written with `wu` — zero `${}`, zero intermediate strings.
// Counters are snapshotted under the mutex so one scrape sees a consistent
// set, and the formatting happens outside the critical section.
fn (mut m Metrics) prometheus_body(mut body []u8) {
	m.mu.lock()
	requests_total := m.requests_total
	s2 := m.status_2xx
	s4 := m.status_4xx
	s5 := m.status_5xx
	m.mu.unlock()
	ws(mut body, 'http_requests_total ')
	wu(mut body, requests_total)
	ws(mut body, '\nhttp_responses_total{class="2xx"} ')
	wu(mut body, s2)
	ws(mut body, '\nhttp_responses_total{class="4xx"} ')
	wu(mut body, s4)
	ws(mut body, '\nhttp_responses_total{class="5xx"} ')
	wu(mut body, s5)
	ws(mut body, '\n')
}

// ---- static responses (consts — the handler appends, never builds) ----------
const resp_healthz = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'.bytes()
const resp_ready = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready'.bytes()
const resp_not_ready_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'.bytes()
const resp_ok_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
const metrics_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: '.bytes()

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// wu is wi for u64 counters (write_dec_u — no lossy cast through i64).
fn wu(mut out []u8, n u64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec_u(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// ---- routing ---------------------------------------------------------------
// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

fn app(req_buffer []u8, mut m Metrics, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	if slice_eq(req.buffer, req.path, '/healthz') {
		out << resp_healthz
		return
	}
	if slice_eq(req.buffer, req.path, '/readyz') {
		// Check dependencies here (db ping, etc). Fail -> 503. The not-ready
		// branch is dead in this demo but it IS the point of /readyz — and as
		// a const it costs nothing.
		ready := true
		if ready {
			out << resp_ready
			return
		}
		out << resp_not_ready_503
		return
	}
	if slice_eq(req.buffer, req.path, '/metrics') {
		// The one small allocation in this example, on the SCRAPE route only:
		// the body must exist before its Content-Length is known. Prometheus
		// polls every 15-60s — this never runs per client request.
		mut body := []u8{cap: 160}
		m.prometheus_body(mut body)
		out << metrics_head
		wi(mut out, i64(body.len))
		ws(mut out, '\r\n\r\n')
		out << body
		return
	}
	// Unknown path: this demo answers an empty 200 (kept from day one — a real
	// service would 404 here).
	out << resp_ok_empty
}

// ---- the observability wrapper ----------------------------------------------
// status_of reads the 3 status digits at their fixed RFC 9112 offset
// ("HTTP/1.1 NNN ...") in place — no slice, no `.bytestr()`, no `.int()`.
// `start` is where the wrapped handler began appending its response, so the
// caller never has to slice `out`. Guarded: a response shorter than 12 bytes
// reports 0 (recorded in no class) instead of reading out of bounds.
@[direct_array_access]
fn status_of(resp []u8, start int) int {
	if resp.len - start < 12 {
		return 0
	}
	// int casts: u8 arithmetic with a rune literal would infer rune.
	return int(resp[start + 9] - `0`) * 100 + int(resp[start + 10] - `0`) * 10 + int(resp[start +
		11] - `0`)
}

// log_line assembles 'level=info method=M path=P status=NNN dur_us=N' in a
// stack buffer and emits it with ONE println. "METHOD SP PATH" comes from two
// memchr calls over the request-line prefix — no full parse, no heap. The
// `tos` view over the stack buffer is read-only and MUST NOT escape: println
// copies the bytes to fd 1 synchronously, then the frame dies. Silently skips
// a malformed request line or a pathologically long request-target (logging
// must never break a response).
@[direct_array_access]
fn log_line(req_buffer []u8, status int, dur_us i64) {
	if req_buffer.len < 4 {
		return
	}
	unsafe {
		// First space ends the method; the prefix up to the SECOND space is
		// the contiguous "METHOD SP PATH".
		sp1 := C.memchr(&req_buffer[0], ` `, usize(req_buffer.len))
		if sp1 == nil {
			return
		}
		method_len := int(&u8(sp1) - &req_buffer[0])
		after_method := method_len + 1
		if after_method >= req_buffer.len {
			return
		}
		sp2 := C.memchr(&req_buffer[after_method], ` `, usize(req_buffer.len - after_method))
		if sp2 == nil {
			return
		}
		path_len := int(&u8(sp2) - &req_buffer[after_method])

		mut line := [512]u8{}
		// worst case: 4 literals (40 B) + method + path + 3 status digits +
		// up to 20 for a 64-bit duration — bounded before any write.
		if method_len + path_len + 64 > line.len {
			return
		}
		mut n := 0
		lit0 := 'level=info method='
		vmemcpy(&line[n], lit0.str, lit0.len)
		n += lit0.len
		vmemcpy(&line[n], &req_buffer[0], method_len)
		n += method_len
		lit1 := ' path='
		vmemcpy(&line[n], lit1.str, lit1.len)
		n += lit1.len
		vmemcpy(&line[n], &req_buffer[after_method], path_len)
		n += path_len
		lit2 := ' status='
		vmemcpy(&line[n], lit2.str, lit2.len)
		n += lit2.len
		mut view := (&line[n]).vbytes(line.len - n)
		mut written := strconv.write_dec(i64(status), mut view)
		if written > 0 {
			n += written
		}
		lit3 := ' dur_us='
		vmemcpy(&line[n], lit3.str, lit3.len)
		n += lit3.len
		view = (&line[n]).vbytes(line.len - n)
		written = strconv.write_dec(dur_us, mut view)
		if written > 0 {
			n += written
		}
		// One structured line per request.
		println(tos(&line[0], n))
	}
}

// observed wraps a handler: access log + metrics around every request. No
// request decode here — the wrapped handler parses; the log only needs the
// request-line prefix and the status digits already sitting in `out`. The
// wrapped `next` stays fallible so the err value reaches the diagnostic log;
// on failure the wrapper answers the canned 400 and closes (what the old
// runtime did on a handler error).
fn observed(next fn (req []u8, mut out []u8) !, mut m Metrics) core.Handler {
	return fn [next, mut m] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		start := time.now()
		start_len := out.len
		next(req_buffer, mut out) or {
			m.record(500)
			// `${}` is sanctioned off the hot path (BEST_PRACTICES §3):
			// error diagnostics, not request serving.
			eprintln('level=error err=${err}')
			out << response.tiny_bad_request_response
			return .close
		}
		status := status_of(out, start_len)
		m.record(status)
		dur_us := time.since(start).microseconds()
		log_line(req_buffer, status, dur_us)
		return .done
	}
}

fn main() {
	mut m := &Metrics{}
	handler := observed(fn [mut m] (req_buffer []u8, mut out []u8) ! {
		app(req_buffer, mut m, mut out)!
	}, mut m)
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handler
	})!
	println('Observability demo on http://localhost:3000/  (/healthz, /readyz, /metrics)')
	server.run()
}
