module main

// SOLUTION: pure handler / golden-table test — works today, no server.
// The handler is a total function of bytes->bytes, so every redirect case is a
// direct assertion. This is the cheapest, most deterministic layer.

fn test_safe_next_rejects_offsite() {
	assert safe_next('/dashboard') == '/dashboard' // same-origin relative: ok
	assert safe_next('//evil.com') == '/' // protocol-relative: rejected
	assert safe_next('https://evil.com') == '/' // absolute: rejected (open-redirect guard)
}

fn test_permanent_move_301() ! {
	out := handle('GET /old HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1)!.bytestr()
	assert out.contains('301 Moved Permanently')
	assert out.contains('Location: /new')
}

fn test_api_redirect_preserves_method_308() ! {
	out := handle('POST /api/v1/resource HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes(),
		-1)!.bytestr()
	assert out.contains('308 Permanent Redirect') // method+body preserving
}

fn test_post_redirect_get_303() ! {
	out := handle('POST /login?next=/profile HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes(),
		-1)!.bytestr()
	assert out.contains('303 See Other')
	assert out.contains('Location: /profile')
}
