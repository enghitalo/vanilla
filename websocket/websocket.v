module websocket

// RFC 6455 WebSocket codec — pure functions over bytes, nothing else (the
// protocol-sibling promised in docs/ARCHITECTURE.md, landed with issue #136's
// connection-takeover seam). No vanilla imports, no I/O, no state: the frame
// parser mirrors http1_1.client.frame_response (complete-message framing with
// int sentinels), the writers append straight into the caller's `out` buffer,
// and per-connection concerns (fragmentation reassembly, close handshakes)
// belong to the ConnHandler composing this codec.
//
// Server-side reminders the codec exposes but does NOT enforce (they are
// direction-specific, and this codec also serves future client use):
//   - a server MUST fail the connection on an UNMASKED client frame
//     (RFC 6455 §5.1) — check FrameHead.masked;
//   - server→client frames are sent UNMASKED — the writers below do that.
import crypto.sha1
import encoding.base64

// Frame opcodes (RFC 6455 §5.2).
pub const op_cont = u8(0x0)
pub const op_text = u8(0x1)
pub const op_binary = u8(0x2)
pub const op_close = u8(0x8)
pub const op_ping = u8(0x9)
pub const op_pong = u8(0xa)

// Close status codes (RFC 6455 §7.4.1) — the ones a minimal server sends.
pub const close_normal = u16(1000)
pub const close_protocol_error = u16(1002)
pub const close_unsupported = u16(1003)
pub const close_too_big = u16(1009)

// frame_head sentinels (FrameHead.total), matching http1_1.client's idiom.
pub const incomplete = -1
pub const err_malformed = -2

// A single frame's payload is capped server-side: bigger is err_malformed. A
// peer needing more sends fragments (fin=0 + continuations). Bounds what one
// frame can force the connection to buffer.
pub const max_frame_payload = 16 * 1024 * 1024

const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

// FrameHead describes one complete frame at the start of a buffer. Offsets
// index into that same buffer — the payload is a view, never a copy.
pub struct FrameHead {
pub:
	total       int // whole frame length (header + payload); incomplete / err_malformed
	payload_off int
	payload_len int
	opcode      u8
	fin         bool
	masked      bool
	mask_off    int // offset of the 4-byte masking key (valid only when masked)
}

// frame_head parses the frame starting at buf[0]. total == incomplete while
// the FULL frame (header + payload) has not arrived yet — accumulate and call
// again; err_malformed on a protocol violation (RSV bits without a negotiated
// extension, reserved opcode, fragmented or oversized control frame,
// non-minimal or oversized length encoding — RFC 6455 §5.2): fail the
// connection, these are unrecoverable framing errors.
@[direct_array_access]
pub fn frame_head(buf []u8) FrameHead {
	if buf.len < 2 {
		return FrameHead{
			total: incomplete
		}
	}
	b0 := buf[0]
	if b0 & 0x70 != 0 {
		return FrameHead{
			total: err_malformed
		} // RSV set, no extension negotiated
	}
	opcode := b0 & 0x0f
	if (opcode > 0x2 && opcode < 0x8) || opcode > 0xa {
		return FrameHead{
			total: err_malformed
		} // reserved opcode
	}
	fin := b0 & 0x80 != 0
	is_control := opcode & 0x8 != 0
	masked := buf[1] & 0x80 != 0
	len7 := int(buf[1] & 0x7f)
	mut off := 2
	mut payload_len := len7
	if is_control && (!fin || len7 > 125) {
		return FrameHead{
			total: err_malformed
		} // control frames: unfragmented, <= 125 (RFC 6455 §5.5)
	}
	if len7 == 126 {
		if buf.len < off + 2 {
			return FrameHead{
				total: incomplete
			}
		}
		payload_len = int(buf[off]) << 8 | int(buf[off + 1])
		if payload_len < 126 {
			return FrameHead{
				total: err_malformed
			} // non-minimal encoding
		}
		off += 2
	} else if len7 == 127 {
		if buf.len < off + 8 {
			return FrameHead{
				total: incomplete
			}
		}
		mut len64 := u64(0)
		for i in 0 .. 8 {
			len64 = len64 << 8 | u64(buf[off + i])
		}
		if len64 < 65536 || len64 > u64(max_frame_payload) {
			// non-minimal encoding, MSB set, or beyond what we will buffer
			return FrameHead{
				total: err_malformed
			}
		}
		payload_len = int(len64)
		off += 8
	}
	if payload_len > max_frame_payload {
		return FrameHead{
			total: err_malformed
		}
	}
	mask_off := off
	if masked {
		off += 4
	}
	if buf.len < off || i64(buf.len) < i64(off) + i64(payload_len) {
		return FrameHead{
			total: incomplete
		}
	}
	return FrameHead{
		total:       off + payload_len
		payload_off: off
		payload_len: payload_len
		opcode:      opcode
		fin:         fin
		masked:      masked
		mask_off:    mask_off
	}
}

// unmask_in_place XORs the frame's payload with its masking key, in the same
// buffer frame_head parsed — after it, buf[payload_off .. payload_off +
// payload_len] is the plain payload view. No-op on an unmasked frame.
@[direct_array_access]
pub fn unmask_in_place(mut buf []u8, h FrameHead) {
	if !h.masked {
		return
	}
	for i in 0 .. h.payload_len {
		buf[h.payload_off + i] ^= buf[h.mask_off + (i & 3)]
	}
}

// write_frame_header appends a server→client frame header (FIN set, unmasked
// — RFC 6455 §5.1 forbids masking server frames) for a payload of
// `payload_len` bytes; append the payload right after. Fragmented sends are a
// caller concern (write op_cont headers yourself) — v1 keeps the writer to
// the whole-message case.
@[direct_array_access]
pub fn write_frame_header(mut out []u8, opcode u8, payload_len int) {
	out << (u8(0x80) | opcode)
	if payload_len <= 125 {
		out << u8(payload_len)
	} else if payload_len <= 0xffff {
		out << u8(126)
		out << u8(payload_len >> 8)
		out << u8(payload_len & 0xff)
	} else {
		out << u8(127)
		mut shift := 56
		for _ in 0 .. 8 {
			out << u8((u64(payload_len) >> shift) & 0xff)
			shift -= 8
		}
	}
}

// write_close appends a complete close frame carrying `code` (RFC 6455 §5.5.1).
pub fn write_close(mut out []u8, code u16) {
	write_frame_header(mut out, op_close, 2)
	out << u8(code >> 8)
	out << u8(code & 0xff)
}

// write_pong appends a complete pong frame echoing a ping's payload
// (RFC 6455 §5.5.3: the pong carries the ping's application data).
pub fn write_pong(mut out []u8, payload []u8) {
	write_frame_header(mut out, op_pong, payload.len)
	out << payload
}

// append_accept_key appends the Sec-WebSocket-Accept value for `client_key`
// (RFC 6455 §4.2.2: base64(SHA-1(key + GUID))) straight into the response
// buffer — the handshake-path form, no intermediate string.
pub fn append_accept_key(mut out []u8, client_key string) {
	mut input := []u8{cap: client_key.len + ws_guid.len}
	unsafe { input.push_many(client_key.str, client_key.len) }
	unsafe { input.push_many(ws_guid.str, ws_guid.len) }
	digest := sha1.sum(input)
	start := out.len
	unsafe { out.grow_len(28) } // base64 of 20 bytes = 28 chars
	base64.encode_in_buffer(digest, unsafe { &u8(out.data) + start })
}

// accept_key is append_accept_key's convenience form (allocates the string) —
// for tests and non-hot-path callers.
pub fn accept_key(client_key string) string {
	mut out := []u8{cap: 28}
	append_accept_key(mut out, client_key)
	return out.bytestr()
}
