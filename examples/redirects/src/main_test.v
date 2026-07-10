module main

// SOLUTION: pure handler / golden-table test — works today, no server.
// The handler is a total function of bytes->bytes, so every redirect case is a
// direct assertion. This is the cheapest, most deterministic layer.
// (.bytestr()/string helpers are fine HERE — tests are scaffolding, not the
// hot path.)
import http_server.core

fn test_safe_next_rejects_offsite() {
	assert safe_next('/dashboard'.bytes()) == '/dashboard'.bytes() // same-origin relative: ok
	assert safe_next('//evil.com'.bytes()) == '/'.bytes() // protocol-relative: rejected
	assert safe_next('https://evil.com'.bytes()) == '/'.bytes() // absolute: rejected (open-redirect guard)
	assert safe_next([]u8{}) == '/'.bytes() // empty: rejected
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
