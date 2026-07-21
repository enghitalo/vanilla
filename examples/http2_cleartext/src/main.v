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
// Async routes work over BOTH protocols (the issue #136 follow-up: .suspend
// is legal for ConnHandlers): GET /slow parks on a timerfd. Served over h1
// the ENGINE parks the request. Served over http2 the bridge hands the app a
// CAPTURE event loop — the watch the app arms is recorded, re-armed on the
// real loop with a bridge continuation, and the app's resumed h1 response is
// re-framed for exactly the stream that parked. Other streams in the same
// burst are served while the parked one waits (v1 limit: one parked stream
// per connection — the engine's one-armed-watch contract; extra parkers are
// refused with RST_STREAM so the client retries).
//
// Try it (prior knowledge, no upgrade dance):
//   curl --http2-prior-knowledge http://localhost:3000/
//   curl --http2-prior-knowledge -d 'ping' http://localhost:3000/echo
//   curl --http2-prior-knowledge http://localhost:3000/slow
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

const slow_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10\r\nConnection: keep-alive\r\n\r\nslow done\n'.bytes()
const slow_unavailable_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const get_method = 'GET'.bytes()
const post_method = 'POST'.bytes()
const pri_method = 'PRI'.bytes()
const root_path = '/'.bytes()
const echo_path = '/echo'.bytes()
const slow_path = '/slow'.bytes()
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
		mut bridge := &BridgeState{
			conn: http2.new_server_conn()
		}
		if !core.queue_takeover(http2_takeover_conn, voidptr(bridge)) {
			res << cannot_takeover_response
			return .close
		}
		// The engine keeps `bridge` reachable for the GC through the
		// connection's state once the mode flips (the takeover_state slot).
		bridge.conn.write_server_preface(mut res)
		return .done
	}
	if !slice_eq(hr.buffer, hr.version, http11_version)
		&& !slice_eq(hr.buffer, hr.version, http10_version) {
		// Not an HTTP/1.x request — a garbled http2 connection preface. Speak
		// the language the peer attempted: a GOAWAY(PROTOCOL_ERROR) frame,
		// then drop the connection (RFC 9113 §3.5). h1 error bytes here would
		// only feed a confused http2 frame parser on the other side.
		http2.write_goaway(mut res, 0, .protocol_error)
		return .close
	}
	return app_route(hr, mut res, mut event_loop)
}

// app_route is the application: plain h1 routes, protocol-blind. Async routes
// park through event_loop — over h1 that is the engine's loop; over http2 it
// is the bridge's capture loop (see serve_http2_request).
fn app_route(hr request_parser.HttpRequest, mut res []u8, mut event_loop core.EventLoop) core.Step {
	if slice_eq(hr.buffer, hr.method, get_method) && slice_eq(hr.buffer, hr.path, root_path) {
		res << home_response
		return .done
	}
	if slice_eq(hr.buffer, hr.method, get_method) && slice_eq(hr.buffer, hr.path, slow_path) {
		return slow_route(mut res, mut event_loop)
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

// BridgeState is the per-connection takeover_state: the http2 protocol state
// plus the bridge's one-parked-stream bookkeeping (the engine's contract
// allows one armed watch per parked connection).
struct BridgeState {
mut:
	conn   &http2.ServerConn
	parked bool
	// Reused across bursts: consume() appends completed requests here, and we
	// clear it each call instead of allocating a fresh slice per readable
	// burst (which would leak under `-gc none`).
	reqs []http2.Http2Request
}

// WatchCapture records the ONE watch an app handler arms while served over
// http2. The bridge hands the app a capture EventLoop whose register writes
// here instead of arming anything — the real watch is armed by the bridge
// with its own continuation, so the app's resumed output is re-framed for
// the stream that parked instead of leaking raw h1 bytes onto the wire.
struct WatchCapture {
mut:
	fd       int = -1
	interest core.WatchInterest
	cont     core.WakeFn = unsafe { nil }
	udata    voidptr
}

// capture_register is the RegisterFn installed on the capture loop: it
// records the app's watch instead of arming it (el.reactor smuggles the
// WatchCapture — the capture loop never reaches a real reactor).
fn capture_register(mut el core.EventLoop, ext_fd int, interest core.WatchInterest, cont core.WakeFn, udata voidptr) {
	mut capture := unsafe { &WatchCapture(el.reactor) }
	capture.fd = ext_fd
	capture.interest = interest
	capture.cont = cont
	capture.udata = udata
	el.last_watched = ext_fd
}

// StreamWait carries a parked stream across the engine's park/resume hop:
// which stream to answer, the app's continuation, and the h1 response bytes
// accumulated so far (streamed across multi-hop suspends).
@[heap]
struct StreamWait {
mut:
	bridge    &BridgeState
	stream_id u32
	app_cont  core.WakeFn = unsafe { nil }
	app_udata voidptr
	h1_res    []u8
}

// http2_takeover_conn is the core.ConnHandler for a flipped connection: the
// ServerConn consumes frames (answering acks/pings/window updates itself)
// and surfaces complete requests, which are served through `handle`. A
// stream that parks (async route) suspends the connection; the bridge's
// continuation resumes it when the watched fd fires.
fn http2_takeover_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut bridge := unsafe { &BridgeState(takeover_state) }
	mut conn := bridge.conn
	bridge.reqs.clear()
	consumed, closing := conn.consume(buf, mut out, mut bridge.reqs)
	mut must_close := closing
	// Index, not `for x in bridge.reqs`: serve_http2_request takes `mut bridge`,
	// and V forbids passing a container as mut while ranging over it. consume
	// already finished appending, so the length is fixed here.
	for i in 0 .. bridge.reqs.len {
		req := bridge.reqs[i]
		if !serve_http2_request(mut bridge, req, mut out, client_fd, worker_state, mut event_loop) {
			must_close = true
		}
	}
	if must_close {
		// The engine tears down any watch armed by a parked stream in this
		// same call (a .close with a live watch never leaks it).
		return consumed, core.Step.close
	}
	if bridge.parked {
		return consumed, core.Step.suspend
	}
	return consumed, core.Step.done
}

// serve_http2_request bridges one http2 request through the h1 handler:
// pseudo-headers become the request line, regular fields carry over
// (connection-specific ones dropped, RFC 9113 §8.2.2), the response head is
// parsed back with the client codec and re-framed as HEADERS + DATA. An app
// handler that suspends parks the stream via bridge_park.
// Returns false when the connection must close afterwards.
fn serve_http2_request(mut bridge BridgeState, req http2.Http2Request, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) bool {
	mut conn := bridge.conn
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
	// The same pure handler serves the translated request — against a CAPTURE
	// event loop, so an async route's watch is recorded (not armed) and the
	// bridge can re-frame its resumed output for this stream.
	mut h1_res := []u8{cap: 512}
	mut capture := WatchCapture{}
	mut probe_loop := core.EventLoop{
		client_fd: client_fd
		reactor:   unsafe { voidptr(&capture) }
		register:  capture_register
	}
	step := handle(h1_req, mut h1_res, client_fd, worker_state, mut probe_loop)
	if step == .suspend {
		return bridge_park(mut bridge, req.stream_id, capture, h1_res, mut out, mut event_loop)
	}
	if !frame_h1_response(mut conn, req.stream_id, h1_res, mut out) {
		return false
	}
	return step == .done
}

// bridge_park parks one stream: the app's captured watch is re-armed on the
// REAL event loop with bridge_wake as its continuation, and the connection
// suspends (http2_takeover_conn returns .suspend). One parked stream per
// connection — the engine's close-path teardown tracks exactly one watch —
// so a second parker is refused (RST_STREAM) and the client retries.
// Returns false when the connection must close.
fn bridge_park(mut bridge BridgeState, stream_id u32, capture WatchCapture, h1_partial []u8, mut out []u8, mut event_loop core.EventLoop) bool {
	if capture.fd < 0 || capture.cont == unsafe { nil } {
		// Suspended without arming a watch — nothing would resume the stream.
		http2.write_goaway(mut out, stream_id, .internal_error)
		return false
	}
	if bridge.parked {
		// Release the app's request-owned fd (e.g. a timerfd). This branch is
		// unreachable where async routes degrade to sync answers, but it must
		// still compile everywhere.
		$if !windows {
			C.close(capture.fd)
		}
		mut conn := bridge.conn
		conn.abort_stream(mut out, stream_id, .refused_stream)
		return true
	}
	wait := &StreamWait{
		bridge:    unsafe { &BridgeState(voidptr(&bridge)) }
		stream_id: stream_id
		app_cont:  capture.cont
		app_udata: capture.udata
		h1_res:    h1_partial
	}
	bridge.parked = true
	event_loop.watch_fd(capture.fd, capture.interest, bridge_wake, voidptr(wait))
	return true
}

// bridge_wake is the continuation the bridge arms for a parked stream: it
// runs the app's continuation against the stream's PRIVATE h1 buffer (again
// under a capture loop, so multi-hop suspends re-park cleanly), then
// re-frames the finished h1 response for exactly that stream.
fn bridge_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut wait := unsafe { &StreamWait(watch_payload) }
	mut bridge := wait.bridge
	mut capture := WatchCapture{}
	mut probe_loop := core.EventLoop{
		client_fd: event_loop.client_fd
		reactor:   unsafe { voidptr(&capture) }
		register:  capture_register
	}
	step := wait.app_cont(mut wait.h1_res, ready_fd, ready_fd_error, wait.app_udata, worker_state, mut
		probe_loop)
	if step == .suspend {
		if capture.fd < 0 || capture.cont == unsafe { nil } {
			bridge.parked = false
			http2.write_goaway(mut out, wait.stream_id, .internal_error)
			return .close
		}
		// Multi-hop park: re-arm with this same StreamWait, stay suspended.
		wait.app_cont = capture.cont
		wait.app_udata = capture.udata
		event_loop.watch_fd(capture.fd, capture.interest, bridge_wake, voidptr(wait))
		return .suspend
	}
	bridge.parked = false
	mut conn := bridge.conn
	if !frame_h1_response(mut conn, wait.stream_id, wait.h1_res, mut out) {
		return .close
	}
	if step == .close {
		// The app asked to drop the connection after its response — say so in
		// the protocol the peer speaks.
		http2.write_goaway(mut out, 0, .no_error)
		return .close
	}
	return .done
}

// frame_h1_response re-frames a complete h1 response as HEADERS + DATA for
// `stream_id`. Returns false (after a GOAWAY) when the response is unusable —
// connection-fatal, since the stream would otherwise hang forever.
fn frame_h1_response(mut conn http2.ServerConn, stream_id u32, h1_res []u8, mut out []u8) bool {
	total := client.frame_response(h1_res)
	status := client.status_code(h1_res)
	if total <= 0 || status < 0 {
		http2.write_goaway(mut out, stream_id, .internal_error)
		return false
	}
	head := client.head_len(h1_res)
	bstart, blen := client.body_bounds(h1_res, total)
	mut block := []u8{cap: 64}
	http2.encode_status(mut block, status)
	append_response_fields(mut block, h1_res, head)
	conn.write_response_headers(mut out, stream_id, block, blen == 0)
	if blen > 0 {
		body := unsafe { (&h1_res[bstart]).vbytes(blen) }
		conn.write_response_data(mut out, stream_id, body)
	}
	return true
}

// slow_route parks the request on a one-shot 30 ms timerfd — the async_timer
// idiom. Served over h1 the ENGINE parks the request; served over http2 the
// BRIDGE captures the watch and parks the stream. Same handler, both
// protocols. On platforms without timerfd the route degrades to a sync 501.
fn slow_route(mut res []u8, mut event_loop core.EventLoop) core.Step {
	$if linux {
		return slow_route_linux(mut res, mut event_loop)
	}
	res << slow_unavailable_response
	return .done
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
