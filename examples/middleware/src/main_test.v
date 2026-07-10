module main

import os
import http_server.core

// Pure tests for the middleware reference design. Three layers:
//   1. the composition mechanics (chain order, single-alloc header injection);
//   2. the per-route auth policy (public / private / role-gated) end-to-end
//      through the composed handler;
//   3. the access log line format (method + path + status), zero-parse path.

const probe_headers = ('X-Content-Type-Options: nosniff\r\n').bytes()

// ── inject_headers (the single-allocation decorator primitive) ────────────────

fn test_inject_headers_after_status_line() {
	resp := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi'.bytes()
	out := inject_headers(resp, probe_headers).bytestr()
	assert out.starts_with('HTTP/1.1 200 OK\r\n') // status line still first
	assert out.contains('X-Content-Type-Options: nosniff')
	assert out.ends_with('\r\n\r\nhi') // body intact
	// header sits BETWEEN the status line and the original first header
	h_at := out.index('X-Content-Type-Options') or { -1 }
	cl_at := out.index('Content-Length') or { -1 }
	assert h_at > 0 && cl_at > h_at
}

fn test_inject_headers_noop_on_empty() {
	resp := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	assert inject_headers(resp, []u8{}).len == resp.len // nothing added
}

fn test_inject_headers_noop_without_status_line() {
	resp := 'no-crlf-here'.bytes()
	assert inject_headers(resp, probe_headers) == resp // returned unchanged
}

// ── chain composition order ───────────────────────────────────────────────────

// Each middleware appends its tag to the response body as it unwinds; the final
// body's suffix order reveals the nesting (pure data flow, no shared state).
fn tag_mw(tag string) Middleware {
	return fn [tag] (next Handler) Handler {
		return fn [tag, next] (req []u8, mut out []u8, mut worker core.Worker) core.Step {
			step := next(req, mut out, mut worker)
			if step != .done {
				return step
			}
			out << tag.bytes()
			return .done
		}
	}
}

fn test_chain_runs_outermost_first() {
	base := fn (req []u8, mut out []u8, mut worker core.Worker) core.Step {
		out << 'app'.bytes()
		return .done
	}
	// A is OUTERMOST: it wraps B, which wraps app. On the way out the response
	// unwinds app -> B -> A, so A's tag lands LAST.
	h := chain(base, tag_mw('A'), tag_mw('B'))
	mut out := []u8{}
	mut worker := core.Worker{}
	assert h('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, mut worker) == .done
	assert out.bytestr() == 'appBA'
}

// ── per-route auth policy through the composed handler ────────────────────────

fn serve(target string, auth string) string {
	handler := chain(route, with_security_headers)
	mut raw := '${target} HTTP/1.1\r\nHost: x\r\n'
	if auth != '' {
		raw += 'Authorization: Bearer ${auth}\r\n'
	}
	raw += '\r\n'
	mut out := []u8{}
	mut worker := core.Worker{}
	if handler(raw.bytes(), mut out, mut worker) == .close {
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

// ── access log ────────────────────────────────────────────────────────────────

fn test_access_log_writes_method_path_status() {
	tmp := os.join_path(os.temp_dir(), 'mw_access_ok.log')
	os.rm(tmp) or {}
	log := new_access_log(tmp)!
	log.record('GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(),
		'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes())
	log.record('POST /users HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(),
		'HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n'.bytes())
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
	log.record('garbage'.bytes(), 'HTTP/1.1 200 OK\r\n\r\n'.bytes())
	log.flush()
	assert os.read_file(tmp)! == ''
	os.rm(tmp) or {}
}
