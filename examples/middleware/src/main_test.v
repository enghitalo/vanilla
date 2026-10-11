module main

import os
import core
import server
import vtest

// Tests for the middleware reference design. Five layers:
//   1. the composition mechanics (chain order, in-place header splice);
//   2. the per-route auth policy (public / private / role-gated) end-to-end
//      through the composed handler;
//   3. the access log line format (method + path + status), zero-parse path;
//   4. the composed chain allocates nothing and keeps the write buffer;
//   5. the wrappers hand the engine's inputs (client_fd, worker_state) to the
//      wrapped handler unchanged — a real server run, via vtest.

const probe_headers = ('X-Content-Type-Options: nosniff\r\n').bytes()

// ── insert_after_status_line (the in-place decorator primitive) ──────────────

fn test_insert_after_status_line_splices_only_its_response() {
	// `out` is the connection's write buffer: a pipelined batch already holds
	// the previous response. The splice must land in the response at `start`.
	earlier := 'HTTP/1.1 204 No Content\r\n\r\n'
	mut out := (earlier + 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi').bytes()
	insert_after_status_line(mut out, earlier.len, probe_headers)
	assert out.bytestr() == earlier +
		'HTTP/1.1 200 OK\r\nX-Content-Type-Options: nosniff\r\nContent-Length: 2\r\n\r\nhi'
}

fn test_insert_after_status_line_noop_on_empty() {
	mut out := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	insert_after_status_line(mut out, 0, []u8{})
	assert out.bytestr() == 'HTTP/1.1 204 No Content\r\n\r\n' // nothing added
}

fn test_insert_after_status_line_noop_without_status_line() {
	mut out := 'no-crlf-here'.bytes()
	insert_after_status_line(mut out, 0, probe_headers)
	assert out.bytestr() == 'no-crlf-here' // left untouched
}

// ── chain composition order ───────────────────────────────────────────────────

// Each middleware appends its tag to the response body as it unwinds; the final
// body's suffix order reveals the nesting (pure data flow, no shared state).
fn tag_mw(tag string) Middleware {
	return fn [tag] (next Handler) Handler {
		return fn [tag, next] (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			step := next(req, mut out, client_fd, worker_state, mut event_loop)
			if step != .done {
				return step
			}
			core.append_str(mut out, tag)
			return .done
		}
	}
}

fn test_chain_runs_outermost_first() {
	base := fn (req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		core.append_str(mut out, 'app')
		return .done
	}
	// A is OUTERMOST: it wraps B, which wraps app. On the way out the response
	// unwinds app -> B -> A, so A's tag lands LAST.
	h := chain(base, tag_mw('A'), tag_mw('B'))
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert h('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut
		event_loop) == .done
	assert out.bytestr() == 'appBA'
}

// ── per-route auth policy through the composed handler ────────────────────────

fn serve(target string, auth string) string {
	return serve_with(target, if auth != '' { 'Authorization: Bearer ${auth}\r\n' } else { '' })
}

// serve_with runs `target`, plus the raw header lines in `headers`, through the
// composed handler and returns the response.
fn serve_with(target string, headers string) string {
	handler := chain(route, with_security_headers)
	raw := '${target} HTTP/1.1\r\nHost: x\r\n${headers}\r\n'
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handler(raw.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close {
		return 'ERR'
	}
	return out.bytestr()
}

fn test_public_route_needs_no_token() {
	out := serve('GET /', '')
	assert out.contains('200 OK')
	assert out.contains('"auth":false')
	assert out.contains('X-Frame-Options: DENY') // global decorator still applied
}

fn test_private_route_rejects_anonymous() {
	assert serve('GET /me', '').contains('401 Unauthorized')
}

fn test_private_route_rejects_bad_token() {
	assert serve('GET /me', 'nope').contains('401 Unauthorized')
}

fn test_private_route_accepts_valid_user() {
	out := serve('GET /me', 'tok-alice')
	assert out.contains('200 OK')
	assert out.contains('"name":"alice"')
}

fn test_admin_route_forbids_plain_user() {
	// authenticated, but wrong role -> 403 (not 401)
	assert serve('GET /admin', 'tok-alice').contains('403 Forbidden')
}

fn test_admin_route_rejects_anonymous_as_401() {
	// no token at all -> 401, before any role check
	assert serve('GET /admin', '').contains('401 Unauthorized')
}

fn test_admin_route_accepts_admin() {
	out := serve('GET /admin', 'tok-root')
	assert out.contains('200 OK')
	assert out.contains('"admin":"root"')
}

fn test_unknown_route_is_404() {
	assert serve('GET /nope', 'tok-root').contains('404 Not Found')
}

fn test_path_with_query_is_not_a_route() {
	// the router matches the whole request-target, query included
	assert serve('GET /me?x=1', 'tok-alice').contains('404 Not Found')
}

fn test_bearer_token_needs_the_scheme_and_a_token() {
	assert serve_with('GET /me', 'Authorization: Bearer \r\n').contains('401 Unauthorized') // no token
	assert serve_with('GET /me', 'Authorization: Basic tok-alice\r\n').contains('401 Unauthorized')
	assert serve_with('GET /me', 'Authorization: Bearertok-alice\r\n').contains('401 Unauthorized')
	// the header NAME is case-insensitive
	assert serve_with('GET /me', 'authorization: Bearer tok-alice\r\n').contains('200 OK')
}

// The 200 responses are framed by hand, so pin their exact bytes: a
// Content-Length that drifts from the body it announces fails here.
const decorated_headers = 'X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n"

fn json_200(body string) string {
	return 'HTTP/1.1 200 OK\r\n' + decorated_headers +
		'Content-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n' +
		body
}

fn test_200_responses_exact_bytes() {
	assert serve('GET /', '') == json_200('{"page":"home","auth":false}')
	assert serve('GET /me', 'tok-alice') == json_200('{"id":1,"name":"alice","role":"user"}')
	assert serve('GET /admin', 'tok-root') == json_200('{"admin":"root","secret":42}')
}

// ── access log ────────────────────────────────────────────────────────────────

fn test_access_log_writes_method_path_status() {
	tmp := os.join_path(os.temp_dir(), 'mw_access_ok.log')
	os.rm(tmp) or {}
	log := new_access_log(tmp)!
	log.record('GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(),
		'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes(), 0)
	// this response starts after an earlier pipelined one: ITS status is logged
	earlier := 'HTTP/1.1 204 No Content\r\n\r\n'
	log.record('POST /users HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(),
		(earlier + 'HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n').bytes(), earlier.len)
	log.flush()
	content := os.read_file(tmp)!
	assert content == 'GET /users/42 200\nPOST /users 201\n'
	os.rm(tmp) or {}
}

fn test_access_log_skips_malformed_request_line() {
	tmp := os.join_path(os.temp_dir(), 'mw_access_bad.log')
	os.rm(tmp) or {}
	log := new_access_log(tmp)!
	// no space in the request line -> nothing logged, no crash
	log.record('garbage'.bytes(), 'HTTP/1.1 200 OK\r\n\r\n'.bytes(), 0)
	log.flush()
	assert os.read_file(tmp)! == ''
	os.rm(tmp) or {}
}

// ── the point of the design: the composed chain allocates nothing ─────────────

// One request per outcome: public 200, private 200/401, role-gated
// 200/403/401, 404. (A malformed request is left out: it answers 400 and
// closes the connection, and decode_http_request's error() allocates.)
const route_requests = [
	'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
	'GET /me HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok-alice\r\n\r\n',
	'GET /me HTTP/1.1\r\nHost: x\r\n\r\n',
	'GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok-root\r\n\r\n',
	'GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok-alice\r\n\r\n',
	'GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer nope\r\n\r\n',
	'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
]

// The epoll worker reuses `out` through `clear()` after each flush. Had any
// layer sliced it (`out[start..]`), the buffer would be marked as shared and
// `clear()` would drop it (data = nil, cap = 0), so it would be reallocated on
// every request. Same buffer, same capacity, after every outcome.
fn test_chain_keeps_the_write_buffer() ! {
	tmp := os.join_path(os.temp_dir(), 'mw_access_keep.log')
	log := new_access_log(tmp)!
	handler := chain(route, with_security_headers, access_log_mw(log))
	mut out := []u8{cap: 4096}
	data := out.data
	mut event_loop := core.EventLoop{}
	for r in route_requests {
		assert handler(r.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .done
		assert out.len > 0
		out.clear()
		assert out.cap == 4096, r
		assert out.data == data, r
	}
	log.flush()
	os.rm(tmp) or {}
}

// Every outcome runs 20k times through the full chain (security headers,
// access log, router) into one reused buffer, as a worker serves them; the
// collector's lifetime allocation counter must not move. (Under `-gc none`,
// vanilla's production build, the same allocation would be a permanent leak.)
fn test_chain_allocates_nothing() ! {
	$if gcboehm ? {
		tmp := os.join_path(os.temp_dir(), 'mw_access_alloc.log')
		log := new_access_log(tmp)!
		handler := chain(route, with_security_headers, access_log_mw(log))
		reqs := route_requests.map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up
			handler(r, mut out, -1, unsafe { nil }, mut event_loop)
			out.clear()
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				handler(r, mut out, -1, unsafe { nil }, mut event_loop)
				out.clear()
			}
		}
		grown := gc_heap_usage().total_bytes - before
		log.flush()
		os.rm(tmp) or {}
		assert grown < 4096, 'the chain allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// ── the wrappers forward every handler input ──────────────────────────────────

const probe_tag = 0x5eed

const probe_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const probe_lost = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

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
		core.append_str(mut out, probe_lost)
		return .done
	}
	state := unsafe { &ProbeState(worker_state) }
	core.append_str(mut out, if state.tag == probe_tag { probe_ok } else { probe_lost })
	return .done
}

fn test_chain_forwards_client_fd_and_worker_state() ! {
	tmp := os.join_path(os.temp_dir(), 'mw_access_forward.log')
	os.rm(tmp) or {}
	log := new_access_log(tmp)!
	got := vtest.drive(server.ServerConfig{
		handler:    chain(probe, with_security_headers, access_log_mw(log))
		make_state: probe_state
	}, [vtest.Script{
		rounds: [vtest.Round{
			send: 'GET /probe HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
		}]
	}])!
	assert got.conns[0].connect_err == ''
	assert got.conns[0].frames.len == 1
	resp := got.conns[0].frames[0].bytestr()
	assert resp.starts_with('HTTP/1.1 200 OK\r\n'), resp
	assert resp.contains('X-Frame-Options: DENY') // both wrappers ran
	log.flush()
	assert os.read_file(tmp)! == 'GET /probe 200\n'
	os.rm(tmp) or {}
}
