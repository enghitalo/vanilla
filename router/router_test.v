module router

fn get(target string) []u8 {
	return 'GET ${target} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
}

// segments pops every segment, then checks the cursor stays spent.
fn segments(req []u8) []string {
	mut p := path(req)
	mut segs := []string{}
	for !p.done() {
		segs << p.next()
	}
	assert p.next() == '' && p.rest() == '' && p.done()
	return segs
}

fn test_method() {
	names := ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH']
	for i, name in names {
		assert method('${name} / HTTP/1.1\r\n\r\n'.bytes()) == unsafe { Method(i) }
	}
	assert method('get / HTTP/1.1\r\n\r\n'.bytes()) == .unknown // case-sensitive
	assert method('BREW / HTTP/1.1\r\n\r\n'.bytes()) == .unknown
	assert method('GETS / HTTP/1.1\r\n\r\n'.bytes()) == .unknown
	assert method('PROPFIND / HTTP/1.1\r\n\r\n'.bytes()) == .unknown
	// no method token
	assert method('GET\r\n\r\n'.bytes()) == .unknown
	assert method(' GET / HTTP/1.1\r\n\r\n'.bytes()) == .unknown
	assert method('GE'.bytes()) == .unknown
	assert method([]u8{}) == .unknown
}

fn test_segments() {
	assert segments(get('/')) == ['']
	assert segments(get('/users')) == ['users']
	assert segments(get('/users/')) == ['users', '']
	assert segments(get('/users/42')) == ['users', '42']
	assert segments(get('/a//b')) == ['a', '', 'b']
	assert segments(get('/users/42?x=/y/z')) == ['users', '42'] // the query is not path
	assert segments(get('/?q=1')) == ['']
}

fn test_path_reads_the_request_line_only() {
	// no HTTP-version: the target ends at the line break, not in a header
	assert segments('GET /users/42\r\nHost: a b\r\n\r\n'.bytes()) == ['users', '42']
	// extra spaces after the method, as request_parser tolerates them
	assert segments('GET  /users HTTP/1.1\r\n\r\n'.bytes()) == ['users']
	// the cursor does not care about the method
	assert segments('BREW /pot HTTP/1.1\r\n\r\n'.bytes()) == ['pot']
}

fn test_done_tells_a_trailing_slash_apart() {
	mut p := path(get('/users'))
	assert p.next() == 'users' && p.done()
	mut q := path(get('/users/'))
	assert q.next() == 'users' && !q.done()
	assert q.next() == '' && q.done()
}

fn test_rest_is_the_catch_all() {
	mut p := path(get('/files/css/app.css?v=2'))
	assert p.rest() == 'files/css/app.css'
	assert p.next() == 'files'
	assert p.rest() == 'css/app.css'
	mut q := path(get('/files/'))
	q.next()
	assert q.rest() == '' && !q.done()
}

// A request with no path to route gets one segment that no route matches:
// not '' (the root's), so not even `/` answers it.
fn test_no_path_matches_no_route() {
	for raw in [
		'OPTIONS * HTTP/1.1\r\n\r\n', // asterisk-form
		'GET http://example.com/users HTTP/1.1\r\n\r\n', // absolute-form
		'GET users HTTP/1.1\r\n\r\n', // no leading /
		'GARBAGE\r\n\r\n', // no target
		'GET\r\n\r\n',
		'GET \r\n\r\n',
		'GET ',
		'',
	] {
		mut p := path(raw.bytes())
		assert !p.done(), raw
		seg := p.next()
		assert seg != '' && seg.contains(' '), raw
		assert p.done() && p.next() == '', raw
	}
}

fn test_segments_are_views_into_the_request() {
	req := get('/users/42')
	mut p := path(req)
	p.next()
	id := p.next()
	assert id == '42'
	assert voidptr(id.str) == unsafe { voidptr(&u8(req.data) + 'GET /users/'.len) }
}

fn test_routing_allocates_nothing() {
	$if gcboehm ? {
		req := get('/users/42/posts/99?x=1')
		star := 'OPTIONS * HTTP/1.1\r\n\r\n'.bytes()
		before := gc_heap_usage().total_bytes
		mut n := 0
		for _ in 0 .. 50_000 {
			m := method(req)
			mut p := path(req)
			for !p.done() {
				n += p.next().len
			}
			n += int(m) + p.rest().len
			mut q := path(star)
			n += q.next().len
		}
		assert n == 50_000 * 15
		assert gc_heap_usage().total_bytes - before < 1024
	}
}
