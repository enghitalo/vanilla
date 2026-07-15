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
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - NEVER concatenate or interpolate — not even on the slow path. Static
//     responses are consts; the Set-Cookie response is two const halves around
//     the one dynamic byte range (the token), hex-encoded straight into `out`.
//   - VIEWS, NOT COPIES: the cookie header is scanned IN PLACE by offsets (no
//     split(), no map), and both tokens reach `hmac.equal` as zero-copy
//     `vbytes` views of the request buffer — it only reads, never retains.
//   - Routing and method gating compare bytes IN PLACE (`slice_eq`) — no
//     `.to_string()`, no `buf[a..b]` slice-marking.
//   The ONE per-request allocation left is `rand.bytes(32)` on GET /form: the
//   CSPRNG output must exist as fresh bytes — that is the security property,
//   don't contort it away.
//
// WORKS TODAY: crypto.rand + crypto.hmac.equal + header/cookie plumbing.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import crypto.rand
import crypto.hmac

// ---- static responses (consts — the handler appends, never builds) ----------
const resp_403 = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// GET /form response = const head + 64 hex token bytes + const tail. The token
// cookie is readable by same-origin JS (to copy into the request header), so
// NOT HttpOnly for the double-submit variant; the synchronizer variant keeps
// it server-side instead.
const form_head = 'HTTP/1.1 200 OK\r\nSet-Cookie: csrf='.bytes()
const form_tail = '; Secure; SameSite=Strict; Path=/\r\nContent-Type: text/html\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const hex_digits = '0123456789abcdef'

// write_hex appends the lowercase hex encoding of `data` straight into `out`
// via a nibble table — no intermediate string (replaces the string-returning
// `hex.encode` + `${}` pair).
@[direct_array_access]
fn write_hex(mut out []u8, data []u8) {
	for b in data {
		out << hex_digits[b >> 4]
		out << hex_digits[b & 0x0F]
	}
}

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// is_unsafe gates enforcement on state-changing methods, compared in place —
// methods are case-sensitive tokens (RFC 9110 §9.1), so exact bytes.
fn is_unsafe(buf []u8, method request_parser.Slice) bool {
	return slice_eq(buf, method, 'POST') || slice_eq(buf, method, 'PUT')
		|| slice_eq(buf, method, 'PATCH') || slice_eq(buf, method, 'DELETE')
}

// cookie_value returns the OFFSETS (start, len) of `name`'s value inside the
// Cookie header bytes, or (0, -1) when the cookie is absent. The header is
// scanned in place — no split(), no map[string]string, no copies. Matches are
// anchored at SEGMENT STARTS (the `; ` separators of RFC 6265 §4.2.1, plus the
// first segment), so `xcsrf=evil` can never match `csrf`. Cookie names are
// case-sensitive (RFC 6265 §4.1.1 token) — no `| 0x20` here; only header NAME
// lookup is case-insensitive, and get_header_value_slice already does that.
@[direct_array_access]
fn cookie_value(buf []u8, hdr request_parser.Slice, name string) (int, int) {
	end := hdr.start + hdr.len
	mut i := hdr.start
	for i < end {
		// At a segment start: exact name match followed by '='.
		mut j := 0
		for j < name.len && i + j < end && buf[i + j] == name[j] {
			j++
		}
		if j == name.len && i + j < end && buf[i + j] == `=` {
			vstart := i + j + 1
			mut vend := vstart
			for vend < end && buf[vend] != `;` {
				vend++
			}
			return vstart, vend - vstart
		}
		// Skip to the next segment: past the ';' and the following spaces.
		for i < end && buf[i] != `;` {
			i++
		}
		i++
		for i < end && buf[i] == ` ` {
			i++
		}
	}
	return 0, -1
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	// GET the form: issue a fresh CSRF token in a cookie. rand.bytes is the one
	// unavoidable per-request allocation — CSPRNG output must exist (see header).
	if slice_eq(req.buffer, req.path, '/form') && slice_eq(req.buffer, req.method, 'GET') {
		token := rand.bytes(32) or { // 32 bytes of CSPRNG entropy -> 64 hex chars
			out << response.tiny_bad_request_response
			return .close
		}
		out << form_head
		write_hex(mut out, token)
		out << form_tail
		return .done
	}

	// State-changing request: require the header token to match the cookie.
	// Guard ordering is load-bearing: missing cookie header, missing csrf pair,
	// empty value or missing X-CSRF-Token all 403 BEFORE any view is taken —
	// `vbytes` needs len > 0 to index the buffer.
	if is_unsafe(req.buffer, req.method) {
		chdr := req.get_header_value_slice('Cookie') or {
			out << resp_403
			return .done
		}
		cstart, clen := cookie_value(req.buffer, chdr, 'csrf')
		hdr := req.get_header_value_slice('X-CSRF-Token') or {
			out << resp_403
			return .done
		}
		if clen <= 0 || hdr.len <= 0 {
			out << resp_403
			return .done
		}
		// Zero-copy views of both tokens; hmac.equal only reads them, in
		// constant time, and both are consumed before the buffer is recycled.
		cookie_token := unsafe { (&req.buffer[cstart]).vbytes(clen) }
		header_token := unsafe { (&req.buffer[hdr.start]).vbytes(hdr.len) }
		if !hmac.equal(cookie_token, header_token) {
			out << resp_403
			return .done
		}
		out << resp_ok
		return .done
	}

	// Safe method (GET/HEAD/...): no token required — they must be side-effect
	// free anyway.
	out << resp_ok
	return .done
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
	})!
	println('CSRF demo on http://localhost:3000/  (GET /form sets token; unsafe methods require X-CSRF-Token)')
	server.run()
}
