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
// here one write per request keeps the demo portable and simple.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
// no allocation per request.
//   - Handlers APPEND into `out` (§1) — no return-a-buffer, no copy.
//   - Fixed responses are `const` strings appended with `core.append_str`.
//   - Routing compares the path IN PLACE by offsets (`slice_eq`) — no
//     `.to_string()`, no match-on-string.
//   - The /metrics response goes straight into `out`: its Content-Length is
//     the literals' lengths plus the counters' digit counts, computed from
//     the same snapshot the body is then written from, with
//     `core.append_str`/`wu` (append_str + write_dec into a stack scratch) —
//     no body buffer, zero `${}` in request-serving code.
//   - The wrapper reads the status straight from the three digit bytes already
//     in `out` — no slice expression, no `.bytestr()`, no re-parse.
//
// WORKS TODAY. The one core dependency for perfect timing is a request-start
// timestamp; we stamp it at handler entry, which is close enough.
import server
import core
import http1_1.request_parser
import http1_1.response
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

// Counters is one snapshot of the registry, taken under its mutex: one scrape
// sees a consistent set, and the Content-Length computed from it agrees with
// the body written from it. The formatting happens outside the critical
// section.
struct Counters {
	requests_total u64
	status_2xx     u64
	status_4xx     u64
	status_5xx     u64
}

fn (mut m Metrics) snapshot() Counters {
	m.mu.lock()
	c := Counters{
		requests_total: m.requests_total
		status_2xx:     m.status_2xx
		status_4xx:     m.status_4xx
		status_5xx:     m.status_5xx
	}
	m.mu.unlock()
	return c
}

// The literal parts of the exposition, in order; each counter follows its own.
const metric_total = 'http_requests_total '
const metric_2xx = '\nhttp_responses_total{class="2xx"} '
const metric_4xx = '\nhttp_responses_total{class="4xx"} '
const metric_5xx = '\nhttp_responses_total{class="5xx"} '
const metric_end = '\n'

// exposition_len is the byte length of what write_exposition appends for `c`:
// the literals plus each counter's digit count (strconv.dec_digits, the count
// write_dec_u writes). The Content-Length goes out first, and the body is
// written once, straight into `out`.
fn (c Counters) exposition_len() int {
	return metric_total.len + strconv.dec_digits(c.requests_total) + metric_2xx.len +
		strconv.dec_digits(c.status_2xx) + metric_4xx.len + strconv.dec_digits(c.status_4xx) +
		metric_5xx.len + strconv.dec_digits(c.status_5xx) + metric_end.len
}

// write_exposition appends the Prometheus text exposition: literal metric
// names + counters written with `wu` — zero `${}`, zero intermediate strings.
fn (c Counters) write_exposition(mut out []u8) {
	core.append_str(mut out, metric_total)
	wu(mut out, c.requests_total)
	core.append_str(mut out, metric_2xx)
	wu(mut out, c.status_2xx)
	core.append_str(mut out, metric_4xx)
	wu(mut out, c.status_4xx)
	core.append_str(mut out, metric_5xx)
	wu(mut out, c.status_5xx)
	core.append_str(mut out, metric_end)
}

// ---- static responses (consts — the handler appends, never builds) ----------
const resp_healthz = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
const resp_ready = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready'
const resp_not_ready_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'
const resp_ok_empty = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'
const resp_internal_error_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const metrics_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: '

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
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

// app appends the response and returns the next Step. A malformed request is
// the CLIENT's error: it gets the canned 400 and the connection closes, and
// the wrapper records the 400 it reads from `out`. The `!` is for the SERVER's
// failures (a dependency down, a bug), which the wrapper answers with 500.
fn app(req_buffer []u8, mut m Metrics, mut out []u8) !core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}
	if slice_eq(req_buffer, req.path, '/healthz') {
		core.append_str(mut out, resp_healthz)
		return .done
	}
	if slice_eq(req_buffer, req.path, '/readyz') {
		// Check dependencies here (db ping, etc). Fail -> 503. The not-ready
		// branch is dead in this demo but it IS the point of /readyz — and as
		// a const it costs nothing.
		ready := true
		if ready {
			core.append_str(mut out, resp_ready)
			return .done
		}
		core.append_str(mut out, resp_not_ready_503)
		return .done
	}
	if slice_eq(req_buffer, req.path, '/metrics') {
		// Snapshot first: the Content-Length is computed from the same counters
		// the body is then written from, so the two agree, and the body goes
		// straight into `out` — no buffer to build it in first.
		c := m.snapshot()
		core.append_str(mut out, metrics_head)
		wi(mut out, c.exposition_len())
		core.append_str(mut out, '\r\n\r\n')
		c.write_exposition(mut out)
		return .done
	}
	// Unknown path: this demo answers an empty 200 (kept from day one — a real
	// service would 404 here).
	core.append_str(mut out, resp_ok_empty)
	return .done
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

// log_line assembles 'level=info method=M path=P status=NNN dur_us=N\n' in a
// stack buffer and emits it with ONE print: one write, newline included, where
// println writes the line and its '\n' separately (two writes, which another
// worker's line can land between). "METHOD SP PATH" comes from two memchr
// calls over the request-line prefix — no full parse, no heap. The `tos` view
// over the stack buffer is read-only and MUST NOT escape: print copies the
// bytes to fd 1 synchronously, then the frame dies. Silently skips a malformed
// request line or a pathologically long request-target (logging must never
// break a response).
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
		// worst case: 4 literals (40 B) + method + path + the status (3 digits;
		// up to 5 when its bytes are no digits) + up to 20 for a 64-bit
		// duration + '\n' — bounded before any write.
		if method_len + path_len + 66 > line.len {
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
		line[n] = `\n`
		n++
		// One structured line per request, in one write.
		print(tos(&line[0], n))
	}
}

// observed wraps a handler: access log + metrics around every request. No
// request decode here — the wrapped handler parses; the log only needs the
// request-line prefix and the status digits already sitting in `out`. The
// wrapped `next` stays fallible so the err value reaches the diagnostic log.
// A failure is the server's fault: any partial response is dropped and the
// client gets a canned 500 (Connection: close). The status is always read
// back from the bytes in `out`, so the status the client receives, the one
// the metrics count, and the one the access log prints are the same.
fn observed(next fn (req []u8, mut out []u8) !core.Step, mut m Metrics) core.Handler {
	return fn [next, mut m] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		start := time.now()
		start_len := out.len
		step := next(req_buffer, mut out) or {
			// `${}` is sanctioned off the hot path (BEST_PRACTICES §3):
			// error diagnostics, not request serving.
			eprintln('level=error err=${err}')
			// Roll back by length, never out.trim(): trim reallocates `out`,
			// the connection's write buffer, once it was ever sliced.
			unsafe {
				out.len = start_len
			}
			core.append_str(mut out, resp_internal_error_500)
			core.Step.close
		}
		status := status_of(out, start_len)
		m.record(status)
		dur_us := time.since(start).microseconds()
		log_line(req_buffer, status, dur_us)
		return step
	}
}

fn main() {
	mut m := &Metrics{}
	handler := observed(fn [mut m] (req_buffer []u8, mut out []u8) !core.Step {
		return app(req_buffer, mut m, mut out)!
	}, mut m)
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handler
	})!
	println('Observability demo on http://localhost:3000/  (/healthz, /readyz, /metrics)')
	srv.run()
}
