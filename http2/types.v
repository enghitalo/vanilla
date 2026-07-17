module http2

// HTTP/2 frame types (RFC 9113 Section 6)
pub enum FrameType {
	data          = 0x0
	headers       = 0x1
	priority      = 0x2
	rst_stream    = 0x3
	settings      = 0x4
	push_promise  = 0x5
	ping          = 0x6
	goaway        = 0x7
	window_update = 0x8
	continuation  = 0x9
}

// HTTP/2 settings identifiers (RFC 9113 Section 6.5.2)
pub enum SettingsId {
	settings_header_table_size      = 0x1
	settings_enable_push            = 0x2
	settings_max_concurrent_streams = 0x3
	settings_initial_window_size    = 0x4
	settings_max_frame_size         = 0x5
	settings_max_header_list_size   = 0x6
}

// HTTP/2 error codes (RFC 9113 Section 7)
pub enum ErrorCode {
	no_error            = 0x0
	protocol_error      = 0x1
	internal_error      = 0x2
	flow_control_error  = 0x3
	settings_timeout    = 0x4
	stream_closed       = 0x5
	frame_size_error    = 0x6
	refused_stream      = 0x7
	cancel              = 0x8
	compression_error   = 0x9
	connect_error       = 0xa
	enhance_your_calm   = 0xb
	inadequate_security = 0xc
	http_1_1_required   = 0xd
}

// HTTP/2 frame header structure
pub struct FrameHeader {
pub:
	length    u32 // 24 bits
	type_     FrameType
	flags     u8
	stream_id u32 // 31 bits
}
