// vtest build: linux
// End-to-end demonstration that offloading argon2 (offload_nix.c.v) removes the
// head-of-line blocking a synchronous verify would cause. Driven over real
// sockets via vtest; see docs/VTEST.md.
//
// The experiment (workers: 1, so ONE worker serves everything — deterministic):
//   1. Fire a login (want: 0 = fire-and-forget: fire() returns after the request
//      bytes are written, NOT after the response). The login now occupies the
//      worker: argon2 either runs inline (sync handler) or is offloaded (.suspend).
//   2. Immediately fire a fast GET /protected and MEASURE how long it takes to
//      answer. The stopwatch is a measurement, not a deadline (the reactor still
//      blocks in poll(-1)); it reads how long a server-driven completion took.
//
// Under the synchronous handler the single worker is stuck in argon2, so
// /protected waits the whole verify. Under the shipped offload handler the worker
// parks the login and answers /protected immediately. We assert on the ratio
// (machine-independent) plus a floor/ceiling.
module main

import server
import core
import vtest
import strings
import time

// A login whose body is the demo password (Content-Length must match).
const hol_login_req = 'POST /token HTTP/1.1\r\nHost: x\r\nContent-Length: 28\r\n\r\ncorrect horse battery staple'.bytes()

// hol_sync_handler is the naive design under test: it verifies argon2 INLINE on
// the worker thread (no offload), so a login blocks the worker for the whole
// ~200 ms (seconds in a debug build). /protected is the fast path.
fn hol_sync_handler(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	if req_buffer.bytestr().contains('/token') {
		if !verify_password('correct horse battery staple'.bytes(), demo_password_phc) {
			out << resp_401
			return .done
		}
		write_token_200(mut out)
		return .done
	}
	out << resp_ok_empty
	return .done
}

// a valid Bearer token for /protected (minted fresh so exp is in the future).
fn hol_protected_req() []u8 {
	mut payload := strings.new_builder(48)
	payload.write_string('{"sub":"user-42","exp":')
	payload.write_decimal(time.unix_now() + 3600)
	payload.write_u8(`}`)
	token := jwt_sign(payload)
	mut sb := strings.new_builder(96)
	sb.write_string('GET /protected HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ')
	sb.write_string(token.bytestr())
	sb.write_string('\r\n\r\n')
	return sb
}

// measure_protected_tail: with a login in flight, measure how long /protected
// takes to complete. Returns the elapsed milliseconds. Asserts /protected was
// actually served 200 (never dropped).
fn measure_protected_tail(cfg server.ServerConfig, protected_req []u8) !i64 {
	mut h := vtest.start(cfg)!
	defer {
		h.stop()
	}
	// 1) login IN FLIGHT — want: 0 returns after the write, the worker is now busy.
	h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: hol_login_req
			want: 0
		}]
	}])!
	// 2) time the fast request completing behind the busy worker.
	sw := time.new_stopwatch()
	fast := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: protected_req
		}]
	}])!
	elapsed := sw.elapsed().milliseconds()
	assert fast.conns[0].connect_err == '', fast.conns[0].connect_err
	assert fast.conns[0].frames.len == 1, 'GET /protected was not answered'
	assert fast.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200'), 'expected 200 for a valid bearer token'
	return elapsed
}

fn test_offload_prevents_head_of_line_blocking() ! {
	protected_req := hol_protected_req()

	// Naive synchronous verify: the single worker is stuck in argon2, so
	// /protected waits the whole login.
	sync_ms := measure_protected_tail(server.ServerConfig{
		io_multiplexing: .epoll
		workers:         1
		handler:         hol_sync_handler
	}, protected_req)!

	// The shipped handler + offload pool: the worker parks the login and serves
	// /protected immediately.
	offload_ms := measure_protected_tail(server.ServerConfig{
		io_multiplexing: .epoll
		workers:         1
		handler:         handle
		make_state:      make_auth_state
	}, protected_req)!

	eprintln('[hol] /protected tail latency — sync=${sync_ms}ms offload=${offload_ms}ms')
	// The robust, machine-independent signal is the ratio: offloading must make
	// /protected dramatically faster while a login is in flight.
	assert offload_ms < sync_ms, 'offload (${offload_ms}ms) must beat sync (${sync_ms}ms)'
	assert offload_ms * 4 < sync_ms, 'offload should be dramatically faster: offload=${offload_ms}ms vs sync=${sync_ms}ms'
}
