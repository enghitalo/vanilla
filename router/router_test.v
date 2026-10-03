module router

import http1_1.request_parser { HttpRequest }

fn parse(raw string) HttpRequest {
	mut req := HttpRequest{
		buffer: raw.bytes()
	}
	parsed := request_parser.decode_into(mut req) // not inside the assert: -prod drops asserts
	assert parsed, 'test request must parse: ${raw}'
	return req
}

fn get(target string) HttpRequest {
	return parse('GET ${target} HTTP/1.1\r\nHost: x\r\n\r\n')
}

// segments pops every segment, then checks the cursor stays spent.
fn segments(target string) []string {
	mut p := path(get(target)) or { return ['<none>'] }
	mut segs := []string{}
	for !p.done() {
		segs << p.next()
	}
	assert p.next() == '' && p.rest() == '' && p.done()
	return segs
}

fn test_method() {
	for i, name in method_names[..int(Method.unknown)] {
		assert method(parse('${name} / HTTP/1.1\r\n\r\n')) == unsafe { Method(i) }
	}
	assert method(parse('get / HTTP/1.1\r\n\r\n')) == .unknown // case-sensitive
	assert method(parse('BREW / HTTP/1.1\r\n\r\n')) == .unknown
	assert method(parse('GETS / HTTP/1.1\r\n\r\n')) == .unknown
	assert method(parse('PROPFIND / HTTP/1.1\r\n\r\n')) == .unknown
}

fn test_segments() {
	assert segments('/') == ['']
	assert segments('/users') == ['users']
	assert segments('/users/') == ['users', '']
	assert segments('/users/42') == ['users', '42']
	assert segments('/a//b') == ['a', '', 'b']
	assert segments('/users/42?x=/y/z') == ['users', '42'] // the query is not path
	assert segments('/?q=1') == ['']
}

fn test_done_tells_a_trailing_slash_apart() {
	mut p := path(get('/users'))?
	assert p.next() == 'users' && p.done()
	mut q := path(get('/users/'))?
	assert q.next() == 'users' && !q.done()
	assert q.next() == '' && q.done()
}

fn test_rest_is_the_catch_all() {
	mut p := path(get('/files/css/app.css?v=2'))?
	assert p.rest() == 'files/css/app.css'
	assert p.next() == 'files'
	assert p.rest() == 'css/app.css'
	mut q := path(get('/files/'))?
	q.next()
	assert q.rest() == '' && !q.done()
}

fn test_only_origin_form_targets_have_a_path() {
	if _ := path(parse('OPTIONS * HTTP/1.1\r\n\r\n')) {
		assert false, 'asterisk-form must not route'
	}
	if _ := path(get('http://example.com/users')) {
		assert false, 'absolute-form must not route'
	}
	if _ := path(get('users')) {
		assert false, 'a target without a leading / must not route'
	}
}

fn test_segments_are_views_into_the_request() {
	req := get('/users/42')
	mut p := path(req)?
	p.next()
	id := p.next()
	assert id == '42'
	assert voidptr(id.str) == unsafe { voidptr(&u8(req.buffer.data) + req.path.start + 7) }
}

fn test_allow() {
	assert allow(.get, .head, .post).bytestr() == 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, POST\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
	// listed in RFC order whatever the argument order; .unknown is never listed
	assert allow(.patch, .unknown, .get).bytestr().contains('Allow: GET, PATCH\r\n')
}

fn test_drop_body() {
	mut out := 'previous'.bytes()
	start := out.len
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	drop_body(mut out, start)
	assert out.bytestr() == 'previousHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n'
	mut none_yet := 'no head here'.bytes()
	drop_body(mut none_yet, 0)
	assert none_yet.bytestr() == 'no head here'
}

fn test_cursor_allocates_nothing() {
	$if gcboehm ? {
		req := get('/users/42/posts/99?x=1')
		before := gc_heap_usage().total_bytes
		mut n := 0
		for _ in 0 .. 50_000 {
			m := method(req)
			mut p := path(req) or { panic('unreachable') }
			for !p.done() {
				n += p.next().len
			}
			n += int(m) + p.rest().len
		}
		assert n == 50_000 * 14
		assert gc_heap_usage().total_bytes - before < 1024
	}
}
