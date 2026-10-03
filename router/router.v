module router

// router — explicit, zero-allocation request routing for vanilla.
//
// The router is not an object you register routes into: it is your
// core.Handler, written as `match` statements over the request's path
// segments. Branches are ordinary code the C compiler sees whole, params are
// typed locals the V compiler checks, and nothing is allocated or looked up
// at runtime that the code does not spell out. This module provides the
// pieces that make that fast and correct:
//
//   m := router.method(req)                       // one length switch, an enum
//   mut path := router.path(req) or { ... 404 }   // zero-copy segment cursor
//   match path.next() {                           // each segment a view: no copy
//       'users' { return users(req, m, mut path, mut out) }
//       else {}
//   }
//   out << router.not_found
//
//   const users_405 = router.allow(.get, .head, .post)   // a 405 + Allow, built once
//
// A sub-router is just a function that takes the cursor and keeps popping.
// The whole path is walked once; each segment costs one memchr and is
// compared by the `match` (length first, then bytes).
import http1_1.request_parser { HttpRequest }

fn C.memchr(s voidptr, c int, n usize) voidptr

// Canned responses for the outcomes every router has.
pub const bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
pub const not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
pub const not_implemented = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// Method is the request method: RFC 9110's nine, in the order allow() lists
// them, or .unknown for any other token (answer it with not_implemented).
pub enum Method {
	get
	head
	post
	put
	delete
	connect
	options
	trace
	patch
	unknown
}

const method_names = ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH',
	'']!

// method returns the request's method: a switch on its length, then one
// fixed-size compare. Methods are case-sensitive (RFC 9110 §9.1).
pub fn method(req HttpRequest) Method {
	unsafe {
		b := &u8(req.buffer.data) + req.method.start
		match req.method.len {
			3 {
				if C.memcmp(b, c'GET', 3) == 0 {
					return .get
				}
				if C.memcmp(b, c'PUT', 3) == 0 {
					return .put
				}
			}
			4 {
				if C.memcmp(b, c'POST', 4) == 0 {
					return .post
				}
				if C.memcmp(b, c'HEAD', 4) == 0 {
					return .head
				}
			}
			5 {
				if C.memcmp(b, c'PATCH', 5) == 0 {
					return .patch
				}
				if C.memcmp(b, c'TRACE', 5) == 0 {
					return .trace
				}
			}
			6 {
				if C.memcmp(b, c'DELETE', 6) == 0 {
					return .delete
				}
			}
			7 {
				if C.memcmp(b, c'OPTIONS', 7) == 0 {
					return .options
				}
				if C.memcmp(b, c'CONNECT', 7) == 0 {
					return .connect
				}
			}
			else {}
		}
	}
	return .unknown
}

// Path is a cursor over the request path's segments, excluding any `?query`.
// It points into the request buffer and copies nothing: every segment it
// hands out is a view, valid until the handler returns (`.clone()` what must
// outlive the request). Segments are raw bytes: not percent-decoded.
pub struct Path {
	base &u8 = unsafe { nil } // first byte of the path
	len  int // path length, query excluded
mut:
	pos int // first byte of the next segment
}

// path returns the cursor for an origin-form target (`/...`), positioned
// before its first segment; none for any other form (`*`, absolute-form),
// which the app answers itself (usually not_found).
pub fn path(req HttpRequest) ?Path {
	base := unsafe { &u8(req.buffer.data) + req.path.start }
	if req.path.len == 0 || unsafe { base[0] } != `/` {
		return none
	}
	q := C.memchr(base, `?`, usize(req.path.len))
	return Path{
		base: base
		len:  if q == unsafe { nil } { req.path.len } else { int(unsafe { &u8(q) - base }) }
		pos:  1
	}
}

// next pops the next segment: `users`, then `42`, for `/users/42`. An empty
// segment — the root `/`, a trailing slash, `//` — is ''; once the path is
// spent, next keeps returning '' and done() is true.
@[inline]
pub fn (mut p Path) next() string {
	if p.pos > p.len {
		return ''
	}
	start := p.pos
	q := C.memchr(unsafe { p.base + start }, `/`, usize(p.len - start))
	end := if q == unsafe { nil } { p.len } else { int(unsafe { &u8(q) - p.base }) }
	p.pos = end + 1
	return unsafe { tos(p.base + start, end - start) }
}

// done reports whether every segment has been popped: true after `users` for
// `/users`, false for `/users/` (an empty segment is left).
@[inline]
pub fn (p &Path) done() bool {
	return p.pos > p.len
}

// rest returns everything not yet popped, slashes included — the catch-all:
// `css/app.css` after popping `files` from `/files/css/app.css`. '' once the
// path is spent.
@[inline]
pub fn (p &Path) rest() string {
	if p.pos > p.len {
		return ''
	}
	return unsafe { tos(p.base + p.pos, p.len - p.pos) }
}

// allow builds the complete `405 Method Not Allowed` response listing
// `methods` in its Allow header (RFC 9110 §15.5.6). Call it once, for a const:
// a leaf's `else` branch then answers 405 with one append.
pub fn allow(methods ...Method) []u8 {
	mut names := []string{}
	for i in 0 .. int(Method.unknown) {
		if unsafe { Method(i) } in methods {
			names << method_names[i]
		}
	}
	return ('HTTP/1.1 405 Method Not Allowed\r\nAllow: ' + names.join(', ') +
		'\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n').bytes()
}

// drop_body truncates the response appended into `out` from `start` to its
// head: a HEAD request served by a GET branch gets GET's headers (its
// Content-Length included) and no body (RFC 9110 §9.3.2).
pub fn drop_body(mut out []u8, start int) {
	unsafe {
		mut i := start
		for i + 3 < out.len {
			q := C.memchr(&u8(out.data) + i, 13, usize(out.len - 3 - i))
			if q == nil {
				return
			}
			i = int(&u8(q) - &u8(out.data))
			if out[i + 1] == 10 && out[i + 2] == 13 && out[i + 3] == 10 {
				out.len = i + 4
				return
			}
			i++
		}
	}
}
