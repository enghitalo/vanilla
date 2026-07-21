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

fn test_non_http1x_version_gets_goaway_and_close() {
	// A garbled http2 preface parses as an h1 request with a non-HTTP/1.x
	// version — answer in the protocol the peer attempted: a
	// GOAWAY(PROTOCOL_ERROR) frame, then drop the connection (RFC 9113 §3.5).
	mut res := []u8{}
	mut event_loop := core.EventLoop{}
	step := handle('INVALID CONNECTION PREFACE\r\n\r\n'.bytes(), mut res, -1, unsafe { nil }, mut
		event_loop)
	assert step == .close
	frames := split_frames(res)
	assert frames.len == 1
	assert frames[0].fh.type_ == .goaway
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

// bridge_step feeds one burst to the takeover ConnHandler over `bridge`.
fn bridge_step(mut bridge BridgeState, input []u8) (int, core.Step, []u8) {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	consumed, step := http2_takeover_conn(input, mut out, -1, voidptr(&bridge), unsafe { nil }, mut
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
	mut bridge := &BridgeState{
		conn: http2.new_server_conn()
	}
	mut input := []u8{}
	input << http2.preface_tail
	http2.write_settings(mut input, [])
	block := get_block(4)
	http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
		1, block.len)
	input << block
	consumed, step, out := bridge_step(mut bridge, input)
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
	mut bridge := &BridgeState{
		conn: http2.new_server_conn()
	}
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	_, step0, _ := bridge_step(mut bridge, handshake)
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
	consumed, step, out := bridge_step(mut bridge, input)
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

fn test_http2_goaway_keeps_the_connection_serving() {
	mut bridge := &BridgeState{
		conn: http2.new_server_conn()
	}
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	_, step0, _ := bridge_step(mut bridge, handshake)
	assert step0 == .done
	// A peer GOAWAY does not close the connection — the peer does. The
	// bridge keeps serving (a PING after it still gets an ack).
	mut input := []u8{}
	http2.write_goaway(mut input, 0, .no_error)
	http2.write_frame_header(mut input, .ping, 0, 0, 8)
	input << [u8(1), 2, 3, 4, 5, 6, 7, 8]
	consumed, step, out := bridge_step(mut bridge, input)
	assert consumed == input.len
	assert step == .done
	frames := split_frames(out)
	assert frames.len == 1
	assert frames[0].fh.type_ == .ping
	assert frames[0].fh.flags & http2.flag_ack != 0
}

fn get_block_path(path string) []u8 {
	mut block := []u8{}
	http2.encode_indexed(mut block, 2) // :method GET
	http2.encode_indexed(mut block, 6) // :scheme http
	http2.encode_literal_name_idx(mut block, 4, path)
	http2.encode_literal_name_idx(mut block, 1, 'x.test')
	return block
}

fn test_bridge_parks_and_resumes_async_stream() ! {
	$if linux {
		mut bridge := &BridgeState{
			conn: http2.new_server_conn()
		}
		mut handshake := []u8{}
		handshake << http2.preface_tail
		http2.write_settings(mut handshake, [])
		_, s0, _ := bridge_step(mut bridge, handshake)
		assert s0 == .done
		// One burst, two streams: /slow parks on a timerfd, / answers now.
		slow_block := get_block_path('/slow')
		home_block := get_block(4)
		mut input := []u8{}
		http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
			1, slow_block.len)
		input << slow_block
		http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
			3, home_block.len)
		input << home_block
		// Engine-loop stand-in: capture what the bridge arms for the park.
		mut engine_capture := WatchCapture{}
		mut el := core.EventLoop{
			client_fd: -1
			reactor:   unsafe { voidptr(&engine_capture) }
			register:  capture_register
		}
		mut out := []u8{}
		consumed, step := http2_takeover_conn(input, mut out, -1, voidptr(bridge), unsafe { nil }, mut
			el)
		assert consumed == input.len
		assert step == .suspend
		assert bridge.parked
		assert engine_capture.fd >= 0 // the app's real timerfd, re-armed by the bridge
		assert el.last_watched == engine_capture.fd
		// Stream 3 answered immediately; stream 1 has nothing yet.
		frames := split_frames(out)
		mut saw_home := false
		for f in frames {
			assert f.fh.stream_id != 1
			if f.fh.type_ == .data && f.fh.stream_id == 3 {
				assert f.payload.bytestr() == 'hello over one handler\n'
				saw_home = true
			}
		}
		assert saw_home
		// The timer "fires": run the continuation the engine would run.
		mut resume_capture := WatchCapture{}
		mut el2 := core.EventLoop{
			client_fd: -1
			reactor:   unsafe { voidptr(&resume_capture) }
			register:  capture_register
		}
		mut out2 := []u8{}
		rstep := engine_capture.cont(mut out2, engine_capture.fd, false, engine_capture.udata,
			unsafe { nil }, mut el2)
		assert rstep == .done
		assert !bridge.parked
		frames2 := split_frames(out2)
		assert frames2.len == 2
		assert frames2[0].fh.type_ == .headers
		assert frames2[0].fh.stream_id == 1
		mut dec := http2.new_decoder(http2.hpack_default_table_size)
		fields := dec.decode(frames2[0].payload)!
		assert fields[0] == hf(':status', '200')
		assert frames2[1].fh.type_ == .data
		assert frames2[1].fh.stream_id == 1
		assert frames2[1].fh.flags & http2.flag_end_stream != 0
		assert frames2[1].payload.bytestr() == 'slow done\n'
	}
}

fn test_second_parker_is_refused_with_rst() {
	$if linux {
		mut bridge := &BridgeState{
			conn: http2.new_server_conn()
		}
		mut handshake := []u8{}
		handshake << http2.preface_tail
		http2.write_settings(mut handshake, [])
		_, s0, _ := bridge_step(mut bridge, handshake)
		assert s0 == .done
		// TWO /slow streams in one burst: the first parks, the second is
		// refused (one armed watch per parked connection — engine contract).
		slow1 := get_block_path('/slow')
		slow3 := get_block_path('/slow')
		mut input := []u8{}
		http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
			1, slow1.len)
		input << slow1
		http2.write_frame_header(mut input, .headers, http2.flag_end_headers | http2.flag_end_stream,
			3, slow3.len)
		input << slow3
		mut engine_capture := WatchCapture{}
		mut el := core.EventLoop{
			client_fd: -1
			reactor:   unsafe { voidptr(&engine_capture) }
			register:  capture_register
		}
		mut out := []u8{}
		consumed, step := http2_takeover_conn(input, mut out, -1, voidptr(bridge), unsafe { nil }, mut
			el)
		assert consumed == input.len
		assert step == .suspend
		frames := split_frames(out)
		mut saw_rst := false
		for f in frames {
			if f.fh.type_ == .rst_stream && f.fh.stream_id == 3 {
				assert f.payload == [u8(0), 0, 0, 7] // REFUSED_STREAM
				saw_rst = true
			}
		}
		assert saw_rst
		// The parked stream still completes.
		mut resume_capture := WatchCapture{}
		mut el2 := core.EventLoop{
			client_fd: -1
			reactor:   unsafe { voidptr(&resume_capture) }
			register:  capture_register
		}
		mut out2 := []u8{}
		rstep := engine_capture.cont(mut out2, engine_capture.fd, false, engine_capture.udata,
			unsafe { nil }, mut el2)
		assert rstep == .done
		frames2 := split_frames(out2)
		assert frames2.len == 2
		assert frames2[1].payload.bytestr() == 'slow done\n'
	}
}

fn test_http2_partial_frame_consumes_nothing() {
	mut bridge := &BridgeState{
		conn: http2.new_server_conn()
	}
	mut handshake := []u8{}
	handshake << http2.preface_tail
	http2.write_settings(mut handshake, [])
	c0, s0, _ := bridge_step(mut bridge, handshake)
	assert c0 == handshake.len
	assert s0 == .done
	block := get_block(4)
	mut whole := []u8{}
	http2.write_frame_header(mut whole, .headers, http2.flag_end_headers | http2.flag_end_stream,
		1, block.len)
	whole << block
	consumed, step, out := bridge_step(mut bridge, whole[..whole.len - 2])
	assert consumed == 0
	assert step == .done
	assert out.len == 0
	consumed2, step2, out2 := bridge_step(mut bridge, whole)
	assert consumed2 == whole.len
	assert step2 == .done
	assert split_frames(out2).len == 2 // HEADERS + DATA
}
