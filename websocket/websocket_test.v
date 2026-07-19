module websocket

// Codec vectors straight from RFC 6455 (§1.3 handshake, §5.7 framing
// examples) plus the malformed-input matrix frame_head must reject. Pure
// codec tests — the connection-level behaviour (upgrade, echo, close) is
// end-to-end tested in examples/websocket_echo.

fn test_accept_key_rfc_vector() {
	// RFC 6455 §1.3: the sample nonce and its expected accept value.
	assert accept_key('dGhlIHNhbXBsZSBub25jZQ==') == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
	mut out := []u8{}
	out << 'Sec-WebSocket-Accept: '.bytes()
	append_accept_key(mut out, 'dGhlIHNhbXBsZSBub25jZQ==')
	assert out.bytestr() == 'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='
}

fn test_masked_hello_rfc_vector() {
	// RFC 6455 §5.7: a single-frame masked text message containing "Hello".
	mut buf := [u8(0x81), 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]
	h := frame_head(buf)
	assert h.total == buf.len
	assert h.opcode == op_text
	assert h.fin
	assert h.masked
	assert h.payload_len == 5
	unmask_in_place(mut buf, h)
	assert buf[h.payload_off..h.payload_off + h.payload_len].bytestr() == 'Hello'
}

fn test_unmasked_hello_rfc_vector() {
	// RFC 6455 §5.7: the same message unmasked (a server→client frame).
	buf := [u8(0x81), 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
	h := frame_head(buf)
	assert h.total == buf.len
	assert !h.masked
	assert buf[h.payload_off..h.payload_off + h.payload_len].bytestr() == 'Hello'
}

fn test_extended_16bit_length() {
	// 256-byte unmasked binary frame: 126 marker + 2-byte big-endian length.
	mut buf := [u8(0x82), 126, 0x01, 0x00]
	buf << []u8{len: 256, init: u8(0x61)}
	h := frame_head(buf)
	assert h.total == 4 + 256
	assert h.opcode == op_binary
	assert h.payload_len == 256
	assert h.payload_off == 4
}

fn test_extended_64bit_length() {
	// 65536-byte frame: 127 marker + 8-byte big-endian length.
	mut buf := [u8(0x82), 127, 0, 0, 0, 0, 0, 1, 0, 0]
	buf << []u8{len: 65536, init: u8(0x62)}
	h := frame_head(buf)
	assert h.total == 10 + 65536
	assert h.payload_len == 65536
	assert h.payload_off == 10
}

fn test_incomplete_frames() {
	assert frame_head([]u8{}).total == incomplete
	assert frame_head([u8(0x81)]).total == incomplete
	// Header complete, payload still in flight.
	assert frame_head([u8(0x81), 0x05, 0x48]).total == incomplete
	// Masked header promises 4 key bytes that have not arrived.
	assert frame_head([u8(0x81), 0x85, 0x37, 0xfa]).total == incomplete
	// 16-bit length marker with only one extended byte so far.
	assert frame_head([u8(0x82), 126, 0x01]).total == incomplete
}

fn test_malformed_frames() {
	// RSV bits set without a negotiated extension.
	assert frame_head([u8(0xc1), 0x00]).total == err_malformed
	// Reserved opcodes 0x3 and 0xb.
	assert frame_head([u8(0x83), 0x00]).total == err_malformed
	assert frame_head([u8(0x8b), 0x00]).total == err_malformed
	// Fragmented control frame (ping without FIN).
	assert frame_head([u8(0x09), 0x00]).total == err_malformed
	// Control frame with a 126-marker length (> 125 forbidden).
	assert frame_head([u8(0x89), 126, 0x01, 0x00]).total == err_malformed
	// Non-minimal encodings: 16-bit form carrying 125, 64-bit form carrying 300.
	assert frame_head([u8(0x82), 126, 0x00, 0x7d]).total == err_malformed
	assert frame_head([u8(0x82), 127, 0, 0, 0, 0, 0, 0, 0x01, 0x2c]).total == err_malformed
	// 64-bit length beyond max_frame_payload.
	assert frame_head([u8(0x82), 127, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]).total == err_malformed
}

fn test_writer_roundtrip() {
	for payload_len in [0, 1, 125, 126, 300, 0xffff, 0x10000] {
		mut out := []u8{}
		write_frame_header(mut out, op_text, payload_len)
		out << []u8{len: payload_len, init: u8(0x2e)}
		h := frame_head(out)
		assert h.total == out.len, 'payload_len ${payload_len}'
		assert h.payload_len == payload_len
		assert h.fin
		assert !h.masked
		assert h.opcode == op_text
	}
}

fn test_close_and_pong_writers() {
	mut out := []u8{}
	write_close(mut out, close_normal)
	h := frame_head(out)
	assert h.total == out.len
	assert h.opcode == op_close
	assert h.payload_len == 2
	assert int(out[h.payload_off]) << 8 | int(out[h.payload_off + 1]) == 1000

	mut pong := []u8{}
	write_pong(mut pong, 'ka'.bytes())
	hp := frame_head(pong)
	assert hp.total == pong.len
	assert hp.opcode == op_pong
	assert pong[hp.payload_off..hp.payload_off + hp.payload_len].bytestr() == 'ka'
}
