module http2

// HTTP/2 frame codec (RFC 9113 §4) — parsing stays zero-copy (headers are
// fixed offsets over the read buffer), writers append straight into the
// caller's `out` buffer (docs/BEST_PRACTICES.md: no intermediate
// allocations on the serving path).

// The client connection preface (RFC 9113 §3.4). The first 18 bytes parse as
// an HTTP/1.1 request line (`PRI * HTTP/2.0` + an empty header section), so a
// prior-knowledge client reaches the request handler as method PRI — the
// handler answers by taking the connection over; `preface_tail` is what
// remains in the read buffer after that request.
pub const preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'.bytes()
pub const preface_tail = 'SM\r\n\r\n'.bytes()

pub const frame_header_len = 9

// Frame flags (RFC 9113 §6) — the ones this codec acts on.
pub const flag_end_stream = u8(0x01) // DATA, HEADERS
pub const flag_ack = u8(0x01) // SETTINGS, PING
pub const flag_end_headers = u8(0x04) // HEADERS, CONTINUATION
pub const flag_padded = u8(0x08) // DATA, HEADERS
pub const flag_priority = u8(0x20) // HEADERS

// Protocol defaults and bounds (RFC 9113 §6.5.2, §6.9.1).
pub const default_max_frame_size = 16384
pub const default_window_size = 65535
pub const max_window = u32(0x7fffffff)

// SETTINGS identifiers as wire values — kept as u16 (not the SettingsId enum)
// because unknown identifiers MUST be ignored, and V enums cannot carry
// unknown values safely.
pub const setting_header_table_size = u16(0x1)
pub const setting_enable_push = u16(0x2)
pub const setting_max_concurrent_streams = u16(0x3)
pub const setting_initial_window_size = u16(0x4)
pub const setting_max_frame_size = u16(0x5)
pub const setting_max_header_list_size = u16(0x6)

// Setting is one SETTINGS parameter (RFC 9113 §6.5.1).
pub struct Setting {
pub:
	id  u16
	val u32
}

// parse_frame_header reads the fixed 9-byte frame header at data[0]
// (RFC 9113 §4.1).
pub fn parse_frame_header(data []u8) !FrameHeader {
	if data.len < frame_header_len {
		return error('Frame header too short')
	}
	length := (u32(data[0]) << 16) | (u32(data[1]) << 8) | u32(data[2])
	type_ := unsafe { FrameType(data[3]) }
	flags := data[4]
	mut stream_id := (u32(data[5]) << 24) | (u32(data[6]) << 16) | (u32(data[7]) << 8) | u32(data[8])
	stream_id &= 0x7FFFFFFF // clear the reserved bit
	return FrameHeader{
		length:    length
		type_:     type_
		flags:     flags
		stream_id: stream_id
	}
}

// serialize_frame_header allocates a 9-byte header (tests/tools). On the
// serving path use write_frame_header, which appends into `out` instead.
pub fn serialize_frame_header(header FrameHeader) []u8 {
	mut data := []u8{cap: frame_header_len}
	write_frame_header(mut data, header.type_, header.flags, header.stream_id, int(header.length))
	return data
}

// write_frame_header appends a 9-byte frame header (RFC 9113 §4.1).
pub fn write_frame_header(mut out []u8, type_ FrameType, flags u8, stream_id u32, length int) {
	out << u8((length >> 16) & 0xff)
	out << u8((length >> 8) & 0xff)
	out << u8(length & 0xff)
	out << u8(type_)
	out << flags
	out << u8((stream_id >> 24) & 0x7f) // reserved bit is 0
	out << u8((stream_id >> 16) & 0xff)
	out << u8((stream_id >> 8) & 0xff)
	out << u8(stream_id & 0xff)
}

fn write_u32(mut out []u8, v u32) {
	out << u8(v >> 24)
	out << u8((v >> 16) & 0xff)
	out << u8((v >> 8) & 0xff)
	out << u8(v & 0xff)
}

fn read_u32(buf []u8, pos int) u32 {
	mut v := u32(buf[pos]) << 24
	v |= u32(buf[pos + 1]) << 16
	v |= u32(buf[pos + 2]) << 8
	v |= u32(buf[pos + 3])
	return v
}

// write_settings appends a SETTINGS frame carrying `settings` (RFC 9113 §6.5).
pub fn write_settings(mut out []u8, settings []Setting) {
	write_frame_header(mut out, .settings, 0, 0, settings.len * 6)
	for s in settings {
		out << u8(s.id >> 8)
		out << u8(s.id & 0xff)
		write_u32(mut out, s.val)
	}
}

// write_settings_ack appends the empty ACK a received SETTINGS requires.
pub fn write_settings_ack(mut out []u8) {
	write_frame_header(mut out, .settings, flag_ack, 0, 0)
}

// parse_settings decodes a SETTINGS payload (the caller passes the payload
// view, not the whole frame).
pub fn parse_settings(payload []u8) ![]Setting {
	if payload.len % 6 != 0 {
		return error('SETTINGS payload not a multiple of 6')
	}
	mut out := []Setting{cap: payload.len / 6}
	for pos := 0; pos < payload.len; pos += 6 {
		out << Setting{
			id:  u16(payload[pos]) << 8 | u16(payload[pos + 1])
			val: read_u32(payload, pos + 2)
		}
	}
	return out
}

// write_ping_ack appends a PING ACK echoing the 8 opaque payload bytes
// (RFC 9113 §6.7).
pub fn write_ping_ack(mut out []u8, opaque []u8) {
	write_frame_header(mut out, .ping, flag_ack, 0, 8)
	out << opaque
}

// write_goaway appends a GOAWAY with no debug data (RFC 9113 §6.8).
pub fn write_goaway(mut out []u8, last_stream_id u32, code ErrorCode) {
	write_frame_header(mut out, .goaway, 0, 0, 8)
	write_u32(mut out, last_stream_id & 0x7fffffff)
	write_u32(mut out, u32(code))
}

// write_rst_stream appends a RST_STREAM (RFC 9113 §6.4).
pub fn write_rst_stream(mut out []u8, stream_id u32, code ErrorCode) {
	write_frame_header(mut out, .rst_stream, 0, stream_id, 4)
	write_u32(mut out, u32(code))
}

// write_window_update appends a WINDOW_UPDATE for `increment` bytes on a
// stream (0 = the connection window) (RFC 9113 §6.9).
pub fn write_window_update(mut out []u8, stream_id u32, increment u32) {
	write_frame_header(mut out, .window_update, 0, stream_id, 4)
	write_u32(mut out, increment & 0x7fffffff)
}

// write_data_header appends a DATA frame header for a `length`-byte payload;
// the caller appends the payload bytes right after.
pub fn write_data_header(mut out []u8, stream_id u32, length int, end_stream bool) {
	flags := if end_stream { flag_end_stream } else { u8(0) }
	write_frame_header(mut out, .data, flags, stream_id, length)
}
