module main

import core

// Handler-level conformance tests: feed raw request bytes to handle_request and
// assert the status line, mirroring the checks an external probe (h1spec) makes.
// This runs the SAME logic the probe exercises, but without a socket — so it is
// deterministic and immune to the backend half-close behavior (see README).

// serve drives the handler with the current contract and returns the bytes it
// appended. client_fd = -1, no worker state, a scratch EventLoop — this server
// is stateless and synchronous, so none of them are consulted.
fn serve(req string) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle_request(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	return out
}

fn status_of(req string) int {
	out := serve(req)
	// Parse "HTTP/1.1 NNN ..." → NNN.
	if out.len < 12 {
		return 0
	}
	s := out.bytestr()
	parts := s.split(' ')
	if parts.len < 2 {
		return 0
	}
	return parts[1].int()
}

fn test_simple_get_accepted() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n') == 200
}

fn test_post_with_content_length() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello') == 200
}

fn test_unknown_path_404() {
	assert status_of('GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n') == 404
}

fn test_invalid_version_rejected() {
	s := status_of('GET / HTTP/2.0\r\nHost: localhost\r\n\r\n')
	assert s == 400 || s == 505
}

fn test_missing_host_rejected() {
	assert status_of('GET / HTTP/1.1\r\n\r\n') == 400
}

fn test_duplicate_host_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\nHost: example.com\r\n\r\n') == 400
}

fn test_invalid_host_value_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: bad host\r\n\r\n') == 400
}

fn test_invalid_header_name_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\nBad Header: value\r\n\r\n') == 400
}

fn test_obsolete_folding_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: localhost\r\n  continued\r\n\r\n') == 400
}

fn test_space_before_colon_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost : localhost\r\n\r\n') == 400
}

fn test_null_in_header_rejected() {
	assert status_of('GET / HTTP/1.1\r\nHost: local\x00host\r\n\r\n') == 400
}

fn test_duplicate_content_length_rejected() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nhello!!') == 400
}

fn test_cl_te_conflict_rejected() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 400
}

fn test_unknown_transfer_coding_rejected() {
	s := status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: nonsense\r\n\r\nhello')
	assert s == 400 || s == 501
}

fn test_chunked_not_final_rejected() {
	// "chunked, gzip" — chunked is not the final coding.
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 400
}

fn test_valid_chunked_accepted() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 200
}

fn test_valid_chunked_with_trailer_accepted() {
	// A trailer section (RFC 9112 §7.1.2) is framed by the core (#185) and sits in
	// the body, after the last chunk: it is not a header field to validate here.
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n') == 200
}

fn test_chunked_http10_rejected() {
	// Transfer-Encoding is HTTP/1.1+; a 1.0 request carrying it is 400 (RFC 9112 §6.1).
	assert status_of('POST / HTTP/1.0\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 400
}

fn test_head_has_no_body() {
	out := serve('HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n')
	s := out.bytestr()
	idx := s.index('\r\n\r\n') or {
		assert false, 'no header terminator in HEAD response'
		return
	}
	body := s[idx + 4..]
	assert body.len == 0, 'HEAD response must have empty body, got ${body.len} bytes'
}

fn test_unsupported_method_405() {
	assert status_of('DELETE / HTTP/1.1\r\nHost: localhost\r\n\r\n') == 405
}

fn test_error_response_is_self_delimiting() {
	// Every 400 must carry Content-Length (or chunked / Connection: close).
	s := serve('get / HTTP/1.1\r\nHost: localhost\r\n\r\n').bytestr().to_lower()
	assert s.contains('content-length:') || s.contains('transfer-encoding: chunked')
		|| s.contains('connection: close')
}

fn test_connection_close_honored() {
	out := serve('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
	assert out.bytestr().to_lower().contains('connection: close')
}

fn step_of(req string) core.Step {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	return handle_request(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
}

// Connection is a comma-separated token list (RFC 9110 §5.6.1, §7.6.1): empty
// elements and the whitespace around each are skipped, and tokens compare
// case-insensitively, letter by letter.
fn test_connection_tokens() {
	for c in ['close', 'Close', 'CLOSE', 'keep-alive, close', ',,close,,', ' , close ', '\tclose\t',
		'upgrade,close'] {
		assert step_of('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: ${c}\r\n\r\n') == .close, c
	}
	for c in ['keep-alive', 'closed', 'xclose', 'clos', '"close"', 'clo se', '', ','] {
		assert step_of('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: ${c}\r\n\r\n') == .done, c
	}
	// HTTP/1.0 closes unless the list has keep-alive. U+212A KELVIN SIGN
	// lowercases to `k` in Unicode, but a token is ASCII: it is not keep-alive.
	for c in ['keep-alive', 'KEEP-ALIVE', 'foo, Keep-Alive', ' keep-alive ,'] {
		assert step_of('GET / HTTP/1.0\r\nHost: localhost\r\nConnection: ${c}\r\n\r\n') == .done, c
	}
	for c in ['foo', 'keep-alive, close', 'keep_alive', '\xe2\x84\xaaeep-alive'] {
		assert step_of('GET / HTTP/1.0\r\nHost: localhost\r\nConnection: ${c}\r\n\r\n') == .close, c
	}
	assert step_of('GET / HTTP/1.0\r\nHost: localhost\r\n\r\n') == .close
}

// Every coding of a Transfer-Encoding list is judged: the final one must be
// chunked, an earlier chunked is 400 and an unknown coding 501; the final
// coding's verdict comes first.
fn test_transfer_coding_lists() {
	for te, want in {
		'chunked':                          200
		'CHUNKED':                          200
		'gzip, chunked':                    200
		'x-gzip,chunked':                   200
		' , gzip , , chunked , ':           200
		'compress, deflate, gzip, chunked': 200
		'foo, chunked':                     501
		'gzip, foo, bar, chunked':          501
		'foo, chunked, chunked':            501
		'chunked, chunked':                 400
		'chunked, foo, chunked':            400
		'gzip chunked':                     501
		'chunked, gzip':                    400
		'foo, gzip':                        400
		'chunked, foo':                     501
		',':                                400
	} {
		got := status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: ${te}\r\n\r\n5\r\nhello\r\n0\r\n\r\n')
		assert got == want, te
	}
}

// Letters fold, nothing else does: `| 0x20` would equate CR with `-` (x-gzip)
// and SI with `/` (HTTP/).
fn test_only_letters_fold() {
	assert status_of('POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: x\rgzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n') == 501
	assert status_of('GET / HTTP\x0f1.1\r\nHost: localhost\r\n\r\n') == 400
	assert status_of('GET / http/1.1\r\nHost: localhost\r\n\r\n') == 505
}

// Serving allocates nothing: every outcome the handler decides itself — the
// routes, Connection lists, Transfer-Encoding lists, 400 / 501 / 505 — runs
// 20k times through one reused buffer, and the collector's lifetime
// allocation counter must not move. (Under -gc none, vanilla's production
// build, an allocation per request is a leak.) Requests the stdlib parser
// rejects are left out: its errors are boxed.
fn test_handle_request_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n',
			'GET /?a=1 HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade, close\r\n\r\n',
			'GET / HTTP/1.0\r\nHost: localhost\r\nConnection: foo, Keep-Alive\r\n\r\n',
			'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'HEAD / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
			'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello',
			'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n',
			'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: foo, chunked\r\n\r\n0\r\n\r\n',
			'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n',
			'DELETE / HTTP/1.1\r\nHost: localhost\r\n\r\n',
			'GET / HTTP/2.0\r\nHost: localhost\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: localhost\r\nBad Header: value\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle_request(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}
