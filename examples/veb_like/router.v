module main

import http_server.http1_1.request_parser { HttpRequest, Slice }

// Responses for the routing outcomes that aren't a handler hit. Built once.
const bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// router dispatches a request to the matching App method.
//
// Hot path: a single comptime-unrolled pass that matches "METHOD /path" exactly
// (static) or against a parameterized pattern (dynamic). A quick `/`-count check
// rejects non-candidates cheaply. The path length is taken WITHOUT the `?query`,
// so query strings never break matching.
//
// Cold path (no handler matched): a malformed request yields 400 (never panics —
// a panic would take down the worker thread); a known path under a different
// method yields 405 + Allow; anything else yields 404.
fn router(req_buffer []u8, _ int, app App) ![]u8 {
	req := request_parser.decode_http_request(req_buffer) or { return bad_request_response }
	mut params := map[string]Slice{}

	// Path length excluding any "?query" — both the slash-count rejection and the
	// matchers must stop at the query, or a query containing '/' (e.g.
	// ?redirect=/home) would defeat the match.
	path_len := path_len_without_query(req)
	// Count the path's slashes the SAME way routes are scanned (scan_attr), so the
	// quick-reject gate compares like with like.
	path_slashes, _ := scan_attr(&req.buffer[req.path.start], path_len)

	$for method in App.methods {
		for attr in method.attrs {
			slashes, star := scan_attr(attr.str, attr.len)
			if star >= 0 {
				// Catch-all route ("/prefix/*name") — spans any number of
				// segments, so it skips the slash-count gate.
				if try_wildcard_route(req, attr, attr.len, star, path_len, mut params) {
					return app.$method(req, params)
				}
			} else if slashes == path_slashes {
				// A route's '/'-count (method has none) must equal the path's.
				if try_static_route(req, attr, attr.len, path_len)
					|| try_dynamic_route(req, attr, attr.len, path_len, mut params) {
					return app.$method(req, params)
				}
			}
		}
	}
	// No handler matched — resolve the correct status off the hot path.
	return resolve_no_match(req, path_len)
}

// path_len_without_query returns the request path length up to (not including) a
// '?'. `req.path` spans the whole request-target, query included.
@[inline]
fn path_len_without_query(req HttpRequest) int {
	unsafe {
		q := C.memchr(&req.buffer[req.path.start], `?`, req.path.len)
		if q == nil {
			return req.path.len
		}
		return int(&u8(q) - &req.buffer[req.path.start])
	}
}

// resolve_no_match decides 405 vs 404: if the path matches a route under some
// OTHER method, it's 405 Method Not Allowed (with an Allow header listing them);
// otherwise 404. Runs only when nothing matched, so it never costs the hot path.
fn resolve_no_match(req HttpRequest, path_len int) []u8 {
	mut allow := []string{}
	$for method in App.methods {
		for attr in method.attrs {
			route_method, route_path := split_attr(attr)
			if route_path_matches(req, path_len, route_path) && route_method !in allow {
				allow << route_method
			}
		}
	}
	if allow.len > 0 {
		return method_not_allowed_response(allow)
	}
	return not_found_response
}

// method_not_allowed_response builds a 405 with an Allow header (RFC 9110 §15.5.6
// requires Allow on a 405).
fn method_not_allowed_response(allow []string) []u8 {
	allowed := allow.join(', ')
	return 'HTTP/1.1 405 Method Not Allowed\r\nAllow: ${allowed}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
}

// split_attr splits a route attribute "METHOD /path" into ("METHOD", "/path").
fn split_attr(attr string) (string, string) {
	sp := attr.index(' ') or { return '', attr }
	return attr[..sp], attr[sp + 1..]
}

// route_path_matches reports whether a route's path pattern (with `:param`
// segments) matches the request path, ignoring the method. Used only on the cold
// 404/405 path, so it favors clarity over the hot matchers' micro-optimizations.
fn route_path_matches(req HttpRequest, path_len int, route_path string) bool {
	rp := req.path.start
	mut ai := 0
	mut ri := 0
	for ai < route_path.len {
		c := route_path[ai]
		if c == `*` {
			return true // catch-all: the literal prefix matched; '*' eats the rest
		} else if c == `:` {
			ai++ // skip ':'
			for ai < route_path.len && route_path[ai] != `/` {
				ai++ // skip the param name
			}
			for ri < path_len && req.buffer[rp + ri] != `/` {
				ri++ // skip the param value
			}
		} else {
			if ri >= path_len || c != req.buffer[rp + ri] {
				return false
			}
			ai++
			ri++
		}
	}
	return ri == path_len
}
