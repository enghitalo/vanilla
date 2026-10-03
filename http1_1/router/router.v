module router

// router — explicit, zero-allocation request routing for vanilla.
//
// The router is not an object you register routes into: it is your
// core.Handler, written as `match` statements over the request's path
// segments. Branches are ordinary code the C compiler sees whole, params are
// typed locals the V compiler checks, and nothing is allocated or looked up
// at runtime that the code does not spell out. This module only reads the
// request line, straight from the raw request; every response (404 and 405
// included) is the app's:
//
//   fn route(req_buffer []u8, mut out []u8, ...) core.Step {  // the core.Handler
//       m := router.method(req_buffer)       // a switch on the first space, an enum
//       mut path := router.path(req_buffer)  // zero-copy segment cursor
//       match path.next() {                  // each segment a view: no copy
//           'users' { return users(m, mut path, mut out) }
//           else {}
//       }
//       out << not_found                     // the app's own response
//       return .done
//   }
//
// Routing parses no headers: a route that needs them decodes the request
// itself (request_parser.decode_into). A sub-router is just a function that
// takes the cursor and keeps popping. The path is walked once; each segment
// costs one memchr and is compared by the `match` (length first, then bytes).

fn C.memchr(s voidptr, c int, n usize) voidptr

// Method is the request method: RFC 9110's nine, or .unknown for any other
// token, including a request line without one.
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

// method reads the request's method, the token before the request line's
// first space: a switch on where that space is, then one fixed-size compare.
// Methods are case-sensitive (RFC 9110 §9.1).
pub fn method(req_buffer []u8) Method {
	n := req_buffer.len
	unsafe {
		b := &u8(req_buffer.data)
		if n > 3 && b[3] == ` ` {
			if C.memcmp(b, c'GET', 3) == 0 {
				return .get
			}
			if C.memcmp(b, c'PUT', 3) == 0 {
				return .put
			}
		} else if n > 4 && b[4] == ` ` {
			if C.memcmp(b, c'POST', 4) == 0 {
				return .post
			}
			if C.memcmp(b, c'HEAD', 4) == 0 {
				return .head
			}
		} else if n > 5 && b[5] == ` ` {
			if C.memcmp(b, c'PATCH', 5) == 0 {
				return .patch
			}
			if C.memcmp(b, c'TRACE', 5) == 0 {
				return .trace
			}
		} else if n > 6 && b[6] == ` ` {
			if C.memcmp(b, c'DELETE', 6) == 0 {
				return .delete
			}
		} else if n > 7 && b[7] == ` ` {
			if C.memcmp(b, c'OPTIONS', 7) == 0 {
				return .options
			}
			if C.memcmp(b, c'CONNECT', 7) == 0 {
				return .connect
			}
		}
	}
	return .unknown
}

// no_path is the single segment of a request with no path to route: a
// request line without an origin-form target (`OPTIONS *`, absolute-form, or
// malformed). A path segment never contains a space, so it matches no route,
// not even `/`: the app's fallback, its 404, answers.
const no_path = ' '

// Path is a cursor over the request path's segments, excluding any `?query`.
// It points into the request buffer and copies nothing: every segment it
// hands out is a view, valid until the handler returns (`.clone()` what must
// outlive the request). Segments are raw bytes: not percent-decoded.
pub struct Path {
	base &u8 = unsafe { nil } // the path's leading `/`
	len  int // path length, query excluded
mut:
	pos int // first byte of the next segment
}

// path returns the cursor over the request's path, read from the request
// line and positioned before its first segment. It never fails: a request
// with no path to route yields one segment that no route matches (no_path).
pub fn path(req_buffer []u8) Path {
	n := req_buffer.len
	unsafe {
		b := &u8(req_buffer.data)
		// The target starts after the method's space (and any extra spaces, as
		// request_parser tolerates them). A line break first: no target at all.
		mut i := 0
		for i < n && b[i] != ` ` {
			if b[i] == `\r` || b[i] == `\n` {
				return Path{
					base: no_path.str
					len:  1
				}
			}
			i++
		}
		for i < n && b[i] == ` ` {
			i++
		}
		if i == n || b[i] != `/` {
			return Path{
				base: no_path.str
				len:  1
			}
		}
		start := i
		i++
		for i < n {
			c := b[i]
			if c == ` ` || c == `?` || c == `\r` || c == `\n` {
				break
			}
			i++
		}
		return Path{
			base: b + start
			len:  i - start
			pos:  1
		}
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
