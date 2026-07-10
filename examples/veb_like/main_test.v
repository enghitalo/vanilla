module main

import http_server.core

// Exhaustive coverage of every route TYPE the router supports. Each case drives
// the real router() through the same closure shape as ServerConfig.handler
// (BEST_PRACTICES §9: handlers are pure, so tests feed raw request bytes — no
// listening socket needed) and checks status / headers / body.
// `${}` interpolation is fine HERE: tests are scaffolding, not hot-path code.
//
// Routes under test (see main.v):
//   GET  /users                                              static
//   POST /users                                              static
//   GET|PUT|PATCH|DELETE /users/:id                          one param, many verbs
//   GET  /users/:id/profile                                  param + literal tail
//   GET  /users/:user_id/posts/:post_id                      two params
//   GET  /users/:user_id/posts/:post_id/comments/:comment_id three params, deep
//   GET  /tags/:a/:b/:c                                       three consecutive params
//   GET  /search/:term                                        single param
//   GET  /files/*path                                         catch-all (wildcard)
//   GET  /proxy/*upstream                                     catch-all (wildcard)

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-string shape the assertions expect — the closure
// below is the exact handler wired in main().
fn serve(raw string) string {
	app := App{}
	handler := fn [app] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		out << router(req_buffer, client_fd, app) or {
			out << bad_request_response
			return .close
		}
		return .done
	}
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handler(raw.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	return out.bytestr()
}

fn req(method string, target string) string {
	return '${method} ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'
}

fn body_of(method string, target string) string {
	r := serve(req(method, target))
	idx := r.index('\r\n\r\n') or { return '' }
	return r[idx + 4..]
}

fn status(method string, target string) string {
	return serve(req(method, target)).all_before('\r\n')
}

// ── static ──────────────────────────────────────────────────────────────────

fn test_static() {
	assert serve(req('GET', '/users')).contains('200 OK')
	assert body_of('GET', '/users') == '[]'
	assert serve(req('POST', '/users')).contains('201 Created')
	assert body_of('POST', '/users') == '{"id":1}'
}

fn test_content_length_is_computed() {
	// The framing writes Content-Length from the body's actual length.
	assert serve(req('GET', '/users')).contains('Content-Length: 2') // '[]'
	assert serve(req('POST', '/users')).contains('Content-Length: 8') // '{"id":1}'
	assert serve(req('GET', '/users/42')).contains('Content-Length: 11') // '{"id":"42"}'
}

// ── one param at the end, across verbs ───────────────────────────────────────

fn test_param_end_verbs() {
	assert body_of('GET', '/users/42') == '{"id":"42"}'
	assert body_of('PUT', '/users/42') == '{"replaced":"42"}'
	assert body_of('PATCH', '/users/42') == '{"updated":"42"}'
	assert body_of('DELETE', '/users/42') == '{"deleted":"42"}'
}

fn test_param_end_405_lists_every_verb() {
	r := serve(req('POST', '/users/42')) // POST not defined on /users/:id
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

fn test_injection_escaped_backslash_and_controls() {
	// backslash must double; a raw TAB byte must become \t (RFC 8259).
	assert body_of('GET', '/search/a\\b') == '{"term":"a\\\\b"}'
	assert body_of('GET', '/search/a\tb') == '{"term":"a\\tb"}'
}

// ── crash safety: every malformed shape is a 400, never a panic ───────────────

fn test_malformed_is_400() {
	assert serve('GARBAGE\r\n\r\n').contains('400 Bad Request')
}

fn test_malformed_empty_buffer_is_400() {
	assert serve('').contains('400 Bad Request')
}

fn test_malformed_truncated_head_is_400() {
	// head never terminated with the blank line
	assert serve('GET / HTTP/1.1\r\nHost: x').contains('400 Bad Request')
}

fn test_malformed_method_only_line_is_400() {
	assert serve('GET\r\n\r\n').contains('400 Bad Request')
}
