module main

// SOLUTION: pure handler-wrapper test — works today.
// Demonstrates testing the COMPOSITION pattern: assert the wrapper injects the
// hardening headers into whatever the inner handler returned, in the right
// place (after the status line, before the body), and hands the engine's
// inputs to the inner handler unchanged.
import core
import server
import vtest

fn test_wrapper_injects_all_headers() {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()

	assert out.contains('Strict-Transport-Security: max-age=')
	assert out.contains("Content-Security-Policy: default-src 'self'")
	assert out.contains('X-Frame-Options: DENY')
	assert out.contains('X-Content-Type-Options: nosniff')
	assert out.contains('Referrer-Policy:')
	assert out.contains('Permissions-Policy:')
}

fn test_status_line_and_body_preserved() {
	out := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()).bytestr()
	assert out.starts_with('HTTP/1.1 200 OK\r\n') // status line still first
	assert out.contains('<h1>secure</h1>') // body intact
	// headers go between status line and the body
	hsts_at := out.index('Strict-Transport-Security') or { -1 }
	body_at := out.index('<h1>') or { -1 }
	assert hsts_at > 0 && body_at > hsts_at
}

fn test_exact_bytes_after_an_earlier_response() {
	// `out` is the connection's write buffer: a pipelined batch already holds
	// the previous response. The wrapper must splice into ITS response only.
	earlier := 'HTTP/1.1 204 No Content\r\n\r\n'
	mut out := earlier.bytes()
	wrapped := with_security_headers(app)
	mut event_loop := core.EventLoop{}
	assert wrapped('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut
		event_loop) == .done
	want := earlier + 'HTTP/1.1 200 OK\r\n' + security_headers.bytestr() +
		'Content-Type: text/html\r\nContent-Length: 15\r\n\r\n<h1>secure</h1>'
	assert out.bytestr() == want
}

fn test_response_without_status_line_untouched() {
	mut out := 'no-crlf-here'.bytes()
	insert_after_status_line(mut out, 0, security_headers)
	assert out.bytestr() == 'no-crlf-here'
}

// serve runs a request through the security-headers wrapper and returns the
// response bytes, adapting the raw-handler contract for the assertions.
fn serve(req []u8) []u8 {
	wrapped := with_security_headers(app)
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert wrapped(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}

// ── the wrapper forwards every handler input ──────────────────────────────────

const probe_tag = 0x5eed

const probe_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const probe_lost = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

struct ProbeState {
	tag int = probe_tag
}

fn probe_state() voidptr {
	return voidptr(&ProbeState{})
}

// probe answers 200 only when the engine's inputs reached it intact: a real
// connection fd and this worker's make_state value. It checks for nil before
// dereferencing, so a wrapper that drops worker_state fails the assert below
// instead of segfaulting the test binary.
fn probe(_req []u8, mut out []u8, client_fd int, worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	if client_fd < 0 || worker_state == unsafe { nil } {
		out << probe_lost
		return .done
	}
	state := unsafe { &ProbeState(worker_state) }
	out << if state.tag == probe_tag { probe_ok } else { probe_lost }
	return .done
}

fn test_wrapper_forwards_client_fd_and_worker_state() ! {
	got := vtest.drive(server.ServerConfig{
		handler:    with_security_headers(probe)
		make_state: probe_state
	}, [vtest.Script{
		rounds: [vtest.Round{
			send: 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
		}]
	}])!
	assert got.conns[0].connect_err == ''
	assert got.conns[0].frames.len == 1
	resp := got.conns[0].frames[0].bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK\r\n'), resp
	assert resp.contains('X-Frame-Options: DENY')
}
