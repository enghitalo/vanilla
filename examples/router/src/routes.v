module main

// The route tree. Each function is a node: it pops the segments it owns from
// the cursor and either answers (a leaf) or hands the cursor to a child. A
// leaf first checks the path is fully consumed (else 404), then the method
// (else its own 405 const, listing exactly what its branches serve), so the
// HTTP outcome is visible right where the route is.
//
//   GET  /users                                              static
//   POST /users                                              static
//   GET|PUT|PATCH|DELETE /users/:id                          one param, many verbs
//   GET  /users/:id/profile                                  param + literal tail
//   GET  /users/:user_id/posts/:post_id                      two params
//   GET  /users/:user_id/posts/:post_id/comments/:comment_id three params, deep
//   GET  /tags/:a/:b/:c                                       three consecutive params
//   GET  /search/:term                                        single param
//   GET  /files/*path, /proxy/*upstream                       catch-all
//   GET  /delay/:ms                                           suspends on a timer
//
// GET branches also take HEAD: route() drops the body afterwards.
import core
import router { Method, Path }

const users_list_response = fixed_json(json_200_head, '[]')
const user_created_response = fixed_json(json_201_head, '{"id":1}')
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const not_implemented_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// The 405 of each leaf, listing exactly what its branches serve.
const users_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, POST\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const user_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, PUT, DELETE, PATCH\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const get_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// route is the server's core.Handler and the root node. It reads only the
// request line: no route here needs a header (one that did would decode the
// request itself, with request_parser.decode_into).
fn route(req_buffer []u8, mut out []u8, _ int, _ voidptr, mut event_loop core.EventLoop) core.Step {
	m := router.method(req_buffer)
	mut path := router.path(req_buffer)
	start := out.len
	step := match path.next() {
		'users' { users(m, mut path, mut out) }
		'tags' { tags(m, mut path, mut out) }
		'search' { search(m, mut path, mut out) }
		'files' { catch_all(m, mut path, mut out, '{"file":') }
		'proxy' { catch_all(m, mut path, mut out, '{"upstream":') }
		'delay' { delay(m, mut path, mut out, mut event_loop) }
		else { not_found(mut out) }
	}
	// HEAD gets the GET answer's headers, Content-Length included, and no body
	// (RFC 9110 §9.3.2). Not for a suspended request: it answers later.
	if m == .head && step != .suspend {
		drop_body(mut out, start)
	}
	return step
}

// /users, /users/:id, /users/:id/profile, /users/:user_id/posts/...
fn users(m Method, mut path Path, mut out []u8) core.Step {
	if path.done() { // /users
		match m {
			.get, .head { out << users_list_response }
			.post { out << user_created_response }
			else { out << users_405 }
		}
		return .done
	}
	id := path.next()
	if id == '' {
		return not_found(mut out)
	}
	if path.done() { // /users/:id
		match m {
			.get, .head { json_field(mut out, '{"id":', id, '}') }
			.put { json_field(mut out, '{"replaced":', id, '}') }
			.patch { json_field(mut out, '{"updated":', id, '}') }
			.delete { json_field(mut out, '{"deleted":', id, '}') }
			else { out << user_405 }
		}
		return .done
	}
	match path.next() {
		'profile' {
			if !path.done() {
				return not_found(mut out)
			}
			if m != .get && m != .head {
				out << get_405
				return .done
			}
			json_field(mut out, '{"id":', id, ',"section":"profile"}')
			return .done
		}
		'posts' {
			return posts(m, id, mut path, mut out)
		}
		else {
			return not_found(mut out)
		}
	}
}

// /users/:user_id/posts/:post_id, /users/:user_id/posts/:post_id/comments/:comment_id
fn posts(m Method, user_id string, mut path Path, mut out []u8) core.Step {
	post_id := path.next()
	if post_id == '' {
		return not_found(mut out)
	}
	if path.done() {
		if m != .get && m != .head {
			out << get_405
			return .done
		}
		b := begin_json(mut out)
		ws(mut out, '{"user":')
		json_string(mut out, user_id)
		ws(mut out, ',"post":')
		json_string(mut out, post_id)
		ws(mut out, '}')
		end_json(mut out, b)
		return .done
	}
	if path.next() != 'comments' {
		return not_found(mut out)
	}
	comment_id := path.next()
	if comment_id == '' || !path.done() {
		return not_found(mut out)
	}
	if m != .get && m != .head {
		out << get_405
		return .done
	}
	b := begin_json(mut out)
	ws(mut out, '{"user":')
	json_string(mut out, user_id)
	ws(mut out, ',"post":')
	json_string(mut out, post_id)
	ws(mut out, ',"comment":')
	json_string(mut out, comment_id)
	ws(mut out, '}')
	end_json(mut out, b)
	return .done
}

// /tags/:a/:b/:c
fn tags(m Method, mut path Path, mut out []u8) core.Step {
	a := path.next()
	b := path.next()
	c := path.next()
	if a == '' || b == '' || c == '' || !path.done() {
		return not_found(mut out)
	}
	if m != .get && m != .head {
		out << get_405
		return .done
	}
	body := begin_json(mut out)
	ws(mut out, '{"a":')
	json_string(mut out, a)
	ws(mut out, ',"b":')
	json_string(mut out, b)
	ws(mut out, ',"c":')
	json_string(mut out, c)
	ws(mut out, '}')
	end_json(mut out, body)
	return .done
}

// /search/:term — one segment; a richer query would come from ?q=… (decode the
// request with request_parser.decode_into, then req.get_query).
fn search(m Method, mut path Path, mut out []u8) core.Step {
	term := path.next()
	if term == '' || !path.done() {
		return not_found(mut out)
	}
	if m != .get && m != .head {
		out << get_405
		return .done
	}
	json_field(mut out, '{"term":', term, '}')
	return .done
}

// /files/*path, /proxy/*upstream: everything after the prefix, slashes
// included. `/files/` captures ''; `/files` (no slash) is not this route.
fn catch_all(m Method, mut path Path, mut out []u8, key string) core.Step {
	if path.done() {
		return not_found(mut out)
	}
	if m != .get && m != .head {
		out << get_405
		return .done
	}
	json_field(mut out, key, path.rest(), '}')
	return .done
}

// /delay/:ms — parks the request on a timer and returns .suspend; the worker
// serves other connections until it fires (delay_linux.c.v; elsewhere: 501).
const delay_bad_ms_response = fixed_json(json_400_head, '{"error":"ms must be 0..10000"}')

fn delay(m Method, mut path Path, mut out []u8, mut event_loop core.EventLoop) core.Step {
	text := path.next()
	if text == '' || !path.done() {
		return not_found(mut out)
	}
	if m != .get && m != .head {
		out << get_405
		return .done
	}
	ms := parse_ms(text) or {
		out << delay_bad_ms_response
		return .done
	}
	$if linux {
		return start_delay(ms, mut out, mut event_loop)
	} $else {
		out << not_implemented_response
		return .done
	}
}

// parse_ms reads a decimal millisecond count in 0..10000, in place.
fn parse_ms(s string) ?int {
	if s.len == 0 || s.len > 5 {
		return none
	}
	mut n := 0
	for c in s {
		if c < `0` || c > `9` {
			return none
		}
		n = n * 10 + int(c - `0`)
	}
	return if n <= 10_000 { n } else { none }
}

@[inline]
fn not_found(mut out []u8) core.Step {
	out << not_found_response
	return .done
}
