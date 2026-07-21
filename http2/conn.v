module http2

// Server-side HTTP/2 connection state machine (RFC 9113), designed to sit
// behind the engine's connection-takeover seam (issue #136): `consume` has
// exactly a ConnHandler's shape — bytes in, response bytes appended to the
// caller's `out`, consumed count back — without importing core (the protocol
// module stays engine-free; the ConnHandler wrapper composing this with the
// application handler lives with its consumer, see examples/http2_cleartext).
//
// Scope (deliberate, rule 3 — don't complicate it):
//   - cleartext prior-knowledge only: the client preface's `PRI * HTTP/2.0`
//     line reaches the request handler as an ordinary parsed request, the
//     handler takes the connection over, and this machine picks up at the
//     `SM\r\n\r\n` tail left in the read buffer.
//   - requests surface only when COMPLETE (END_STREAM seen): handlers are
//     pure functions of a whole request, same as the h1 path.
//   - flow control is honored on the send side (DATA parks in the stream's
//     pending buffer until WINDOW_UPDATE) and replenished eagerly on the
//     receive side (bodies are consumed on arrival, so both windows snap
//     back to full after every DATA frame).
//   - trailers are decoded (HPACK state is connection-global and MUST see
//     every block) but not surfaced; PRIORITY is parsed and ignored.
//   - errors follow RFC 9113 §5.4: connection-fatal ones append a GOAWAY and
//     report close; refused/overflowing streams get RST_STREAM.

// Http2Request is one complete request: decoded header list (pseudo-headers
// like :method/:path included, in wire order) plus the reassembled body.
pub struct Http2Request {
pub:
	stream_id u32
	headers   []HeaderField
	body      []u8
}

// max_concurrent_streams is advertised in the server preface SETTINGS and
// enforced: streams opened beyond it are refused (RST_STREAM REFUSED_STREAM).
pub const max_concurrent_streams = 128

// A header block (HEADERS + CONTINUATIONs, before decompression) larger than
// this closes the connection — mirrors the h1 431 posture.
const max_header_block = 64 * 1024

// A request body larger than this closes the connection — mirrors the h1
// engine's built-in request ceiling (sm_max_request_bytes).
const max_body_bytes = 8 * 1024 * 1024

@[heap]
struct StreamState {
mut:
	headers     []HeaderField
	body        []u8
	remote_done bool // END_STREAM received — the request is complete
	recv_window i64
	send_window i64
	pending     []u8 // response DATA parked until the peer opens its window
	pending_off int
	pending_end bool
}

// ServerConn is one connection's HTTP/2 state. Allocate with new_server_conn
// and keep it per connection (it is the natural takeover_state value).
@[heap]
pub struct ServerConn {
mut:
	dec          HpackDecoder
	preface_seen bool
	saw_goaway   bool
	last_stream  u32
	streams      map[u32]&StreamState
	// header-block assembly: HEADERS..CONTINUATION must be contiguous (§4.3)
	hdr_expecting  bool
	hdr_stream     u32
	hdr_end_stream bool
	hdr_refused    bool
	hdr_trailers   bool
	hdr_block      []u8
	// peer-declared limits and both directions' flow-control windows
	peer_max_frame   int = default_max_frame_size
	init_send_window i64 = i64(default_window_size)
	conn_send_window i64 = i64(default_window_size)
	conn_recv_window i64 = i64(default_window_size)
}

// new_server_conn returns a fresh connection state (heap — it must outlive
// the handler invocation that created it).
pub fn new_server_conn() &ServerConn {
	return &ServerConn{
		dec: new_decoder(hpack_default_table_size)
	}
}

// write_server_preface appends the server connection preface — the SETTINGS
// frame RFC 9113 §3.4 requires as the server's first bytes. The upgrade
// handler appends this as its "switching response" when queueing the
// takeover, so it is flushed before any client frame is answered.
pub fn (mut c ServerConn) write_server_preface(mut out []u8) {
	write_settings(mut out, [
		Setting{
			id:  setting_max_concurrent_streams
			val: u32(max_concurrent_streams)
		},
		Setting{
			id:  setting_header_table_size
			val: u32(hpack_default_table_size)
		},
	])
}

// consume processes as many complete frames as `buf` holds. Completed
// requests are appended to `reqs`; protocol-mandated replies (SETTINGS ack,
// PING ack, WINDOW_UPDATE, RST_STREAM, GOAWAY) are appended to `out`.
// Returns the bytes consumed and whether the connection must close (GOAWAY
// written or received) — a ConnHandler maps that straight to .done/.close.
pub fn (mut c ServerConn) consume(buf []u8, mut out []u8, mut reqs []Http2Request) (int, bool) {
	mut consumed := 0
	if !c.preface_seen {
		if buf.len < preface_tail.len {
			return 0, false
		}
		for i in 0 .. preface_tail.len {
			if buf[i] != preface_tail[i] {
				write_goaway(mut out, 0, .protocol_error)
				return consumed, true
			}
		}
		consumed = preface_tail.len
		c.preface_seen = true
	}
	for {
		rest := buf.len - consumed
		if rest < frame_header_len {
			break
		}
		fh := parse_frame_header(unsafe { (&buf[consumed]).vbytes(rest) }) or {
			write_goaway(mut out, c.last_stream, .internal_error)
			return consumed, true
		}
		if int(fh.length) > default_max_frame_size {
			// We never raise SETTINGS_MAX_FRAME_SIZE, so a bigger frame is a
			// peer error (§4.2) — and the ceiling on buffering one frame.
			write_goaway(mut out, c.last_stream, .frame_size_error)
			return consumed, true
		}
		total := frame_header_len + int(fh.length)
		if rest < total {
			break // partial frame — the engine buffers the tail and re-calls
		}
		payload := if fh.length > 0 {
			unsafe { (&buf[consumed + frame_header_len]).vbytes(int(fh.length)) }
		} else {
			[]u8{}
		}
		if u8(fh.type_) > u8(FrameType.continuation) {
			consumed += total // unknown frame types MUST be ignored (§4.1)
			continue
		}
		code := c.frame(fh, payload, mut out, mut reqs)
		consumed += total
		if code != .no_error {
			write_goaway(mut out, c.last_stream, code)
			return consumed, true
		}
		if c.saw_goaway {
			return consumed, true
		}
	}
	return consumed, false
}

// frame dispatches one complete frame. Any code but .no_error is
// connection-fatal (consume answers with GOAWAY).
fn (mut c ServerConn) frame(fh FrameHeader, payload []u8, mut out []u8, mut reqs []Http2Request) ErrorCode {
	if c.hdr_expecting && fh.type_ != .continuation {
		return .protocol_error // a header block must be contiguous (§4.3)
	}
	match fh.type_ {
		.data {
			return c.on_data(fh, payload, mut out, mut reqs)
		}
		.headers {
			return c.on_headers(fh, payload, mut out, mut reqs)
		}
		.priority {
			if fh.stream_id == 0 {
				return .protocol_error
			}
			if payload.len != 5 {
				return .frame_size_error
			}
			return .no_error // deprecated scheme — parsed, ignored (§6.3)
		}
		.rst_stream {
			if fh.stream_id == 0 {
				return .protocol_error
			}
			if payload.len != 4 {
				return .frame_size_error
			}
			c.streams.delete(fh.stream_id)
			return .no_error
		}
		.settings {
			return c.on_settings(fh, payload, mut out)
		}
		.push_promise {
			return .protocol_error // clients cannot push (§8.4)
		}
		.ping {
			if fh.stream_id != 0 {
				return .protocol_error
			}
			if payload.len != 8 {
				return .frame_size_error
			}
			if fh.flags & flag_ack == 0 {
				write_ping_ack(mut out, payload)
			}
			return .no_error
		}
		.goaway {
			if payload.len < 8 {
				return .frame_size_error
			}
			c.saw_goaway = true
			return .no_error
		}
		.window_update {
			return c.on_window_update(fh, payload, mut out)
		}
		.continuation {
			if !c.hdr_expecting || fh.stream_id != c.hdr_stream {
				return .protocol_error
			}
			if c.hdr_block.len + payload.len > max_header_block {
				return .enhance_your_calm
			}
			if payload.len > 0 {
				unsafe { c.hdr_block.push_many(&payload[0], payload.len) }
			}
			if fh.flags & flag_end_headers != 0 {
				return c.finish_header_block(mut out, mut reqs)
			}
			return .no_error
		}
	}
	return .no_error
}

fn (mut c ServerConn) on_headers(fh FrameHeader, payload []u8, mut out []u8, mut reqs []Http2Request) ErrorCode {
	if fh.stream_id == 0 || fh.stream_id & 1 == 0 {
		return .protocol_error // client streams are odd (§5.1.1)
	}
	mut off := 0
	mut end := payload.len
	if fh.flags & flag_padded != 0 {
		if payload.len < 1 {
			return .protocol_error
		}
		pad := int(payload[0])
		off = 1
		if off + pad > payload.len {
			return .protocol_error
		}
		end = payload.len - pad
	}
	if fh.flags & flag_priority != 0 {
		if off + 5 > end {
			return .protocol_error
		}
		off += 5
	}
	c.hdr_trailers = false
	c.hdr_refused = false
	if fh.stream_id in c.streams {
		s := c.streams[fh.stream_id] or { return .internal_error }
		// A second HEADERS on an open stream: trailers — only valid while the
		// request side is open and only when it closes it (§8.1).
		if s.remote_done || fh.flags & flag_end_stream == 0 {
			return .protocol_error
		}
		c.hdr_trailers = true
	} else {
		if fh.stream_id <= c.last_stream {
			return .protocol_error // new stream ids must ascend (§5.1.1)
		}
		c.last_stream = fh.stream_id
		if c.streams.len >= max_concurrent_streams {
			// The block still decodes below — HPACK state is connection-wide
			// (§4.3) — but the stream itself is refused.
			c.hdr_refused = true
		}
	}
	c.hdr_stream = fh.stream_id
	c.hdr_end_stream = fh.flags & flag_end_stream != 0
	c.hdr_block.clear()
	if end > off {
		unsafe { c.hdr_block.push_many(&payload[off], end - off) }
	}
	if fh.flags & flag_end_headers != 0 {
		return c.finish_header_block(mut out, mut reqs)
	}
	c.hdr_expecting = true
	return .no_error
}

// finish_header_block runs once END_HEADERS arrives: decompress, then either
// surface trailers-completion, refuse, or open the stream (and complete the
// request when END_STREAM rode the HEADERS).
fn (mut c ServerConn) finish_header_block(mut out []u8, mut reqs []Http2Request) ErrorCode {
	c.hdr_expecting = false
	fields := c.dec.decode(c.hdr_block) or {
		return .compression_error // table state is unrecoverable (RFC 7541 §5.3)
	}
	stream_id := c.hdr_stream
	if c.hdr_trailers {
		// Trailers kept the HPACK state consistent; their fields are not
		// surfaced (v1) — they complete the request as END_STREAM does.
		mut s := c.streams[stream_id] or { return .internal_error }
		s.remote_done = true
		reqs << Http2Request{
			stream_id: stream_id
			headers:   s.headers
			body:      s.body
		}
		return .no_error
	}
	if c.hdr_refused {
		write_rst_stream(mut out, stream_id, .refused_stream)
		return .no_error
	}
	mut s := &StreamState{
		headers:     fields
		recv_window: i64(default_window_size)
		send_window: c.init_send_window
	}
	c.streams[stream_id] = s
	if c.hdr_end_stream {
		s.remote_done = true
		reqs << Http2Request{
			stream_id: stream_id
			headers:   s.headers
			body:      s.body
		}
	}
	return .no_error
}

fn (mut c ServerConn) on_data(fh FrameHeader, payload []u8, mut out []u8, mut reqs []Http2Request) ErrorCode {
	if fh.stream_id == 0 {
		return .protocol_error
	}
	if fh.stream_id !in c.streams {
		return .stream_closed // DATA on an idle/closed stream (§6.1)
	}
	mut s := c.streams[fh.stream_id] or { return .internal_error }
	if s.remote_done {
		return .stream_closed
	}
	flow := payload.len // padding counts toward flow control (§6.9.1)
	c.conn_recv_window -= i64(flow)
	s.recv_window -= i64(flow)
	if c.conn_recv_window < 0 || s.recv_window < 0 {
		return .flow_control_error
	}
	mut off := 0
	mut end := payload.len
	if fh.flags & flag_padded != 0 {
		if payload.len < 1 {
			return .protocol_error
		}
		pad := int(payload[0])
		off = 1
		if off + pad > payload.len {
			return .protocol_error
		}
		end = payload.len - pad
	}
	if s.body.len + (end - off) > max_body_bytes {
		return .enhance_your_calm // mirrors the h1 request-size ceiling
	}
	if end > off {
		unsafe { s.body.push_many(&payload[off], end - off) }
	}
	// Replenish eagerly: bodies are consumed on arrival (handlers see whole
	// requests), so the peer's view of both windows snaps back to full.
	if flow > 0 {
		write_window_update(mut out, 0, u32(flow))
		c.conn_recv_window += i64(flow)
		if fh.flags & flag_end_stream == 0 {
			write_window_update(mut out, fh.stream_id, u32(flow))
			s.recv_window += i64(flow)
		}
	}
	if fh.flags & flag_end_stream != 0 {
		s.remote_done = true
		reqs << Http2Request{
			stream_id: fh.stream_id
			headers:   s.headers
			body:      s.body
		}
	}
	return .no_error
}

fn (mut c ServerConn) on_settings(fh FrameHeader, payload []u8, mut out []u8) ErrorCode {
	if fh.stream_id != 0 {
		return .protocol_error
	}
	if fh.flags & flag_ack != 0 {
		if payload.len != 0 {
			return .frame_size_error
		}
		return .no_error
	}
	settings := parse_settings(payload) or { return .frame_size_error }
	for st in settings {
		if st.id == setting_initial_window_size {
			if st.val > max_window {
				return .flow_control_error
			}
			delta := i64(st.val) - c.init_send_window
			c.init_send_window = i64(st.val)
			// §6.9.2: a changed initial window retroactively adjusts every
			// open stream's send window (it may go negative).
			for id in c.streams.keys() {
				mut s := c.streams[id] or { continue }
				s.send_window += delta
			}
		} else if st.id == setting_max_frame_size {
			if st.val < u32(default_max_frame_size) || st.val > 16777215 {
				return .protocol_error
			}
			c.peer_max_frame = int(st.val)
		} else if st.id == setting_enable_push {
			if st.val > 1 {
				return .protocol_error
			}
		}
		// setting_header_table_size needs no action: this server's encoder
		// never indexes, so no encoder table exists to resize. Unknown
		// identifiers are ignored (§6.5.2).
	}
	write_settings_ack(mut out)
	return .no_error
}

fn (mut c ServerConn) on_window_update(fh FrameHeader, payload []u8, mut out []u8) ErrorCode {
	if payload.len != 4 {
		return .frame_size_error
	}
	inc := read_u32(payload, 0) & 0x7fffffff
	if inc == 0 {
		return .protocol_error
	}
	if fh.stream_id == 0 {
		c.conn_send_window += i64(inc)
		if c.conn_send_window > i64(max_window) {
			return .flow_control_error
		}
		for id in c.streams.keys() {
			c.flush_pending(mut out, id)
		}
		return .no_error
	}
	if fh.stream_id !in c.streams {
		return .no_error // stream already finished — stale update, ignore
	}
	mut s := c.streams[fh.stream_id] or { return .internal_error }
	s.send_window += i64(inc)
	if s.send_window > i64(max_window) {
		write_rst_stream(mut out, fh.stream_id, .flow_control_error)
		c.streams.delete(fh.stream_id)
		return .no_error // stream-level error (§6.9.1), connection lives on
	}
	c.flush_pending(mut out, fh.stream_id)
	return .no_error
}

// write_response_headers appends the response HEADERS frame for `block` (an
// HPACK block built with the encode_* helpers — :status first, RFC 9113
// §8.3). A block wider than the peer's max frame size splits into
// CONTINUATIONs. end_stream=true finishes the response (no body follows).
pub fn (mut c ServerConn) write_response_headers(mut out []u8, stream_id u32, block []u8, end_stream bool) {
	es := if end_stream { flag_end_stream } else { u8(0) }
	if block.len <= c.peer_max_frame {
		write_frame_header(mut out, .headers, flag_end_headers | es, stream_id, block.len)
		out << block
	} else {
		write_frame_header(mut out, .headers, es, stream_id, c.peer_max_frame)
		unsafe { out.push_many(&block[0], c.peer_max_frame) }
		mut off := c.peer_max_frame
		for off < block.len {
			mut chunk := block.len - off
			mut flags := flag_end_headers
			if chunk > c.peer_max_frame {
				chunk = c.peer_max_frame
				flags = 0
			}
			write_frame_header(mut out, .continuation, flags, stream_id, chunk)
			unsafe { out.push_many(&block[off], chunk) }
			off += chunk
		}
	}
	if end_stream {
		c.streams.delete(stream_id)
	}
}

// write_response_data appends the response body as DATA frames, respecting
// the connection and stream send windows and the peer's max frame size.
// Whatever the windows cannot take is parked in the stream's pending buffer
// and flushed as the peer's WINDOW_UPDATEs arrive (through consume). The
// last DATA frame carries END_STREAM and releases the stream state.
pub fn (mut c ServerConn) write_response_data(mut out []u8, stream_id u32, body []u8) {
	mut s := c.streams[stream_id] or { return }
	if body.len == 0 {
		write_data_header(mut out, stream_id, 0, true)
		c.streams.delete(stream_id)
		return
	}
	s.pending << body
	s.pending_end = true
	c.flush_pending(mut out, stream_id)
}

fn (mut c ServerConn) flush_pending(mut out []u8, stream_id u32) {
	mut s := c.streams[stream_id] or { return }
	for s.pending_off < s.pending.len {
		mut allow := c.conn_send_window
		if s.send_window < allow {
			allow = s.send_window
		}
		if allow <= 0 {
			return // parked until a WINDOW_UPDATE reopens a window
		}
		mut chunk := s.pending.len - s.pending_off
		if i64(chunk) > allow {
			chunk = int(allow)
		}
		if chunk > c.peer_max_frame {
			chunk = c.peer_max_frame
		}
		last := s.pending_off + chunk == s.pending.len && s.pending_end
		write_data_header(mut out, stream_id, chunk, last)
		unsafe { out.push_many(&s.pending[s.pending_off], chunk) }
		s.pending_off += chunk
		c.conn_send_window -= i64(chunk)
		s.send_window -= i64(chunk)
	}
	if s.pending_off == s.pending.len && s.pending_end {
		c.streams.delete(stream_id)
	}
}
