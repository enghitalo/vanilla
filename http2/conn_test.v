module http2

// ServerConn state-machine tests: client-side frames are built with the same
// symmetric writers, fed through consume in engine-realistic slices (whole
// bursts, split frames, pipelined preface), and the machine's output is
// re-parsed with the same frame codec.

struct ParsedFrame {
	fh      FrameHeader
	payload []u8
}

// frames_of splits an output buffer back into frames.
fn frames_of(buf []u8) []ParsedFrame {
	mut out := []ParsedFrame{}
	mut pos := 0
	for pos + frame_header_len <= buf.len {
		fh := parse_frame_header(buf[pos..]) or { panic(err) }
		total := frame_header_len + int(fh.length)
		assert pos + total <= buf.len
		out << ParsedFrame{
			fh:      fh
			payload: buf[pos + frame_header_len..pos + total]
		}
		pos += total
	}
	assert pos == buf.len
	return out
}

fn hf(name string, value string) HeaderField {
	return HeaderField{
		name:  name
		value: value
	}
}

// get_request_block builds a GET / request header block from static indexes:
// :method GET (2), :scheme http (6), :path / (4), :authority literal (1).
fn get_request_block() []u8 {
	mut block := []u8{}
	encode_indexed(mut block, 2)
	encode_indexed(mut block, 6)
	encode_indexed(mut block, 4)
	encode_literal_name_idx(mut block, 1, 'x.test')
	return block
}

fn get_request_fields() []HeaderField {
	return [hf(':method', 'GET'), hf(':scheme', 'http'), hf(':path', '/'),
		hf(':authority', 'x.test')]
}

fn test_server_preface_parses() ! {
	mut c := new_server_conn()
	mut out := []u8{}
	c.write_server_preface(mut out)
	frames := frames_of(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .settings
	assert frames[0].fh.flags & flag_ack == 0
	settings := parse_settings(frames[0].payload)!
	assert settings.len == 2
	assert settings[0].id == setting_max_concurrent_streams
	assert int(settings[0].val) == max_concurrent_streams
}

fn test_preface_tail_and_settings_handshake() {
	mut c := new_server_conn()
	mut input := []u8{}
	input << preface_tail
	write_settings(mut input, []) // empty client SETTINGS
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert reqs.len == 0
	frames := frames_of(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .settings
	assert frames[0].fh.flags & flag_ack != 0
}

fn test_bad_preface_tail_closes() {
	mut c := new_server_conn()
	mut out := []u8{}
	mut reqs := []Http2Request{}
	_, closing := c.consume('XM\r\n\r\n'.bytes(), mut out, mut reqs)
	assert closing
	frames := frames_of(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .goaway
}

// handshake feeds the preface tail + empty client SETTINGS and discards the ack.
fn handshake(mut c ServerConn) {
	mut input := []u8{}
	input << preface_tail
	write_settings(mut input, [])
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
}

fn test_get_request_and_response() ! {
	mut c := new_server_conn()
	handshake(mut c)
	block := get_request_block()
	mut input := []u8{}
	write_frame_header(mut input, .headers, flag_end_headers | flag_end_stream, 1, block.len)
	input << block
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert reqs.len == 1
	assert reqs[0].stream_id == 1
	assert reqs[0].headers == get_request_fields()
	assert reqs[0].body.len == 0

	// Respond: 200 + a body, then check the wire shape end to end.
	mut resp_block := []u8{}
	encode_status(mut resp_block, 200)
	encode_literal(mut resp_block, 'content-type', 'text/plain')
	c.write_response_headers(mut out, 1, resp_block, false)
	c.write_response_data(mut out, 1, 'hello over http2'.bytes())
	frames := frames_of(out)
	assert frames.len == 2
	assert frames[0].fh.type_ == .headers
	assert frames[0].fh.flags & flag_end_headers != 0
	assert frames[0].fh.flags & flag_end_stream == 0
	mut d := new_decoder(hpack_default_table_size)
	decoded := d.decode(frames[0].payload)!
	assert decoded == [hf(':status', '200'), hf('content-type', 'text/plain')]
	assert frames[1].fh.type_ == .data
	assert frames[1].fh.flags & flag_end_stream != 0
	assert frames[1].payload.bytestr() == 'hello over http2'
	// The stream is done — its state must be released.
	assert c.streams.len == 0
}

fn test_post_body_and_window_replenish() {
	mut c := new_server_conn()
	handshake(mut c)
	mut block := []u8{}
	encode_indexed(mut block, 3) // :method POST
	encode_indexed(mut block, 6)
	encode_indexed(mut block, 4)
	encode_literal_name_idx(mut block, 1, 'x.test')
	mut input := []u8{}
	write_frame_header(mut input, .headers, flag_end_headers, 1, block.len)
	input << block
	write_data_header(mut input, 1, 5, false)
	input << 'hello'.bytes()
	write_data_header(mut input, 1, 6, true)
	input << ' world'.bytes()
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert reqs.len == 1
	assert reqs[0].body.bytestr() == 'hello world'
	// First DATA (not END_STREAM): connection + stream replenishment.
	// Second DATA (END_STREAM): connection replenishment only.
	frames := frames_of(out)
	assert frames.len == 3
	assert frames[0].fh.type_ == .window_update
	assert frames[0].fh.stream_id == 0
	assert read_u32(frames[0].payload, 0) == 5
	assert frames[1].fh.type_ == .window_update
	assert frames[1].fh.stream_id == 1
	assert read_u32(frames[1].payload, 0) == 5
	assert frames[2].fh.type_ == .window_update
	assert frames[2].fh.stream_id == 0
	assert read_u32(frames[2].payload, 0) == 6
}

fn test_partial_frame_buffering() {
	mut c := new_server_conn()
	handshake(mut c)
	block := get_request_block()
	mut whole := []u8{}
	write_frame_header(mut whole, .headers, flag_end_headers | flag_end_stream, 1, block.len)
	whole << block
	// First burst stops mid-payload: nothing consumed beyond complete frames.
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed1, closing1 := c.consume(whole[..whole.len - 3], mut out, mut reqs)
	assert consumed1 == 0
	assert !closing1
	assert reqs.len == 0
	// The engine compacts and re-calls with the tail appended.
	consumed2, closing2 := c.consume(whole, mut out, mut reqs)
	assert consumed2 == whole.len
	assert !closing2
	assert reqs.len == 1
}

fn test_ping_echo() {
	mut c := new_server_conn()
	handshake(mut c)
	opaque := [u8(9), 8, 7, 6, 5, 4, 3, 2]
	mut input := []u8{}
	write_frame_header(mut input, .ping, 0, 0, 8)
	input << opaque
	mut out := []u8{}
	mut reqs := []Http2Request{}
	_, closing := c.consume(input, mut out, mut reqs)
	assert !closing
	frames := frames_of(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .ping
	assert frames[0].fh.flags & flag_ack != 0
	assert frames[0].payload == opaque
}

fn test_flow_control_parks_and_window_update_flushes() {
	mut c := new_server_conn()
	// Client SETTINGS: initial stream window of 10 bytes.
	mut input := []u8{}
	input << preface_tail
	write_settings(mut input, [
		Setting{
			id:  setting_initial_window_size
			val: 10
		},
	])
	block := get_request_block()
	write_frame_header(mut input, .headers, flag_end_headers | flag_end_stream, 1, block.len)
	input << block
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert reqs.len == 1
	// A 25-byte body against a 10-byte stream window: 10 sent, 15 parked.
	out.clear()
	body := 'abcdefghijklmnopqrstuvwxy'.bytes()
	mut resp_block := []u8{}
	encode_status(mut resp_block, 200)
	c.write_response_headers(mut out, 1, resp_block, false)
	c.write_response_data(mut out, 1, body)
	mut frames := frames_of(out)
	assert frames.len == 2
	assert frames[1].fh.type_ == .data
	assert int(frames[1].fh.length) == 10
	assert frames[1].fh.flags & flag_end_stream == 0
	assert c.streams.len == 1
	// WINDOW_UPDATE for the stream releases the rest, END_STREAM included.
	out.clear()
	mut wu := []u8{}
	write_window_update(mut wu, 1, 15)
	_, closing2 := c.consume(wu, mut out, mut reqs)
	assert !closing2
	frames = frames_of(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .data
	assert int(frames[0].fh.length) == 15
	assert frames[0].fh.flags & flag_end_stream != 0
	assert frames[0].payload.bytestr() == 'klmnopqrstuvwxy'
	assert c.streams.len == 0
}

fn test_unknown_frame_type_ignored() {
	mut c := new_server_conn()
	handshake(mut c)
	// Type 0x0b does not exist — the frame must be skipped whole.
	input := [u8(0), 0, 2, 0x0b, 0, 0, 0, 0, 1, 0xaa, 0xbb]
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert out.len == 0
}

fn test_push_promise_from_client_is_fatal() {
	mut c := new_server_conn()
	handshake(mut c)
	mut input := []u8{}
	write_frame_header(mut input, .push_promise, flag_end_headers, 1, 0)
	mut out := []u8{}
	mut reqs := []Http2Request{}
	_, closing := c.consume(input, mut out, mut reqs)
	assert closing
	frames := frames_of(out)
	assert frames[frames.len - 1].fh.type_ == .goaway
}

fn test_oversized_frame_is_fatal() {
	mut c := new_server_conn()
	handshake(mut c)
	// A frame header claiming 20000 bytes: above SETTINGS_MAX_FRAME_SIZE.
	input := [u8(0x00), 0x4e, 0x20, 0x00, 0, 0, 0, 0, 1]
	mut out := []u8{}
	mut reqs := []Http2Request{}
	_, closing := c.consume(input, mut out, mut reqs)
	assert closing
	frames := frames_of(out)
	assert frames[frames.len - 1].fh.type_ == .goaway
	assert read_u32(frames[frames.len - 1].payload, 4) == u32(ErrorCode.frame_size_error)
}

fn test_new_stream_ids_must_ascend() {
	mut c := new_server_conn()
	handshake(mut c)
	block5 := get_request_block()
	mut input := []u8{}
	write_frame_header(mut input, .headers, flag_end_headers | flag_end_stream, 5, block5.len)
	input << block5
	mut out := []u8{}
	mut reqs := []Http2Request{}
	_, closing1 := c.consume(input, mut out, mut reqs)
	assert !closing1
	assert reqs.len == 1
	// Stream 3 after stream 5 — protocol error, connection-fatal.
	block3 := get_request_block()
	mut input2 := []u8{}
	write_frame_header(mut input2, .headers, flag_end_headers | flag_end_stream, 3, block3.len)
	input2 << block3
	out.clear()
	_, closing2 := c.consume(input2, mut out, mut reqs)
	assert closing2
	frames := frames_of(out)
	assert frames[frames.len - 1].fh.type_ == .goaway
}

fn test_rst_stream_drops_state() {
	mut c := new_server_conn()
	handshake(mut c)
	block := get_request_block()
	mut input := []u8{}
	// Open stream 1 without END_STREAM (a request still uploading)...
	write_frame_header(mut input, .headers, flag_end_headers, 1, block.len)
	input << block
	// ...then the client aborts it.
	write_rst_stream(mut input, 1, .cancel)
	mut out := []u8{}
	mut reqs := []Http2Request{}
	consumed, closing := c.consume(input, mut out, mut reqs)
	assert consumed == input.len
	assert !closing
	assert reqs.len == 0
	assert c.streams.len == 0
}
