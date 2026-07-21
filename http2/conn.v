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
	headers []HeaderField
	body    []u8
	// END_STREAM received — the request side is complete
	remote_done bool
	// refused or malformed (§8.3): the RST already went out; keep draining the
	// stream's frames quietly, never surface it as a request
	rejected bool
	// content-length asserted by the header block, -1 = none (§8.1.1: it must
	// equal the DATA total, checked when the request side completes)
	declared_len i64 = -1
	recv_window  i64
	send_window  i64
	// response DATA parked until the peer opens its window
	pending     []u8
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
	hdr_malformed  bool
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
			if c.hdr_expecting {
				// A header block must be a contiguous frame sequence — even
				// unknown frame types cannot interleave (§4.3).
				write_goaway(mut out, c.last_stream, .protocol_error)
				return consumed, true
			}
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
			dep := read_u32(payload, 0) & 0x7fffffff
			if dep == fh.stream_id {
				// A stream cannot depend on itself — stream error (§5.3.1).
				write_rst_stream(mut out, fh.stream_id, .protocol_error)
				c.streams.delete(fh.stream_id)
			}
			return .no_error // deprecated scheme — parsed, otherwise ignored (§6.3)
		}
		.rst_stream {
			if fh.stream_id == 0 || fh.stream_id > c.last_stream {
				return .protocol_error // includes RST on an idle stream (§6.4)
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
	c.hdr_trailers = false
	c.hdr_refused = false
	c.hdr_malformed = false
	if fh.flags & flag_priority != 0 {
		if off + 5 > end {
			return .protocol_error
		}
		dep := read_u32(payload, off) & 0x7fffffff
		if dep == fh.stream_id {
			c.hdr_malformed = true // self-dependency — stream error (§5.3.1)
		}
		off += 5
	}
	if fh.stream_id in c.streams {
		s := c.streams[fh.stream_id] or { return .internal_error }
		if s.remote_done {
			return .stream_closed // HEADERS on half-closed (remote) (§5.1)
		}
		// A second HEADERS on an open stream: trailers — only valid when the
		// block also closes the request side (§8.1).
		if fh.flags & flag_end_stream == 0 {
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
		if !valid_trailer_fields(fields) {
			// Pseudo-headers or connection-specific fields in trailers make
			// the request malformed (§8.1, §8.3) — stream error.
			write_rst_stream(mut out, stream_id, .protocol_error)
			c.streams.delete(stream_id)
			return .no_error
		}
		// Trailers kept the HPACK state consistent; their fields are not
		// surfaced (v1) — they complete the request as END_STREAM does.
		c.complete_stream(stream_id, mut out, mut reqs)
		return .no_error
	}
	if c.hdr_refused {
		write_rst_stream(mut out, stream_id, .refused_stream)
		return .no_error
	}
	ok, declared := validate_request_fields(fields)
	malformed := c.hdr_malformed || !ok
	mut s := &StreamState{
		headers:      fields
		rejected:     malformed
		declared_len: declared
		recv_window:  i64(default_window_size)
		send_window:  c.init_send_window
	}
	c.streams[stream_id] = s
	if malformed {
		// Malformed request (§8.3): a stream error, never surfaced. The
		// rejected stream state stays so the client's in-flight frames for it
		// drain quietly instead of escalating to a connection error.
		write_rst_stream(mut out, stream_id, .protocol_error)
	}
	if c.hdr_end_stream {
		c.complete_stream(stream_id, mut out, mut reqs)
	}
	return .no_error
}

// complete_stream ends a stream's request side: rejected streams and
// content-length violations are dropped, everything else surfaces as a
// complete request (the stream stays for the response to be written).
fn (mut c ServerConn) complete_stream(stream_id u32, mut out []u8, mut reqs []Http2Request) {
	mut s := c.streams[stream_id] or { return }
	s.remote_done = true
	if s.rejected {
		c.streams.delete(stream_id)
		return
	}
	if s.declared_len >= 0 && s.declared_len != i64(s.body.len) {
		// content-length must equal the DATA total (§8.1.1) — malformed.
		write_rst_stream(mut out, stream_id, .protocol_error)
		c.streams.delete(stream_id)
		return
	}
	reqs << Http2Request{
		stream_id: stream_id
		headers:   s.headers
		body:      s.body
	}
}

// validate_request_fields enforces the malformed-request rules of RFC 9113
// §8.2/§8.3 on a decoded request header list. Returns validity plus the
// declared content-length (-1 when absent).
fn validate_request_fields(fields []HeaderField) (bool, i64) {
	mut seen_regular := false
	mut method := ''
	mut n_method := 0
	mut n_scheme := 0
	mut n_path := 0
	mut n_authority := 0
	mut declared := i64(-1)
	for f in fields {
		if f.name.len == 0 {
			return false, -1
		}
		if f.name[0] == `:` {
			if seen_regular {
				return false, -1 // pseudo-header after a regular field (§8.3)
			}
			match f.name {
				':method' {
					n_method++
					method = f.value
				}
				':scheme' {
					n_scheme++
				}
				':path' {
					n_path++
					if f.value.len == 0 {
						return false, -1 // empty :path (§8.3.1)
					}
				}
				':authority' {
					n_authority++
				}
				else {
					return false, -1 // unknown or response pseudo-header (§8.3)
				}
			}
			continue
		}
		seen_regular = true
		if !valid_regular_field_name(f.name) {
			return false, -1
		}
		if f.name == 'te' && f.value != 'trailers' {
			return false, -1 // te may only carry 'trailers' (§8.2.2)
		}
		if f.name == 'content-length' {
			n := parse_content_length(f.value)
			if n < 0 {
				return false, -1
			}
			if declared >= 0 && declared != n {
				return false, -1 // differing duplicates (§8.1.1)
			}
			declared = n
		}
	}
	if n_method != 1 || n_authority > 1 {
		return false, -1
	}
	if method == 'CONNECT' {
		// CONNECT omits :scheme and :path and requires :authority (§8.5).
		if n_scheme != 0 || n_path != 0 || n_authority != 1 {
			return false, -1
		}
	} else if n_scheme != 1 || n_path != 1 {
		return false, -1 // exactly one of each (§8.3.1)
	}
	return true, declared
}

// valid_regular_field_name rejects uppercase (http2 field names are
// lowercase on the wire, §8.2) and the connection-specific fields that must
// not exist in http2 framing (§8.2.2).
fn valid_regular_field_name(name string) bool {
	for ch in name {
		if (ch >= `A` && ch <= `Z`) || ch == ` ` || ch == 0 {
			return false
		}
	}
	return match name {
		'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade' { false }
		else { true }
	}
}

// valid_trailer_fields: trailers carry only regular fields (§8.1).
fn valid_trailer_fields(fields []HeaderField) bool {
	for f in fields {
		if f.name.len == 0 || f.name[0] == `:` || !valid_regular_field_name(f.name) {
			return false
		}
	}
	return true
}

// parse_content_length parses a strictly-decimal content-length; -1 on
// anything else (signs, blanks, non-digits, absurd width).
fn parse_content_length(s string) i64 {
	if s.len == 0 || s.len > 18 {
		return -1
	}
	mut n := i64(0)
	for ch in s {
		if ch < `0` || ch > `9` {
			return -1
		}
		n = n * 10 + i64(ch - `0`)
	}
	return n
}

fn (mut c ServerConn) on_data(fh FrameHeader, payload []u8, mut out []u8, mut reqs []Http2Request) ErrorCode {
	if fh.stream_id == 0 {
		return .protocol_error
	}
	if fh.stream_id !in c.streams {
		if fh.stream_id > c.last_stream {
			return .protocol_error // DATA on an idle stream (§5.1, §6.1)
		}
		return .stream_closed // DATA on a fully closed stream (§5.1)
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
	if !s.rejected {
		if s.body.len + (end - off) > max_body_bytes {
			return .enhance_your_calm // mirrors the h1 request-size ceiling
		}
		if end > off {
			unsafe { s.body.push_many(&payload[off], end - off) }
		}
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
		c.complete_stream(fh.stream_id, mut out, mut reqs)
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
	if fh.stream_id != 0 && inc == 0 {
		// Zero increment on a stream is a STREAM error (§6.9).
		write_rst_stream(mut out, fh.stream_id, .protocol_error)
		c.streams.delete(fh.stream_id)
		return .no_error
	}
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
			// parked until a WINDOW_UPDATE reopens a window
			return
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
