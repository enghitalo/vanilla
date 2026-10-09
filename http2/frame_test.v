module http2

fn test_frame_header_roundtrip() ! {
	mut out := []u8{}
	write_frame_header(mut out, .headers, flag_end_headers | flag_end_stream, 5, 1234)
	assert out.len == frame_header_len
	fh := parse_frame_header(out)!
	assert fh.length == 1234
	assert fh.type_ == .headers
	assert fh.flags == flag_end_headers | flag_end_stream
	assert fh.stream_id == 5
}

fn test_frame_header_reserved_bit_cleared() ! {
	mut out := []u8{}
	// Writer must zero the reserved bit even for a huge id; parser must mask it.
	write_frame_header(mut out, .data, 0, 0xffffffff, 0)
	fh := parse_frame_header(out)!
	assert fh.stream_id == 0x7fffffff
	assert out[5] & 0x80 == 0
}

fn test_settings_roundtrip() ! {
	mut out := []u8{}
	write_settings(mut out, [
		Setting{
			id:  setting_max_concurrent_streams
			val: 128
		},
		Setting{
			id:  setting_initial_window_size
			val: 65535
		},
	])
	fh := parse_frame_header(out)!
	assert fh.type_ == .settings
	assert fh.stream_id == 0
	assert int(fh.length) == 12
	settings := parse_settings(out[frame_header_len..])!
	assert settings.len == 2
	assert settings[0].id == setting_max_concurrent_streams
	assert settings[0].val == 128
	assert settings[1].id == setting_initial_window_size
	assert settings[1].val == 65535
}

fn test_parse_settings_rejects_partial_entry() {
	if _ := parse_settings([u8(0), 1, 0, 0]) {
		assert false
	}
}

fn test_settings_ack() ! {
	mut out := []u8{}
	write_settings_ack(mut out)
	fh := parse_frame_header(out)!
	assert fh.type_ == .settings
	assert fh.flags & flag_ack != 0
	assert fh.length == 0
}

fn test_ping_ack_echoes_payload() ! {
	opaque := [u8(1), 2, 3, 4, 5, 6, 7, 8]
	mut out := []u8{}
	write_ping_ack(mut out, opaque)
	fh := parse_frame_header(out)!
	assert fh.type_ == .ping
	assert fh.flags & flag_ack != 0
	assert int(fh.length) == 8
	assert out[frame_header_len..] == opaque
}

fn test_goaway_layout() ! {
	mut out := []u8{}
	write_goaway(mut out, 7, .protocol_error)
	fh := parse_frame_header(out)!
	assert fh.type_ == .goaway
	assert int(fh.length) == 8
	assert read_u32(out, frame_header_len) == 7
	assert read_u32(out, frame_header_len + 4) == u32(ErrorCode.protocol_error)
}

fn test_window_update_layout() ! {
	mut out := []u8{}
	write_window_update(mut out, 3, 4096)
	fh := parse_frame_header(out)!
	assert fh.type_ == .window_update
	assert fh.stream_id == 3
	assert int(fh.length) == 4
	assert read_u32(out, frame_header_len) == 4096
}

fn test_data_header_flags() ! {
	mut out := []u8{}
	write_data_header(mut out, 1, 10, false)
	write_data_header(mut out, 1, 0, true)
	first := parse_frame_header(out)!
	assert first.type_ == .data
	assert first.flags & flag_end_stream == 0
	assert int(first.length) == 10
	second := parse_frame_header(out[frame_header_len..])!
	assert second.flags & flag_end_stream != 0
	assert second.length == 0
}
