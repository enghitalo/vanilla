module main

// HTTP/2 over cleartext TCP with prior knowledge (RFC 9113 §3.4) — the second
// consumer of the conn-mode seam (issue #136), and the reason the seam
// reserved an http2 arm: one engine, one application handler, now three wire
// protocols (HTTP/1.1, WebSocket, HTTP/2) on the same port.
//
// How the connection flips: an http2 client's first bytes are the connection
// preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`. Its first 18 bytes parse as a
// complete HTTP/1.1 request (method PRI, target *, empty header section), so
// it reaches `handle` like any request. The handler queues the takeover,
// appends the server preface (a SETTINGS frame) as its switching response,
// and returns `.done` — the engine flushes the SETTINGS and routes every
// later burst (starting with the `SM\r\n\r\n` tail already in the read
// buffer) to `http2_takeover_conn`.
//
// How requests are served: the http2.ServerConn state machine surfaces each
// COMPLETE request; this file translates it to HTTP/1.1 bytes, calls the SAME
// `handle` the h1 path uses (a core.Handler is bytes-in/bytes-out — nothing
// http1-specific about the contract), then re-frames the h1 response as
// HEADERS + DATA with the http1_1.client response codec doing the parsing.
// The translation allocates; that is the http2 bridge's cost, paid off the
// h1 hot path (which is untouched).
//
// Try it (prior knowledge, no upgrade dance):
//   curl --http2-prior-knowledge http://localhost:3000/
//   curl --http2-prior-knowledge -d 'ping' http://localhost:3000/echo
import core
import http1_1.client
import http1_1.request_parser
import http1_1.response
import http2
import server
import strconv

const home_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 23\r\nConnection: keep-alive\r\n\r\nhello over one handler\n'.bytes()
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
// 501: this worker/backend cannot take connections over (queue_takeover
// returned false) — answering the preface with h1 bytes the client can see
// beats leaving it to time out on a half-spoken protocol.
const cannot_takeover_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const echo_head_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: '.bytes()
const echo_head_suffix = '\r\nConnection: keep-alive\r\n\r\n'.bytes()

const get_method = 'GET'.bytes()
const post_method = 'POST'.bytes()
const pri_method = 'PRI'.bytes()
const root_path = '/'.bytes()
const echo_path = '/echo'.bytes()
const star_target = '*'.bytes()

const h1_line_suffix = ' HTTP/1.1\r\n'.bytes()
const http11_version = 'HTTP/1.1'.bytes()
const http10_version = 'HTTP/1.0'.bytes()
const h1_host_prefix = 'host: '.bytes()
const h1_content_length_prefix = 'content-length: '.bytes()
const h1_header_sep = ': '.bytes()
const crlf = '\r\n'.bytes()

// slice_eq compares a request Slice against a small const byte pattern.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, want []u8) bool {
	if s.len != want.len {
		return false
	}
	for i in 0 .. want.len {
		if buf[s.start + i] != want[i] {
			return false
		}
	}
	return true
}

// write_int appends n's decimal digits — itoa into a stack scratch, then
// push_many (docs/BEST_PRACTICES.md: no `.str()` on the serving path).
fn write_int(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// handle serves BOTH protocols: h1 requests directly, and the http2
// connection preface by flipping the connection's mode. The http2 bridge
// below calls this same function for every http2 request.
fn handle(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if slice_eq(hr.buffer, hr.method, pri_method) && slice_eq(hr.buffer, hr.path, star_target) {
		// The http2 client connection preface. Takeover FIRST: only answer
		// with the server preface if this worker can actually flip the mode.
		mut conn := http2.new_server_conn()
		if !core.queue_takeover(http2_takeover_conn, voidptr(conn)) {
			res << cannot_takeover_response
			return .close
		}
		// The engine keeps `conn` reachable for the GC through the
		// connection's state once the mode flips (the takeover_state slot).
		conn.write_server_preface(mut res)
		return .done
	}
	if !slice_eq(hr.buffer, hr.version, http11_version)
		&& !slice_eq(hr.buffer, hr.version, http10_version) {
		// Not an HTTP/1.x request — e.g. a garbled http2 connection preface.
		// Answer 400 and drop the connection (RFC 9113 §3.5 requires the TCP
		// connection terminated on an invalid preface; a keep-alive 404 would
		// leave the peer hanging).
		res << response.tiny_bad_request_response
		return .close
	}
	return app_route(hr, mut res)
}

// app_route is the application: plain h1 routes, protocol-blind.
fn app_route(hr request_parser.HttpRequest, mut res []u8) core.Step {
	if slice_eq(hr.buffer, hr.method, get_method) && slice_eq(hr.buffer, hr.path, root_path) {
		res << home_response
		return .done
	}
	if slice_eq(hr.buffer, hr.method, post_method) && slice_eq(hr.buffer, hr.path, echo_path) {
		res << echo_head_prefix
		write_int(mut res, i64(hr.body.len))
		res << echo_head_suffix
		if hr.body.len > 0 {
			unsafe { res.push_many(&hr.buffer[hr.body.start], hr.body.len) }
		}
		return .done
	}
	res << not_found_response
	return .done
}

// http2_takeover_conn is the core.ConnHandler for a flipped connection: the
// ServerConn consumes frames (answering acks/pings/window updates itself)
// and surfaces complete requests, which are served through `handle`.
fn http2_takeover_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut conn := unsafe { &http2.ServerConn(takeover_state) }
	mut reqs := []http2.Http2Request{}
	consumed, closing := conn.consume(buf, mut out, mut reqs)
	mut must_close := closing
	for req in reqs {
		if !serve_http2_request(mut conn, req, mut out, client_fd, worker_state, mut event_loop) {
			must_close = true
		}
	}
	if must_close {
		return consumed, core.Step.close
	}
	return consumed, core.Step.done
}

// serve_http2_request bridges one http2 request through the h1 handler:
// pseudo-headers become the request line, regular fields carry over
// (connection-specific ones dropped, RFC 9113 §8.2.2), the response head is
// parsed back with the client codec and re-framed as HEADERS + DATA.
// Returns false when the connection must close afterwards.
fn serve_http2_request(mut conn http2.ServerConn, req http2.Http2Request, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) bool {
	mut method := ''
	mut path := ''
	mut authority := ''
	for f in req.headers {
		match f.name {
			':method' { method = f.value }
			':path' { path = f.value }
			':authority' { authority = f.value }
			else {}
		}
	}
	if method == '' || path == '' {
		// Malformed request (§8.3.1) — answer 400 on the stream, keep the
		// connection.
		mut block := []u8{cap: 4}
		http2.encode_status(mut block, 400)
		conn.write_response_headers(mut out, req.stream_id, block, true)
		return true
	}
	if authority == '' {
		authority = 'localhost'
	}
	// Translate to h1 request bytes.
	mut h1_req := []u8{cap: 256 + req.body.len}
	unsafe { h1_req.push_many(method.str, method.len) }
	h1_req << u8(` `)
	unsafe { h1_req.push_many(path.str, path.len) }
	h1_req << h1_line_suffix
	h1_req << h1_host_prefix
	unsafe { h1_req.push_many(authority.str, authority.len) }
	h1_req << crlf
	for f in req.headers {
		if f.name.len == 0 || f.name[0] == `:` {
			continue
		}
		// host rides :authority; connection-specific fields do not exist in
		// http2 and must not be resurrected; te is only ever 'trailers'.
		if f.name == 'host' || f.name == 'te' || is_connection_specific(f.name) {
			continue
		}
		unsafe { h1_req.push_many(f.name.str, f.name.len) }
		h1_req << h1_header_sep
		unsafe { h1_req.push_many(f.value.str, f.value.len) }
		h1_req << crlf
	}
	if req.body.len > 0 {
		h1_req << h1_content_length_prefix
		write_int(mut h1_req, i64(req.body.len))
		h1_req << crlf
	}
	h1_req << crlf
	if req.body.len > 0 {
		unsafe { h1_req.push_many(&req.body[0], req.body.len) }
	}
	// The same pure handler serves the translated request.
	mut h1_res := []u8{cap: 512}
	step := handle(h1_req, mut h1_res, client_fd, worker_state, mut event_loop)
	if step == .suspend {
		// .suspend is unsupported behind the takeover seam (issue #136 v1).
		http2.write_goaway(mut out, req.stream_id, .internal_error)
		return false
	}
	total := client.frame_response(h1_res)
	status := client.status_code(h1_res)
	if total <= 0 || status < 0 {
		http2.write_goaway(mut out, req.stream_id, .internal_error)
		return false
	}
	head := client.head_len(h1_res)
	bstart, blen := client.body_bounds(h1_res, total)
	mut block := []u8{cap: 64}
	http2.encode_status(mut block, status)
	append_response_fields(mut block, h1_res, head)
	conn.write_response_headers(mut out, req.stream_id, block, blen == 0)
	if blen > 0 {
		body := unsafe { (&h1_res[bstart]).vbytes(blen) }
		conn.write_response_data(mut out, req.stream_id, body)
	}
	return step == .done
}

// append_response_fields HPACK-encodes the h1 response head's fields (after
// the status line, names lowercased, connection-specific fields dropped).
fn append_response_fields(mut block []u8, res []u8, head int) {
	mut pos := 0
	for pos + 1 < head && !(res[pos] == `\r` && res[pos + 1] == `\n`) {
		pos++
	}
	pos += 2
	for pos + 1 < head {
		if res[pos] == `\r` && res[pos + 1] == `\n` {
			break
		}
		mut eol := pos
		for eol + 1 < head && !(res[eol] == `\r` && res[eol + 1] == `\n`) {
			eol++
		}
		mut colon := pos
		for colon < eol && res[colon] != `:` {
			colon++
		}
		if colon > pos && colon < eol {
			mut lower := []u8{cap: colon - pos}
			for i in pos .. colon {
				mut ch := res[i]
				if ch >= `A` && ch <= `Z` {
					ch += 32
				}
				lower << ch
			}
			name := lower.bytestr()
			if !is_connection_specific(name) {
				mut vstart := colon + 1
				for vstart < eol && res[vstart] == u8(` `) {
					vstart++
				}
				value := if vstart < eol {
					unsafe { tos(&res[vstart], eol - vstart) }
				} else {
					''
				}
				http2.encode_literal(mut block, name, value)
			}
		}
		pos = eol + 2
	}
}

// is_connection_specific reports h1 connection-level fields that MUST NOT
// cross into http2 framing (RFC 9113 §8.2.2).
fn is_connection_specific(name string) bool {
	return match name {
		'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade' { true }
		else { false }
	}
}

fn main() {
	// The takeover seam is epoll-first (issue #136): elsewhere queue_takeover
	// reports false and the preface answers 501 instead of a dead SETTINGS.
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
	})!
	println('HTTP/2 (cleartext, prior knowledge) + HTTP/1.1 on http://localhost:3000')
	println('  curl --http2-prior-knowledge http://localhost:3000/')
	srv.run()
}
