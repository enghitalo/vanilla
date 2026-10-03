module main

// Router micro-benchmark — measurable WITHOUT wrk.
//
// The two routing styles vanilla ships, over the same 13 routes, in process:
// parse + route + a small response appended into one reused buffer, which is
// a worker's per-request work minus the socket.
//
//   veb_like  declarative: `@['GET /users/:id']` methods compiled into a trie
//             at startup (http1_1/veb_like)
//   router    explicit: the handler is the router, `match` over the path's
//             segments with the router module's zero-copy cursor; it reads
//             only the request line (veb_like parses the whole request: its
//             handlers receive it)
//
// Both must answer every request byte-identically (checked before timing),
// so the clock only sees how each one gets there. Handlers do minimal work —
// a reply naming the route and echoing its params — to keep the measurement
// on routing rather than on response building.
//
//   v -prod -gc none -o /tmp/router_bench bench/router/router_bench.v
//   bench/measure.sh /tmp/router_bench
import benchmark
import os
import strconv
import core
import http1_1.request_parser { HttpRequest }
import http1_1.router { Method, Path }
import http1_1.veb_like { Params }

fn C.memchr(s voidptr, c int, n usize) voidptr

// ── shared reply framing ─────────────────────────────────────────────────────

const ok_head = 'HTTP/1.1 200 OK\r\nContent-Length: '
const ok_tail = '\r\n\r\n'

// reply appends a 200 whose body is `name` then each value after a space.
@[direct_array_access]
fn reply(mut out []u8, name string, a string, b string, c string) {
	mut n := name.len
	for v in [a, b, c]! {
		if v.len > 0 {
			n += 1 + v.len
		}
	}
	core.append_str(mut out, ok_head)
	mut digits := [20]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	w := strconv.write_dec(n, mut view)
	unsafe { out.push_many(&digits[0], w) }
	core.append_str(mut out, ok_tail)
	core.append_str(mut out, name)
	for v in [a, b, c]! {
		if v.len > 0 {
			out << ` `
			core.append_str(mut out, v)
		}
	}
}

// ── declarative: veb_like ────────────────────────────────────────────────────

struct App {}

@['GET /users']
fn (app &App) list_users(_ HttpRequest, _ &Params, mut out []u8) core.Step {
	reply(mut out, 'list_users', '', '', '')
	return .done
}

@['POST /users']
fn (app &App) create_user(_ HttpRequest, _ &Params, mut out []u8) core.Step {
	reply(mut out, 'create_user', '', '', '')
	return .done
}

@['GET /users/:id']
fn (app &App) show_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'show_user', p.get('id'), '', '')
	return .done
}

@['PUT /users/:id']
fn (app &App) replace_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'replace_user', p.get('id'), '', '')
	return .done
}

@['PATCH /users/:id']
fn (app &App) update_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'update_user', p.get('id'), '', '')
	return .done
}

@['DELETE /users/:id']
fn (app &App) delete_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'delete_user', p.get('id'), '', '')
	return .done
}

@['GET /users/:id/profile']
fn (app &App) user_profile(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'user_profile', p.get('id'), '', '')
	return .done
}

@['GET /users/:user_id/posts/:post_id']
fn (app &App) user_post(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'user_post', p.get('user_id'), p.get('post_id'), '')
	return .done
}

@['GET /users/:user_id/posts/:post_id/comments/:comment_id']
fn (app &App) post_comment(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'post_comment', p.get('user_id'), p.get('post_id'), p.get('comment_id'))
	return .done
}

@['GET /tags/:a/:b/:c']
fn (app &App) tags(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'tags', p.get('a'), p.get('b'), p.get('c'))
	return .done
}

@['GET /search/:term']
fn (app &App) search(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'search', p.get('term'), '', '')
	return .done
}

@['GET /files/*path']
fn (app &App) serve_file(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'serve_file', p.get('path'), '', '')
	return .done
}

@['GET /proxy/*upstream']
fn (app &App) proxy(_ HttpRequest, p &Params, mut out []u8) core.Step {
	reply(mut out, 'proxy', p.get('upstream'), '', '')
	return .done
}

// ── explicit: the router module ──────────────────────────────────────────────

const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const users_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, POST\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const user_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, PUT, DELETE, PATCH\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const get_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// handle is the core.Handler: routing reads the request line, no header.
fn handle(req_buffer []u8, mut out []u8, _ int, _ voidptr, mut _event_loop core.EventLoop) core.Step {
	m := router.method(req_buffer)
	mut path := router.path(req_buffer)
	start := out.len
	step := route(m, mut path, mut out)
	if m == .head {
		drop_body(mut out, start)
	}
	return step
}

// drop_body keeps the head of the response appended from `start` (HEAD).
fn drop_body(mut out []u8, start int) {
	unsafe {
		mut i := start
		for i + 3 < out.len {
			q := C.memchr(&u8(out.data) + i, `\r`, usize(out.len - 3 - i))
			if q == nil {
				return
			}
			i = int(&u8(q) - &u8(out.data))
			if out[i + 1] == `\n` && out[i + 2] == `\r` && out[i + 3] == `\n` {
				out.len = i + 4
				return
			}
			i++
		}
	}
}

fn route(m Method, mut path Path, mut out []u8) core.Step {
	match path.next() {
		'users' {
			return users(m, mut path, mut out)
		}
		'tags' {
			a := path.next()
			b := path.next()
			c := path.next()
			if a == '' || b == '' || c == '' || !path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'tags', a, b, c)
		}
		'search' {
			term := path.next()
			if term == '' || !path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'search', term, '', '')
		}
		'files' {
			if path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'serve_file', path.rest(), '', '')
		}
		'proxy' {
			if path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'proxy', path.rest(), '', '')
		}
		else {
			return not_found(mut out)
		}
	}
}

fn users(m Method, mut path Path, mut out []u8) core.Step {
	if path.done() {
		match m {
			.get, .head { reply(mut out, 'list_users', '', '', '') }
			.post { reply(mut out, 'create_user', '', '', '') }
			else { core.append_str(mut out, users_405) }
		}
		return .done
	}
	id := path.next()
	if id == '' {
		return not_found(mut out)
	}
	if path.done() {
		match m {
			.get, .head { reply(mut out, 'show_user', id, '', '') }
			.put { reply(mut out, 'replace_user', id, '', '') }
			.patch { reply(mut out, 'update_user', id, '', '') }
			.delete { reply(mut out, 'delete_user', id, '', '') }
			else { core.append_str(mut out, user_405) }
		}
		return .done
	}
	match path.next() {
		'profile' {
			if !path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'user_profile', id, '', '')
		}
		'posts' {
			post_id := path.next()
			if post_id == '' {
				return not_found(mut out)
			}
			if path.done() {
				return get_leaf(m, mut out, 'user_post', id, post_id, '')
			}
			if path.next() != 'comments' {
				return not_found(mut out)
			}
			comment_id := path.next()
			if comment_id == '' || !path.done() {
				return not_found(mut out)
			}
			return get_leaf(m, mut out, 'post_comment', id, post_id, comment_id)
		}
		else {
			return not_found(mut out)
		}
	}
}

@[inline]
fn get_leaf(m Method, mut out []u8, name string, a string, b string, c string) core.Step {
	if m != .get && m != .head {
		core.append_str(mut out, get_405)
	} else {
		reply(mut out, name, a, b, c)
	}
	return .done
}

@[inline]
fn not_found(mut out []u8) core.Step {
	core.append_str(mut out, not_found_response)
	return .done
}

// ── the measurement ──────────────────────────────────────────────────────────

struct Case {
	name string
	req  []u8
}

fn mk(name string, line string) Case {
	return Case{name, (line + ' HTTP/1.1\r\nHost: localhost:3000\r\nUser-Agent: wrk\r\n\r\n').bytes()}
}

fn main() {
	env_iters := os.getenv('BENCH_ITERS').int()
	iterations := if env_iters > 0 { env_iters } else { 5_000_000 }
	cases := [
		mk('static     GET /users', 'GET /users'),
		mk('1 param    GET /users/42', 'GET /users/42'),
		mk('2 params   GET /users/7/posts/99', 'GET /users/7/posts/99'),
		mk('3 params   GET /users/7/posts/99/comments/5', 'GET /users/7/posts/99/comments/5'),
		mk('catch-all  GET /files/css/app.css', 'GET /files/css/app.css'),
		mk('HEAD       HEAD /users/42', 'HEAD /users/42'),
		mk('405        POST /users/42', 'POST /users/42'),
		mk('404        GET /nope/x', 'GET /nope/x'),
	]
	declarative := veb_like.new[App](&App{}) or { panic(err) }
	mut el := core.EventLoop{}
	mut a := []u8{cap: 4096}
	mut b := []u8{cap: 4096}

	// Byte-identical answers, or the comparison means nothing.
	for c in cases {
		unsafe {
			a.len = 0
			b.len = 0
		}
		declarative.handle(c.req, mut a, -1, unsafe { nil }, mut el)
		handle(c.req, mut b, -1, unsafe { nil }, mut el)
		if a != b {
			eprintln('MISMATCH on ${c.name}:\n  veb_like: ${a.bytestr()}\n  router:   ${b.bytestr()}')
			exit(1)
		}
		println('${c.name:-44s} -> ${a.bytestr().all_before('\r\n')}')
	}
	per_case := iterations / cases.len
	println('iterations      = ${per_case} per case\n')

	mut acc := u64(0)
	mut bm := benchmark.start()
	for c in cases {
		for _ in 0 .. per_case {
			unsafe {
				a.len = 0
			}
			declarative.handle(c.req, mut a, -1, unsafe { nil }, mut el)
			acc += u64(a.len)
		}
		bm.measure('veb_like ${c.name}')
	}
	for c in cases {
		for _ in 0 .. per_case {
			unsafe {
				b.len = 0
			}
			handle(c.req, mut b, -1, unsafe { nil }, mut el)
			acc += u64(b.len)
		}
		bm.measure('router   ${c.name}')
	}
	println('\nchecksum=${acc} (ignore; keeps the optimizer honest)')
}
