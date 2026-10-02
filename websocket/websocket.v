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
// buffer — the handshake-path form, no intermediate string and no heap
// allocation: the SHA-1 runs over the key and then the GUID on the stack
// (Sha1 below). crypto.sha1.sum allocated 8 blocks per call (the key+GUID
// copy, the Digest and its two arrays, the padding and digest arrays, and one
// message schedule per block), ~830 B of RSS per upgrade that -gc none never
// gets back — a reconnecting client leaked it on every connection.
pub fn append_accept_key(mut out []u8, client_key string) {
	mut s := Sha1{}
	s.write(client_key.str, client_key.len)
	s.write(ws_guid.str, ws_guid.len)
	mut digest := [20]u8{}
	s.sum(mut digest)
	start := out.len
	unsafe { out.grow_len(28) } // base64 of 20 bytes = 28 chars
	base64.encode_in_buffer(unsafe { (&digest[0]).vbytes(20) }, unsafe { &u8(out.data) + start })
}

// Sha1 is SHA-1 (FIPS 180-4) in fixed arrays, for append_accept_key only: a
// value on the caller's stack, fed bytes with write, finished with sum. Not a
// general hashing API — it exists so the handshake allocates nothing.
struct Sha1 {
mut:
	h     [5]u32 = [u32(0x67452301), 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]!
	block [64]u8
	n     int // bytes buffered in block
	len   u64 // bytes written in total
}

@[direct_array_access]
fn (mut s Sha1) write(p &u8, len int) {
	for i in 0 .. len {
		s.block[s.n] = unsafe { p[i] }
		s.n++
		if s.n == 64 {
			s.compress()
			s.n = 0
		}
	}
	s.len += u64(len)
}

// sum pads the message (0x80, zeros, the 64-bit big-endian bit length) and
// writes the 20-byte digest.
@[direct_array_access]
fn (mut s Sha1) sum(mut digest [20]u8) {
	bits := s.len << 3
	s.block[s.n] = 0x80
	s.n++
	if s.n > 56 {
		// No room for the length: zero-fill and compress this block first.
		for s.n < 64 {
			s.block[s.n] = 0
			s.n++
		}
		s.compress()
		s.n = 0
	}
	for s.n < 56 {
		s.block[s.n] = 0
		s.n++
	}
	for i in 0 .. 8 {
		s.block[56 + i] = u8(bits >> (56 - 8 * i))
	}
	s.compress()
	for i in 0 .. 5 {
		digest[4 * i] = u8(s.h[i] >> 24)
		digest[4 * i + 1] = u8(s.h[i] >> 16)
		digest[4 * i + 2] = u8(s.h[i] >> 8)
		digest[4 * i + 3] = u8(s.h[i])
	}
}

// compress folds the full 64-byte block into the state.
@[direct_array_access]
fn (mut s Sha1) compress() {
	mut w := [80]u32{}
	for i in 0 .. 16 {
		j := 4 * i
		w[i] = (u32(s.block[j]) << 24) | (u32(s.block[j + 1]) << 16) | (u32(s.block[j + 2]) << 8) | u32(s.block[j + 3])
	}
	for i in 16 .. 80 {
		x := w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
		w[i] = (x << 1) | (x >> 31)
	}
	mut a := s.h[0]
	mut b := s.h[1]
	mut c := s.h[2]
	mut d := s.h[3]
	mut e := s.h[4]
	for i in 0 .. 80 {
		mut f := u32(0)
		mut k := u32(0)
		if i < 20 {
			f = (b & c) | (~b & d)
			k = 0x5a827999
		} else if i < 40 {
			f = b ^ c ^ d
			k = 0x6ed9eba1
		} else if i < 60 {
			f = (b & c) | (b & d) | (c & d)
			k = 0x8f1bbcdc
		} else {
			f = b ^ c ^ d
			k = 0xca62c1d6
		}
		t := ((a << 5) | (a >> 27)) + f + e + k + w[i]
		e = d
		d = c
		c = (b << 30) | (b >> 2)
		b = a
		a = t
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
	s.h[4] += e
}

// accept_key is append_accept_key's convenience form (allocates the string) —
// for tests and non-hot-path callers.
pub fn accept_key(client_key string) string {
	mut out := []u8{cap: 28}
	append_accept_key(mut out, client_key)
	return out.bytestr()
}
