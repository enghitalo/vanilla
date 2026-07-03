module main

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
	id := s.create('user-7')
	sess := s.get(id) or { panic('session should exist') }
	assert sess.user_id == 'user-7'
	assert sess.csrf_token.len == 64 // a per-session CSRF token is minted too
}

fn test_unknown_session_is_none() {
	mut s := Store{}
	assert s.get('does-not-exist') == none
}

fn test_session_ids_unguessable() {
	mut s := Store{}
	a := s.create('u')
	b := s.create('u')
	assert a.len == 64 // CSPRNG, 32 bytes hex
	assert a != b // never collide / never sequential
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect.
fn serve(mut store Store, req string) !string {
	mut out := []u8{}
	handle(req.bytes(), -1, mut out, mut store)!
	return out.bytestr()
}

fn test_login_me_logout_flow() ! {
	mut s := Store{}
	// /login mints a session and sets the cookie with ALL security attributes.
	login := serve(mut s, 'GET /login HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert login.contains('200 OK')
	assert login.contains('HttpOnly')
	assert login.contains('Secure')
	assert login.contains('SameSite=Lax')
	assert login.contains('Path=/')
	assert login.contains('Max-Age=86400')
	assert login.contains('Content-Length: 0')
	sid := login.all_after('Set-Cookie: sid=').all_before(';')
	assert sid.len == 64 // CSPRNG id, 32 bytes hex
	// /me with that cookie -> the session's user, correct framing.
	me := serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=${sid}\r\n\r\n')!
	assert me.contains('200 OK')
	body := me.all_after('\r\n\r\n')
	assert body == '{"user":"user-42"}'
	assert me.all_after('Content-Length: ').all_before('\r\n').int() == body.len
	// sid found even when it is not the first cookie pair.
	me2 := serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: theme=dark; sid=${sid}\r\n\r\n')!
	assert me2.contains('200 OK')
	// /logout expires the cookie.
	logout := serve(mut s, 'GET /logout HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert logout.contains('200 OK')
	assert logout.contains('Set-Cookie: sid=;')
	assert logout.contains('Max-Age=0')
}

fn test_me_rejects_missing_or_bogus_cookie() ! {
	mut s := Store{}
	sid := s.create('user-42')
	// no Cookie header at all
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\n\r\n')!.contains('401')
	// cookie present but not a live session id
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=bogus\r\n\r\n')!.contains('401')
	// empty sid value
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: sid=\r\n\r\n')!.contains('401')
	// prefix collision: a valid id under `xsid` must never be read as `sid`
	assert serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\nCookie: xsid=${sid}\r\n\r\n')!.contains('401')
}

fn test_unknown_route_and_malformed() {
	mut s := Store{}
	if resp := serve(mut s, 'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n') {
		assert resp.contains('404')
	} else {
		assert false, '404 route must still produce a response'
	}
	// Malformed input must surface as a handler error, never a response.
	if _ := serve(mut s, 'garbage') {
		assert false, 'garbage request must not produce a response'
	}
	if _ := serve(mut s, 'GET /me HTTP/1.1\r\nHost: x\r\n') { // no final CRLFCRLF
		assert false, 'truncated request must not produce a response'
	}
}
