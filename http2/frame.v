module http2

// HTTP/2 frame parsing and serialization (RFC 9113 Section 4.1)

pub fn parse_frame_header(data []u8) !FrameHeader {
	if data.len < 9 {
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

pub fn serialize_frame_header(header FrameHeader) []u8 {
	mut data := []u8{len: 9}
	data[0] = u8((header.length >> 16) & 0xFF)
	data[1] = u8((header.length >> 8) & 0xFF)
	data[2] = u8(header.length & 0xFF)
	data[3] = u8(header.type_)
	data[4] = header.flags
	data[5] = u8((header.stream_id >> 24) & 0x7F) // reserved bit is 0
	data[6] = u8((header.stream_id >> 16) & 0xFF)
	data[7] = u8((header.stream_id >> 8) & 0xFF)
	data[8] = u8(header.stream_id & 0xFF)
	return data
}
