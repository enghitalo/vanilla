module main

// SOLUTION: pure handler / golden-table test — works today, no server.
// The handler is a total function of bytes->bytes, so every redirect case is a
// direct assertion. This is the cheapest, most deterministic layer.
// (.bytestr()/string helpers are fine HERE — tests are scaffolding, not the
// hot path.)
import core
import http1_1.request_parser
import http1_1.response

fn test_safe_next_rejects_offsite() {
	assert safe_next('/dashboard'.bytes()) == '/dashboard'.bytes() // same-origin relative: ok
	assert safe_next('//evil.com'.bytes()) == '/'.bytes() // protocol-relative: rejected
	assert safe_next('https://evil.com'.bytes()) == '/'.bytes() // absolute: rejected (open-redirect guard)
	assert safe_next([]u8{}) == '/'.bytes() // empty: rejected
}

// Browsers treat `\` as `/` in http(s) URLs (WHATWG URL): `/\evil.com` and
// `/\\evil.com` are `//evil.com` to them, protocol-relative, off-site (#293).
fn test_safe_next_rejects_backslash_second_byte() {
	for target in ['/\\evil.com', '/\\\\evil.com', '/\\/evil.com', '/\\'] {
		assert safe_next(target.bytes()) == '/'.bytes(), target
	}
}

// The URL parser removes TAB, LF and CR before parsing, so each of these is
// `//evil.com` (or `/\evil.com`) to a browser. CR and LF can't arrive raw
// through the server (test_raw_cr_or_lf_in_next_never_reaches_location), so
// they're checked on safe_next directly; a raw TAB does arrive
// (test_post_redirect_rejects_raw_tab_next).
fn test_safe_next_rejects_url_whitespace_second_byte() {
	for target in ['/\t/evil.com', '/\n/evil.com', '/\r/evil.com', '/\t\\evil.com', '/\t'] {
		assert safe_next(target.bytes()) == '/'.bytes(), target
	}
}

// Same-site paths stay accepted: `/` alone, a `\` past the second byte, and
// `%5C`, which browsers don't decode in a Location (it stays a path).
fn test_safe_next_keeps_same_site_paths() {
	for target in ['/', '/profile', '/a\\b', '/%5Cevil.com', '/%2F%2Fevil.com', '/a/b?c=d'] {
		assert safe_next(target.bytes()) == target.bytes(), target
	}
}

fn test_permanent_move_301() ! {
	out := serve('GET /old HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('301 Moved Permanently')
	assert out.contains('Location: /new')
}

// req.path INCLUDES the query string — routing must strip it, or '/old?utm=1'
// silently falls through to the 200 fallback.
fn test_permanent_move_301_with_query() ! {
	out := serve('GET /old?utm=1 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('301 Moved Permanently')
	assert out.contains('Location: /new')
}

fn test_api_redirect_preserves_method_308() ! {
	out :=
		serve('POST /api/v1/resource HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('308 Permanent Redirect') // method+body preserving
}

fn test_post_redirect_get_303() ! {
	out :=
		serve('POST /login?next=/profile HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('303 See Other')
	assert out.contains('Location: /profile\r\n')
}

// E2E open-redirect guard: a protocol-relative `next` must collapse to '/'.
fn test_post_redirect_rejects_offsite_next() ! {
	out :=
		serve('POST /login?next=//evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('303 See Other')
	assert out.contains('Location: /\r\n')
	assert !out.contains('evil.com')
}

// E2E: the issue's repro (#293). A `\` second byte must collapse to '/' too.
fn test_post_redirect_rejects_backslash_next() ! {
	for target in ['/\\evil.com', '/\\\\evil.com'] {
		out :=
			serve('POST /login?next=${target} HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
		assert out.contains('303 See Other'), target
		assert out.contains('Location: /\r\n'), target
		assert !out.contains('evil.com'), target
	}
}

// A raw TAB in the target reaches the handler: the framer only checks that
// every LF follows a CR, and the request-line parser ends the target at SP or
// CR. A browser would drop the TAB and read `//evil.com`.
fn test_post_redirect_rejects_raw_tab_next() ! {
	req := 'POST /login?next=/\t/evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()
	assert request_parser.frame_request_length(req)! == req.len // framed whole: handle sees it
	out := serve(req)!.bytestr()
	assert out.contains('Location: /\r\n')
	assert !out.contains('evil.com')
}

// A raw LF or CR never reaches the Location: the framer answers a bare LF with
// 400 before any handler runs, and a CR ends the request-target, so a CR not
// followed by LF leaves a malformed request line (the canned 400 + .close).
fn test_raw_cr_or_lf_in_next_never_reaches_location() {
	lf := 'POST /login?next=/\n/evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()
	if _ := request_parser.frame_request_length(lf) {
		assert false, 'a bare LF must not frame'
	}
	cr := 'POST /login?next=/\r/evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(cr, mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
}

// Same-site targets are echoed as sent: `/` alone, a `\` past the second byte,
// and `%5C`, which stays a path in a browser.
fn test_post_redirect_keeps_same_site_next() ! {
	for target in ['/', '/a\\b', '/%5Cevil.com'] {
		out :=
			serve('POST /login?next=${target} HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
		assert out.contains('Location: ${target}\r\n'), target
	}
}

fn test_post_redirect_empty_next_falls_to_root() ! {
	out :=
		serve('POST /login?next= HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('303 See Other')
	assert out.contains('Location: /\r\n')
}

fn test_post_redirect_defaults_to_dashboard() ! {
	out := serve('POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes())!.bytestr()
	assert out.contains('303 See Other')
	assert out.contains('Location: /dashboard\r\n')
}

fn test_get_login_is_plain_200() ! {
	out := serve('GET /login HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.starts_with('HTTP/1.1 200 OK')
	assert out.contains('Connection: keep-alive')
}

fn test_unknown_path_falls_back_200() ! {
	out := serve('GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())!.bytestr()
	assert out.starts_with('HTTP/1.1 200 OK')
}

fn test_malformed_requests_error() {
	mut caught := false
	if _ := serve('\r\n\r\n'.bytes()) {
		assert false, 'bare CRLFCRLF must not parse'
	} else {
		caught = true
	}
	assert caught
	caught = false
	if _ := serve('GET /old'.bytes()) { // truncated request-line
		assert false, 'truncated request-line must not parse'
	} else {
		caught = true
	}
	assert caught
}

// Every route, the dynamic 303 included, runs 20k times through one reused
// buffer, as a worker would serve them; the collector's lifetime allocation
// counter must not move. (Under `-gc none`, vanilla's epoll build, an
// allocation here would be a permanent leak.)
fn test_handler_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET /old HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET /old?utm=1 HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /login?next=/profile HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login?next=//evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login?next=/\\evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login?next=/\t/evil.com HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login?next=/a\\b HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login?next= HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'GET /login HTTP/1.1\r\nHost: x\r\n\r\n',
			'POST /api/v1/resource HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) ![]u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .close {
		return error('handler closed the connection')
	}
	return out
}
