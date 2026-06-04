module main

// Exhaustive coverage of every route TYPE the router supports. Each case drives
// the real router() and checks status / headers / body.
//
// Routes under test (see main.v):
//   GET  /users                                              static
//   POST /users                                              static
//   GET|PUT|PATCH|DELETE /users/:id                          one param, many verbs
//   GET  /users/:id/profile                                  param + literal tail
//   GET  /users/:user_id/posts/:post_id                      two params
//   GET  /users/:user_id/posts/:post_id/comments/:comment_id three params, deep
//   GET  /tags/:a/:b/:c                                       three consecutive params
//   GET  /search/:term                                       single param
//   GET  /files/*path                                        catch-all (wildcard)
//   GET  /proxy/*upstream                                    catch-all (wildcard)

fn app() App {
	return App{}
}

fn resp(raw string) string {
	r := router(raw.bytes(), -1, app()) or { panic('router error: ${err}') }
	return r.bytestr()
}

fn req(method string, target string) string {
	return '${method} ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'
}

fn body_of(method string, target string) string {
	r := resp(req(method, target))
	idx := r.index('\r\n\r\n') or { return '' }
	return r[idx + 4..]
}

fn status(method string, target string) string {
	return resp(req(method, target)).all_before('\r\n')
}

// ── static ──────────────────────────────────────────────────────────────────

fn test_static() {
	assert resp(req('GET', '/users')).contains('200 OK')
	assert body_of('GET', '/users') == '[]'
	assert resp(req('POST', '/users')).contains('201 Created')
	assert body_of('POST', '/users') == '{"id":1}'
}

// ── one param at the end, across verbs ───────────────────────────────────────

fn test_param_end_verbs() {
	assert body_of('GET', '/users/42') == '{"id":"42"}'
	assert body_of('PUT', '/users/42') == '{"replaced":"42"}'
	assert body_of('PATCH', '/users/42') == '{"updated":"42"}'
	assert body_of('DELETE', '/users/42') == '{"deleted":"42"}'
}

fn test_param_end_405_lists_every_verb() {
	r := resp(req('POST', '/users/42')) // POST not defined on /users/:id
	assert r.contains('405 Method Not Allowed')
	for m in ['GET', 'PUT', 'PATCH', 'DELETE'] {
		assert r.contains(m), 'Allow should list ${m}'
	}
}

// ── param + literal tail ─────────────────────────────────────────────────────

fn test_param_then_literal() {
	assert body_of('GET', '/users/7/profile') == '{"id":"7","section":"profile"}'
}

// ── multiple params ──────────────────────────────────────────────────────────

fn test_two_params() {
	assert body_of('GET', '/users/7/posts/99') == '{"user":"7","post":"99"}'
}

fn test_three_params_deep() {
	assert body_of('GET', '/users/7/posts/99/comments/5') == '{"user":"7","post":"99","comment":"5"}'
}

fn test_three_consecutive_params() {
	assert body_of('GET', '/tags/red/green/blue') == '{"a":"red","b":"green","c":"blue"}'
}

fn test_single_param() {
	assert body_of('GET', '/search/vlang') == '{"term":"vlang"}'
}

// ── catch-all / wildcard ─────────────────────────────────────────────────────

fn test_wildcard_single_segment() {
	assert body_of('GET', '/files/logo.png') == '{"file":"logo.png"}'
}

fn test_wildcard_captures_slashes() {
	// The defining property: '*' eats the rest of the path, slashes included.
	assert body_of('GET', '/files/css/app.css') == '{"file":"css/app.css"}'
	assert body_of('GET', '/files/a/b/c/d.png') == '{"file":"a/b/c/d.png"}'
	assert body_of('GET', '/proxy/http/example.com/x') == '{"upstream":"http/example.com/x"}'
}

fn test_wildcard_empty_tail() {
	// "/files/" matches with an empty capture; "/files" (no slash) does not.
	assert body_of('GET', '/files/') == '{"file":""}'
	assert status('GET', '/files') == 'HTTP/1.1 404 Not Found'
}

fn test_wildcard_ignores_query() {
	assert body_of('GET', '/files/a/b.js?v=2') == '{"file":"a/b.js"}'
}

// ── 404s ─────────────────────────────────────────────────────────────────────

fn test_404s() {
	assert status('GET', '/') == 'HTTP/1.1 404 Not Found'
	assert status('GET', '/nope') == 'HTTP/1.1 404 Not Found'
	assert status('GET', '/users') == 'HTTP/1.1 200 OK' // sanity: this one exists
	assert status('GET', '/users/7/posts') == 'HTTP/1.1 404 Not Found' // partial
	assert status('GET', '/USERS/7') == 'HTTP/1.1 404 Not Found' // case-sensitive
	assert status('GET', '/tags/a/b') == 'HTTP/1.1 404 Not Found' // needs 3 segs
}

// ── query string: params come from the path, values from ?… ──────────────────

fn test_query_does_not_break_matching() {
	assert body_of('GET', '/users/42?foo=bar') == '{"id":"42"}'
	// a '/' inside the query must not inflate the path's slash count
	assert status('GET', '/users/42?next=/home') == 'HTTP/1.1 200 OK'
}

// ── security: URL-derived values are JSON-escaped (params AND wildcards) ──────

fn test_injection_escaped_in_param() {
	assert body_of('GET', '/search/a"b') == '{"term":"a\\"b"}'
}

fn test_injection_escaped_in_wildcard() {
	assert body_of('GET', '/files/a"b.txt') == '{"file":"a\\"b.txt"}'
}

// ── crash safety ─────────────────────────────────────────────────────────────

fn test_malformed_is_400() {
	assert resp('GARBAGE\r\n\r\n').contains('400 Bad Request')
}
