module main

// CSRF protection — reference design.
//
// Cross-Site Request Forgery: a malicious site makes the victim's BROWSER send
// a state-changing request to your site, riding on the victim's cookies. The
// defense is to require a secret the attacker's site cannot read or guess.
//
// TWO STANDARD PATTERNS (both shown):
//   1. SameSite cookies — the first line of defense (see cookies_sessions).
//      `SameSite=Lax/Strict` stops the cookie from being sent on cross-site
//      POSTs at all. Necessary but pair it with a token for defense in depth.
//   2. Double-submit / synchronizer token — issue a random CSRF token, deliver
//      it in BOTH a cookie and the page; state-changing requests must echo it
//      in a header/form field. The attacker's site can't read the cookie (same-
//      origin policy), so it can't forge the matching header.
//
// RULES:
//   - Only enforce on UNSAFE methods (POST/PUT/PATCH/DELETE). GET/HEAD must be
//     side-effect free, so they need no token.
//   - Compare the token in CONSTANT TIME (timing leaks).
//   - Token must come from a CSPRNG.
//
// WORKS TODAY: crypto.rand + crypto.hmac.equal + header/cookie plumbing.

import http_server
import http_server.http1_1.request_parser
import crypto.rand
import crypto.hmac
import encoding.hex

fn new_token() string {
	return hex.encode(rand.bytes(32) or { panic('csprng unavailable') })
}

fn parse_cookies(header string) map[string]string {
	mut out := map[string]string{}
	for pair in header.split('; ') {
		if eq := pair.index('=') {
			out[pair[..eq]] = pair[eq + 1..]
		}
	}
	return out
}

fn is_unsafe(method string) bool {
	return method in ['POST', 'PUT', 'PATCH', 'DELETE']
}

fn handle(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	path := req.path.to_string(req.buffer)

	cookies := if c := req.get_header_value_slice('Cookie') {
		parse_cookies(c.to_string(req.buffer))
	} else {
		map[string]string{}
	}

	// GET the form: issue a fresh CSRF token in a cookie (readable by same-origin
	// JS to put into the request header — so NOT HttpOnly for the double-submit
	// variant; the synchronizer variant keeps it server-side instead).
	if path == '/form' && method == 'GET' {
		token := new_token()
		return ('HTTP/1.1 200 OK\r\n' +
			'Set-Cookie: csrf=${token}; Secure; SameSite=Strict; Path=/\r\n' +
			'Content-Type: text/html\r\nContent-Length: 0\r\n\r\n').bytes()
	}

	// State-changing request: require the header token to match the cookie.
	if is_unsafe(method) {
		cookie_token := cookies['csrf'] or { '' }
		header_token := if h := req.get_header_value_slice('X-CSRF-Token') {
			h.to_string(req.buffer)
		} else {
			''
		}
		if cookie_token == '' || !hmac.equal(cookie_token.bytes(), header_token.bytes()) {
			return 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
		return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
	}

	return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: handle
	})!
	println('CSRF demo on http://localhost:3000/  (GET /form sets token; unsafe methods require X-CSRF-Token)')
	server.run()
}
