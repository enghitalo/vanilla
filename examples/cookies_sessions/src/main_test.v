module main

import core
import http1_1.response
import time

// Pure logic tests + raw-request E2E (BEST_PRACTICES §9). The cookie scanner
// and the session store are pure/in-memory, so the parsing rules, the session
// round-trip and the unguessability invariant are unit testable; the handler
// is pure too, so the E2E tests feed raw request bytes straight to handle() —
// no listening socket required.
// (`${}` and slicing below are TEST scaffolding — the example code itself
// never concatenates; see main.v's byte-discipline header.)

// cookie_of adapts the offset-returning scanner to plain strings for tests.
fn cookie_of(header string, name string) string {
	buf := header.bytes()
	start, len := cookie_value(buf, 0, buf.len, name)
	if start < 0 || len <= 0 {
		return ''
	}
	return buf[start..start + len].bytestr()
}

fn test_cookie_value_parsing() {
	assert cookie_of('sid=abc123; theme=dark', 'sid') == 'abc123'
	assert cookie_of('sid=abc123; theme=dark', 'theme') == 'dark'
	// whole-token: a prefix-colliding name must never match
	assert cookie_of('xsid=evil', 'sid') == ''
	// any pair position; lenient delimiters (no space after ';')
	assert cookie_of('a=1;sid=v; b=2', 'sid') == 'v'
	// '=' inside a value is data — the value runs to the next ';'
	assert cookie_of('sid=a=b; c=d', 'sid') == 'a=b'
	// a `sid=` inside another cookie's VALUE is not a pair boundary
	assert cookie_of('evil=sid=fake', 'sid') == ''
	// cookie names are case-sensitive (RFC 6265)
	assert cookie_of('SID=abc', 'sid') == ''
	// absent / empty value
	assert cookie_of('theme=dark', 'sid') == ''
	assert cookie_of('sid=', 'sid') == ''
}

fn test_session_roundtrip() {
	mut s := Store{}
	id := s.create('user-7', 0) or { panic('store should have room') }
	sess := s.get(id, 0) or { panic('session should exist') }
	assert sess.user_id == 'user-7'
	assert sess.csrf_token.len == 64 // a per-session CSRF token is minted too
}

fn test_unknown_session_is_none() {
	mut s := Store{}
	assert s.get('does-not-exist', 0) == none
}

fn test_session_ids_unguessable() {
	mut s := Store{}
	a := s.create('u', 0) or { panic('store should have room') }
	b := s.create('u', 0) or { panic('store should have room') }
	assert a.len == 64 // CSPRNG, 32 bytes hex
	assert a != b // never collide / never sequential
}

// A token is 64 lowercase hex chars backed by ONE allocation: the stored
// string itself (65 bytes with its NUL). It used to cost about 500 bytes: the
// rand.bytes array and hex.encode's growing buffer plus its copy.
fn test_new_token_is_hex_in_one_allocation() {
	tok := new_token()
	assert tok.len == 64
	for c in tok {
		assert (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`), tok
	}
	assert unsafe { tok.str[64] } == 0 // NUL-terminated like any V string
	assert new_token() != tok
	$if gcboehm ? {
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			_ := new_token()
		}
		per_token := (gc_heap_usage().total_bytes - before) / u64(rounds)
		assert per_token <= 96, 'new_token allocated ${per_token} bytes per call'
	}
}

// The server enforces the lifetime itself — Max-Age is only a client hint.
fn test_session_expires_server_side() {
	mut s := Store{}
	id := s.create('u', 0) or { panic('store should have room') }
	assert s.get(id, session_ttl_ns - 1) != none
	assert s.get(id, session_ttl_ns) == none
}

// The lazy sweep in create() reclaims expired sessions, at most once per
// sweep_every_ns.
fn test_sweep_reclaims_expired_sessions() {
	mut s := Store{}
	old := s.create('u', 0) or { panic('store should have room') }
	// Inside the sweep window nothing is walked, even past old's expiry.
	s.next_sweep = session_ttl_ns + sweep_every_ns
	s.create('u', session_ttl_ns) or { panic('store should have room') }
	assert s.sessions.len == 2
	// Once the window opens, the next create drops the expired entry.
	s.create('u', s.next_sweep) or { panic('store should have room') }
	assert s.sessions.len == 2
	assert old !in s.sessions
}

// A full store fails CLOSED for new logins and never evicts a live session;
// room reappears once a sweep reclaims expired entries.
fn test_store_is_capped() {
	mut s := Store{
		max_sessions: 2
	}
	a := s.create('u', 0) or { panic('store should have room') }
	b := s.create('u', 0) or { panic('store should have room') }
	assert s.create('u', 1) == none
	assert s.get(a, 1) != none
	assert s.get(b, 1) != none
	assert s.sessions.len == 2
	s.create('u', session_ttl_ns) or { panic('sweep should have freed room') }
	assert s.sessions.len == 1
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect.
fn serve(mut store Store, req string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop, mut store)
	return out.bytestr()
}

fn test_login_me_logout_flow() {
	mut s := Store{}
	// /login mints a session and sets the cookie with ALL security attributes.
	login := serve(mut s, 'POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')
	assert login.contains('200 OK')
	assert login.contains('HttpOnly')
	assert login.contains('Secure')
	assert login.contains('SameSite=Lax')
	assert login.contains('Path=/')
	assert login.contains('Max-Age=86400')
	assert session_ttl_s == 86400 // cookie lifetime == server-side lifetime
	assert login.contains('Content-Length: 0')
	sid := login.all_after('Set-Cookie: sid=').all_before(';')
	assert sid.len == 64 // CSPRNG id, 32 bytes hex
	// /me with that cookie -> the session's user, correct framing.
	me := serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=${sid}\r\n\r\n')
	assert me.contains('200 OK')
	body := me.all_after('\r\n\r\n')
	assert body == '{"user":"user-42"}'
	assert me.all_after('Content-Length: ').all_before('\r\n').int() == body.len
	// sid found even when it is not the first cookie pair.
	me2 := serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: theme=dark; sid=${sid}\r\n\r\n')
	assert me2.contains('200 OK')
	// /logout deletes the server-side session AND expires the cookie.
	logout := serve(mut s, 'GET /logout HTTP/1.1\r\nHost: x\r\nCookie: sid=${sid}\r\n\r\n')
	assert logout.contains('200 OK')
	assert logout.contains('Set-Cookie: sid=;')
	assert logout.contains('Max-Age=0')
	assert s.sessions.len == 0
	// A replayed cookie is dead after logout.
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=${sid}\r\n\r\n').contains('401')
	// Logout without a session still clears the cookie (idempotent).
	assert serve(mut s, 'GET /logout HTTP/1.1\r\nHost: x\r\n\r\n').contains('Max-Age=0')
}

// /login changes server state: any method but POST is refused and mints
// nothing, so crawlers, prefetchers and `<img src>` cannot create sessions.
fn test_login_requires_post() {
	mut s := Store{}
	for method in ['GET', 'HEAD', 'PUT'] {
		r := serve(mut s, '${method} /login HTTP/1.1\r\nHost: x\r\n\r\n')
		assert r.starts_with('HTTP/1.1 405 ')
		assert r.contains('Allow: POST\r\n')
		assert !r.contains('Set-Cookie')
	}
	assert s.sessions.len == 0
}

// A full store answers new logins with 503 + Retry-After and no cookie.
fn test_login_when_store_full() {
	mut s := Store{
		max_sessions: 0
	}
	r := serve(mut s, 'POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')
	assert r.starts_with('HTTP/1.1 503 ')
	assert r.contains('Retry-After: ${sweep_every_s}\r\n')
	assert !r.contains('Set-Cookie')
	assert s.sessions.len == 0
}

fn test_me_rejects_missing_or_bogus_cookie() {
	mut s := Store{}
	sid := s.create('user-42', i64(time.sys_mono_now())) or { panic('store should have room') }
	// no Cookie header at all
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\n\r\n').contains('401')
	// cookie present but not a live session id
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=bogus\r\n\r\n').contains('401')
	// empty sid value
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=\r\n\r\n').contains('401')
	// prefix collision: a valid id under `xsid` must never be read as `sid`
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: xsid=${sid}\r\n\r\n').contains('401')
}

fn test_unknown_route_and_malformed() {
	mut s := Store{}
	assert serve(mut s, 'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n').contains('404')
	// Malformed input gets the canned 400 and the connection is closed.
	mut event_loop := core.EventLoop{}
	mut out := []u8{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop, mut s) == .close
	assert out == response.tiny_bad_request_response
	mut out2 := []u8{}
	// no final CRLFCRLF
	assert handle('GET /me HTTP/1.1\r\nHost: x\r\n'.bytes(), mut out2, -1, unsafe { nil }, mut
		event_loop, mut s) == .close
	assert out2 == response.tiny_bad_request_response
}
