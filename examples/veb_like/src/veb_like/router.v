module veb_like

// veb_like — declarative routing for vanilla: annotate the methods of your App
// with `@['METHOD /path']` and the router dispatches to them.
//
//   @['GET /users/:id']
//   fn (app &App) show_user(req HttpRequest, p &veb_like.Params, mut out []u8) core.Step {
//       ... append the response into out, using p.get('id') ...
//       return .done
//   }
//
//   router := veb_like.new[App](&App{})!
//   handler: fn [router] (req []u8, mut out []u8, fd int, ws voidptr, mut el core.EventLoop) core.Step {
//       return router.handle(req, mut out, fd, ws, mut el)
//   }
//
// Everything that can be decided before the first request is decided once, in
// new(): the attributes are read and compiled into a segment trie, routing
// conflicts are reported as errors, and every node's complete 405 response is
// prebuilt. A request then costs one parse, one walk of the trie (O(path
// depth), independent of how many routes exist), and one direct method call.
// It allocates nothing — not for a hit, a 404, a 405 or a 400 — which matters
// twice over: under `-gc none` (vanilla's production build) a per-request
// allocation is a leak, and under the GC it is churn that caps multi-core
// throughput.
//
// Handlers keep the full core.Handler contract: they append the raw response
// into `out` and return a core.Step, so a route can `.suspend` on
// event_loop.watch_fd (async DB, timers, upstreams) or `.close`. Two shapes:
//
//   (req HttpRequest, p &Params, mut out []u8) core.Step
//   (req HttpRequest, p &Params, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step
//
// Every method of App that returns core.Step is a handler, routed or not, so it
// must have one of these shapes; keep helpers on another type or have them
// return something else.
//
// Route syntax: `:name` matches one non-empty segment, `*name` (last segment
// only) matches the rest of the path, slashes included, possibly empty. Static
// segments win over `:name`, which wins over `*name`; a dead end backtracks.
// Matching is byte-exact (case-sensitive, no percent-decoding) and stops at
// '?'. Only origin-form targets (`/...`) are routed.
//
// HTTP semantics: 404 when no route matches the path; 405 with an Allow header
// when the path matches under other methods; HEAD is served by the GET route
// when no HEAD route exists (the body is dropped from what the handler wrote,
// unless it suspends); 501 for a method outside RFC 9110's nine; 400 + close
// for a request the parser rejects.
import core
import http1_1.request_parser { HttpRequest, Slice }
import http1_1.response

fn C.memchr(s voidptr, c int, n usize) voidptr

// max_params caps the :name and *name segments of one route.
pub const max_params = 8

const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const not_implemented_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const method_not_allowed_head = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: '
const method_not_allowed_tail = '\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// The nine RFC 9110 methods, in the order Allow lists them. A method's index
// selects its slot in Node.route.
const method_names = ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH']!
const m_get = 0
const m_head = 1

// Router is built once by new() and only read afterwards, so every worker
// shares it without a lock.
@[heap]
pub struct Router[T] {
	app   &T
	table Table
pub mut:
	// not_found is the complete response for a path no route matches. Replace
	// it before the server starts (a custom 404 page); never during serving.
	not_found []u8 = not_found_response
}

// new reads the route attributes of T's handler methods and compiles them.
// It fails on a malformed route or two handlers claiming the same method and
// path, so a routing mistake stops the server at startup, not at request time.
pub fn new[T](app &T) !&Router[T] {
	mut t := Table{
		nodes: [Node{}]
	}
	mut handler := 0
	$for method in T.methods {
		$if method.return_type is core.Step {
			$if method.args.len != 3 && method.args.len != 6 {
				$compile_error('veb_like: every method returning core.Step is a route handler and must take (req HttpRequest, p &veb_like.Params, mut out []u8), optionally followed by (client_fd int, worker_state voidptr, mut event_loop core.EventLoop)')
			}
			for attr in method.attrs {
				t.add(attr, handler, method.name)!
			}
			handler++
		}
	}
	t.finish()
	return &Router[T]{
		app:   app
		table: t
	}
}

// handle is a core.Handler: wire it into ServerConfig.handler through a
// closure capturing the router.
@[direct_array_access]
pub fn (r &Router[T]) handle(req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut req := HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}
	m := method_index(req)
	if m < 0 {
		out << not_implemented_response
		return .done
	}
	mut p := Params{}
	ni := r.table.lookup(req, mut p)
	if ni < 0 {
		out << r.not_found
		return .done
	}
	node := unsafe { &r.table.nodes[ni] }
	mut rid := node.route[m]
	head_as_get := rid < 0 && m == m_head && node.route[m_get] >= 0
	if head_as_get {
		rid = node.route[m_get]
	}
	if rid < 0 {
		out << node.allow
		return .done
	}
	route := unsafe { &r.table.routes[rid] }
	p.route = route
	start := out.len
	step := r.dispatch(route.handler, req, &p, mut out, client_fd, worker_state, mut event_loop)
	if head_as_get && step != .suspend {
		drop_body(mut out, start)
	}
	return step
}

// dispatch calls T's handler number `h`. The `$for` unrolls into one direct
// call per handler behind an integer compare; it never reads method.attrs,
// which V would materialize as a fresh heap array on every pass.
fn (r &Router[T]) dispatch(h int, req HttpRequest, p &Params, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	app := r.app
	mut i := 0
	$for method in T.methods {
		$if method.return_type is core.Step {
			if i == h {
				// A forwarded `mut` parameter is passed without `mut` in a
				// comptime call (V rejects `mut out` here); it is still the
				// caller's buffer.
				$if method.args.len == 3 {
					return app.$method(req, p, out)
				} $else {
					return app.$method(req, p, out, client_fd, worker_state, event_loop)
				}
			}
			i++
		}
	}
	return .close // unreachable: route ids only name handlers
}

// drop_body truncates the response appended from `start` to its head, for a
// HEAD request served by a GET handler.
fn drop_body(mut out []u8, start int) {
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

// method_index maps the request method to its slot, or -1 when it is not one
// of the nine: one switch on the length, then fixed-size compares.
@[inline]
fn method_index(req HttpRequest) int {
	b := unsafe { &u8(req.buffer.data) + req.method.start }
	return method_slot(b, req.method.len)
}

@[direct_array_access]
fn method_slot(b &u8, len int) int {
	unsafe {
		match len {
			3 {
				if C.memcmp(b, c'GET', 3) == 0 {
					return m_get
				}
				if C.memcmp(b, c'PUT', 3) == 0 {
					return 3
				}
			}
			4 {
				if C.memcmp(b, c'POST', 4) == 0 {
					return 2
				}
				if C.memcmp(b, c'HEAD', 4) == 0 {
					return m_head
				}
			}
			5 {
				if C.memcmp(b, c'PATCH', 5) == 0 {
					return 8
				}
				if C.memcmp(b, c'TRACE', 5) == 0 {
					return 7
				}
			}
			6 {
				if C.memcmp(b, c'DELETE', 6) == 0 {
					return 4
				}
			}
			7 {
				if C.memcmp(b, c'OPTIONS', 7) == 0 {
					return 6
				}
				if C.memcmp(b, c'CONNECT', 7) == 0 {
					return 5
				}
			}
			else {}
		}
	}
	return -1
}

// ── the compiled routes ──────────────────────────────────────────────────────

struct Node {
mut:
	seg     string // the literal a static child matches
	statics []int  // static children, as indexes into Table.nodes
	param   int    = -1 // the :name child
	wild    int    = -1 // the *name child
	route   [9]int = [-1, -1, -1, -1, -1, -1, -1, -1, -1]! // route id per method slot
	allow   []u8 // complete 405 response; empty when no route ends here
}

struct Route {
	handler int      // position of the handler among T's handler methods
	names   []string // param names in path order, without ':' / '*'
	attr    string   // the attribute, for error messages
	fn_name string
}

// Table is the non-generic part of the router: compiled once per App type's
// routes, walked by every request.
struct Table {
mut:
	nodes  []Node
	routes []Route
}

// add compiles one attribute. An attribute whose first word is not an HTTP
// method (`inline`, `direct_array_access`, ...) is not a route and is skipped.
fn (mut t Table) add(attr string, handler int, fn_name string) ! {
	sp := attr.index_u8(` `)
	if sp <= 0 {
		return
	}
	m := method_slot(attr.str, sp)
	if m < 0 {
		return
	}
	pattern := attr[sp + 1..]
	if pattern.len == 0 || pattern[0] != `/` {
		return error('veb_like: ${fn_name}: route `${attr}` must be `METHOD /path`')
	}
	segs := pattern[1..].split('/')
	mut ni := 0
	mut names := []string{}
	for i, seg in segs {
		if seg.len > 0 && (seg[0] == `:` || seg[0] == `*`) {
			if seg.len == 1 {
				return error('veb_like: ${fn_name}: route `${attr}` has a nameless `${seg}` segment')
			}
			if seg[1..] in names {
				return error('veb_like: ${fn_name}: route `${attr}` names `${seg[1..]}` twice')
			}
			names << seg[1..]
			if seg[0] == `*` {
				if i != segs.len - 1 {
					return error('veb_like: ${fn_name}: route `${attr}`: `${seg}` must be the last segment')
				}
				if t.nodes[ni].wild < 0 {
					t.nodes << Node{}
					t.nodes[ni].wild = t.nodes.len - 1
				}
				ni = t.nodes[ni].wild
			} else {
				if t.nodes[ni].param < 0 {
					t.nodes << Node{}
					t.nodes[ni].param = t.nodes.len - 1
				}
				ni = t.nodes[ni].param
			}
			continue
		}
		mut next := -1
		for c in t.nodes[ni].statics {
			if t.nodes[c].seg == seg {
				next = c
				break
			}
		}
		if next < 0 {
			t.nodes << Node{
				seg: seg
			}
			next = t.nodes.len - 1
			t.nodes[ni].statics << next
		}
		ni = next
	}
	if names.len > max_params {
		return error('veb_like: ${fn_name}: route `${attr}` has ${names.len} params, the limit is ${max_params}')
	}
	if t.nodes[ni].route[m] >= 0 {
		other := t.routes[t.nodes[ni].route[m]]
		return error('veb_like: ${fn_name}: route `${attr}` is already handled by ${other.fn_name} (`${other.attr}`)')
	}
	t.nodes[ni].route[m] = t.routes.len
	t.routes << Route{
		handler: handler
		names:   names
		attr:    attr
		fn_name: fn_name
	}
}

// finish prebuilds, for every node a route ends at, the complete 405
// response listing the methods it does serve (HEAD wherever GET is).
fn (mut t Table) finish() {
	for mut n in t.nodes {
		mut allow := []string{}
		for slot, name in method_names {
			if n.route[slot] >= 0 || (slot == m_head && n.route[m_get] >= 0) {
				allow << name
			}
		}
		if allow.len > 0 {
			n.allow = (method_not_allowed_head + allow.join(', ') + method_not_allowed_tail).bytes()
		}
	}
}

// lookup returns the node the request path ends at (-1: none), filling `p`
// with the param values on the way.
fn (t &Table) lookup(req HttpRequest, mut p Params) int {
	start := req.path.start
	base := unsafe { &u8(req.buffer.data) + start }
	q := C.memchr(base, `?`, usize(req.path.len))
	len := if q == unsafe { nil } { req.path.len } else { int(unsafe { &u8(q) - base }) }
	if len == 0 || unsafe { base[0] } != `/` {
		return -1
	}
	p.base = unsafe { &u8(req.buffer.data) }
	return t.find(0, base, start, len, 1, mut p)
}

// find matches the path bytes from `pos` (the start of a segment) below node
// `ni`: static children first, then :name, then *name, backtracking out of a
// dead end. `start` is the path's offset in the request buffer.
@[direct_array_access]
fn (t &Table) find(ni int, base &u8, start int, len int, pos int, mut p Params) int {
	node := unsafe { &t.nodes[ni] }
	if pos > len {
		return if node.allow.len > 0 { ni } else { -1 }
	}
	q := C.memchr(unsafe { base + pos }, `/`, usize(len - pos))
	end := if q == unsafe { nil } { len } else { int(unsafe { &u8(q) - base }) }
	seg_len := end - pos
	for c in node.statics {
		child := unsafe { &t.nodes[c] }
		if child.seg.len == seg_len && same(child.seg, unsafe { tos(base + pos, seg_len) }) {
			hit := t.find(c, base, start, len, end + 1, mut p)
			if hit >= 0 {
				return hit
			}
		}
	}
	if node.param >= 0 && seg_len > 0 && p.n < max_params {
		mark := p.n
		p.push(Slice{start + pos, seg_len})
		hit := t.find(node.param, base, start, len, end + 1, mut p)
		if hit >= 0 {
			return hit
		}
		p.n = mark
	}
	if node.wild >= 0 && p.n < max_params {
		p.push(Slice{start + pos, len - pos})
		return node.wild
	}
	return -1
}
