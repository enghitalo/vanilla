module main

// SOLUTION: pure logic test — works today.
// Cookie parsing and the session store are pure/in-memory, so the round-trip
// and the unguessability invariant are unit testable.

fn test_parse_cookies() {
	m := parse_cookies('sid=abc123; theme=dark')
	assert m['sid'] == 'abc123'
	assert m['theme'] == 'dark'
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
