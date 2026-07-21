module main

// In-process tests: the h1 routes as plain handler calls, the preface guard,
// and the whole http2 bridge (ServerConn + translation + re-framing) driven
// as a bare ConnHandler — no sockets, no engine, pure bytes.
import core
import http2

fn serve_h1(req string) (core.Step, string) {
	mut res := []u8{}
	mut event_loop := core.EventLoop{}
	step := handle(req.bytes(), mut res, -1, unsafe { nil }, mut event_loop)
	return step, res.bytestr()
}

fn test_h1_routes() {
	step, home := serve_h1('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	assert step == .done
	assert home == home_response.bytestr()
	step2, echoed := serve_h1('POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nping')
	assert step2 == .done
	assert echoed.starts_with('HTTP/1.1 200 OK\r\n')
	assert echoed.ends_with('\r\n\r\nping')
	step3, missing := serve_h1('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n')
	assert step3 == .done
	assert missing.starts_with('HTTP/1.1 404')
}

fn test_preface_without_capable_worker_is_501() {
	// This test binary never calls core.enable_takeover(), so queue_takeover
	// reports false and the preface must be answered with the visible 501.
	step, res := serve_h1('PRI * HTTP/2.0\r\n\r\n')
	assert step == .close
	assert res == cannot_takeover_response.bytestr()
}

struct TestFrame {
	fh      http2.FrameHeader
	payload []u8
}

fn split_frames(buf []u8) []TestFrame {
	mut out := []TestFrame{}
	mut pos := 0
	for pos + 9 <= buf.len {
		fh := http2.parse_frame_header(buf[pos..]) or { panic(err) }
		total := 9 + int(fh.length)
		assert pos + total <= buf.len
		out << TestFrame{
			fh:      fh
			payload: buf[pos + 9..pos + total]
		}
		pos += total
	}
	assert pos == buf.len
	return out
}

fn hf(name string, value string) http2.HeaderField {
	return http2.HeaderField{
		name:  name
		value: value
	}
}

// bridge_step feeds one burst to the takeover ConnHandler over `conn`.
fn bridge_step(mut conn http2.ServerConn, input []u8) (int, core.Step, []u8) {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	consumed, step := http2_takeover_conn(input, mut out, -1, voidptr(conn), unsafe { nil }, mut
		event_loop)
	return consumed, step, out
}

fn get_block(path_idx int) []u8 {
	mut block := []u8{}
	http2.encode_indexed(mut block, 2) // :method GET
	http2.encode_indexed(mut block, 6) // :scheme http
	http2.encode_indexed(mut block, path_idx) // 4 = /
	http2.encode_literal_name_idx(mut block, 1, 'x.test')
	return block
}

fn test_http2_get_bridges_to_the_h1_handler() ! {
	mut conn := http2.new_server_conn()
	mut input := []u8{}
	input << http2.preface_tail
	http2.write_settings(mut input, [])
	block := get_block(4)
	http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
		1, block.len)
	input << block
	consumed, step, out := bridge_step(mut conn, input)
	assert consumed == input.len
	assert step == .done
	frames := split_frames(out)
	// SETTINGS ack, then the response: HEADERS + DATA.
	assert frames.len == 3
	assert frames[0].fh.type_ == .settings
	assert frames[0].fh.flags & http2.flag_ack != 0
	assert frames[1].fh.type_ == .headers
	assert frames[1].fh.flags & http2.flag_end_headers != 0
	assert frames[1].fh.flags & http2.flag_end_stream == 0
	mut dec := http2.new_decoder(http2.hpack_default_table_size)
	fields := dec.decode(frames[1].payload)!
	assert fields[0] == hf(':status', '200')
	assert hf('content-type', 'text/plain') in fields
	assert hf('content-length', '23') in fields
	// Connection-specific h1 fields must not leak into http2 framing.
	for f in fields {
		assert f.name != 'connection'
	}
	assert frames[2].fh.type_ == .data
	assert frames[2].fh.flags & http2.flag_end_stream != 0
	assert frames[2].payload.bytestr() == 'hello over one handler\n'
}

fn test_http2_post_echo_with_body() ! {
	mut conn := http2.new_server_conn()
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	_, step0, _ := bridge_step(mut conn, handshake)
	assert step0 == .done
	mut block := []u8{}
	http2.encode_indexed(mut block, 3) // :method POST
	http2.encode_indexed(mut block, 6)
	http2.encode_literal_name_idx(mut block, 4, '/echo')
	http2.encode_literal_name_idx(mut block, 1, 'x.test')
	mut input := []u8{}
	http2.write_frame_header(mut input, .headers, http2.flag_end_headers, 1, block.len)
	input << block
	http2.write_data_header(mut input, 1, 4, true)
	input << 'ping'.bytes()
	consumed, step, out := bridge_step(mut conn, input)
	assert consumed == input.len
	assert step == .done
	frames := split_frames(out)
	// WINDOW_UPDATE (connection) for the DATA, then HEADERS + DATA back.
	assert frames[0].fh.type_ == .window_update
	assert frames[0].fh.stream_id == 0
	assert frames[1].fh.type_ == .headers
	mut dec := http2.new_decoder(http2.hpack_default_table_size)
	fields := dec.decode(frames[1].payload)!
	assert fields[0] == hf(':status', '200')
	assert hf('content-length', '4') in fields
	assert frames[2].fh.type_ == .data
	assert frames[2].payload.bytestr() == 'ping'
	assert frames[2].fh.flags & http2.flag_end_stream != 0
}

fn test_http2_goaway_closes_the_connection() {
	mut conn := http2.new_server_conn()
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	_, step0, _ := bridge_step(mut conn, handshake)
	assert step0 == .done
	mut input := []u8{}
	http2.write_goaway(mut input, 0, .no_error)
	consumed, step, _ := bridge_step(mut conn, input)
	assert consumed == input.len
	assert step == .close
}

fn test_http2_partial_frame_consumes_nothing() {
	mut conn := http2.new_server_conn()
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	c0, s0, _ := bridge_step(mut conn, handshake)
	assert c0 == handshake.len
	assert s0 == .done
	block := get_block(4)
	mut whole := []u8{}
	http2.write_frame_header(mut whole, .headers, http2.flag_end_headers | http2.flag_end_stream,
		1, block.len)
	whole << block
	consumed, step, out := bridge_step(mut conn, whole[..whole.len - 2])
	assert consumed == 0
	assert step == .done
	assert out.len == 0
	consumed2, step2, out2 := bridge_step(mut conn, whole)
	assert consumed2 == whole.len
	assert step2 == .done
	assert split_frames(out2).len == 2 // HEADERS + DATA
}
