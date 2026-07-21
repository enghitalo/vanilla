module main

// End-to-end proof of http2-over-the-seam through a real epoll worker, on
// vtest: the client preface flips the connection, SETTINGS are exchanged,
// and requests round-trip through the SAME handler that serves the h1
// connection in the same run. Raw bytes in scripts, until-predicates over
// raw bytes out (http2 responses are frame-framed, so `want` counting never
// applies). Linux-only invocation: the takeover seam is epoll-first.
import http2
import server
import vtest

const e2e_home_body = 'hello over one handler\n'.bytes()
const e2e_slow_body = 'slow done\n'.bytes()

fn e2e_index_bytes(acc []u8, needle []u8) int {
	if needle.len == 0 || acc.len < needle.len {
		return -1
	}
	for i := 0; i <= acc.len - needle.len; i++ {
		mut hit := true
		for j in 0 .. needle.len {
			if acc[i + j] != needle[j] {
				hit = false
				break
			}
		}
		if hit {
			return i
		}
	}
	return -1
}

// e2e_until_bytes packages "this exact byte sequence arrived" as a predicate.
fn e2e_until_bytes(needle []u8) fn (acc []u8) bool {
	return fn [needle] (acc []u8) bool {
		return e2e_index_bytes(acc, needle) >= 0
	}
}

// e2e_get_opening is the whole client opening in ONE write — preface, empty
// SETTINGS, and a GET / that ends the stream — the seam's trickiest ordering
// (frames pipelined behind the preface request in the same segment).
fn e2e_get_opening() []u8 {
	mut b := []u8{}
	b << http2.preface
	http2.write_settings(mut b, [])
	mut block := []u8{}
	http2.encode_indexed(mut block, 2) // :method GET
	http2.encode_indexed(mut block, 6) // :scheme http
	http2.encode_indexed(mut block, 4) // :path /
	http2.encode_literal_name_idx(mut block, 1, 'x.test')
	http2.write_frame_header(mut b, .headers, http2.flag_end_headers | http2.flag_end_stream, 1,
		block.len)
	b << block
	return b
}

fn e2e_post_echo(stream_id u32, payload string) []u8 {
	mut b := []u8{}
	mut block := []u8{}
	http2.encode_indexed(mut block, 3) // :method POST
	http2.encode_indexed(mut block, 6)
	http2.encode_literal_name_idx(mut block, 4, '/echo')
	http2.encode_literal_name_idx(mut block, 1, 'x.test')
	http2.write_frame_header(mut b, .headers, http2.flag_end_headers, stream_id, block.len)
	b << block
	http2.write_data_header(mut b, stream_id, payload.len, true)
	b << payload.bytes()
	return b
}

// e2e_async_opening: preface + SETTINGS + GET /slow (stream 1, parks on a
// timerfd) + GET / (stream 3, answers immediately) — all in ONE write.
fn e2e_async_opening() []u8 {
	mut b := []u8{}
	b << http2.preface
	http2.write_settings(mut b, [])
	mut slow_block := []u8{}
	http2.encode_indexed(mut slow_block, 2)
	http2.encode_indexed(mut slow_block, 6)
	http2.encode_literal_name_idx(mut slow_block, 4, '/slow')
	http2.encode_literal_name_idx(mut slow_block, 1, 'x.test')
	http2.write_frame_header(mut b, .headers, http2.flag_end_headers | http2.flag_end_stream, 1,
		slow_block.len)
	b << slow_block
	mut home_block := []u8{}
	http2.encode_indexed(mut home_block, 2)
	http2.encode_indexed(mut home_block, 6)
	http2.encode_indexed(mut home_block, 4)
	http2.encode_literal_name_idx(mut home_block, 1, 'x.test')
	http2.write_frame_header(mut b, .headers, http2.flag_end_headers | http2.flag_end_stream, 3,
		home_block.len)
	b << home_block
	return b
}

fn e2e_ping() []u8 {
	mut b := []u8{}
	http2.write_frame_header(mut b, .ping, 0, 0, 8)
	b << [u8(0xca), 0xfe, 0xba, 0xbe, 0x00, 0x11, 0x22, 0x33]
	return b
}

// e2e_ping_ack is the exact PING ack the server must send back: same opaque
// payload, ACK flag set.
fn e2e_ping_ack() []u8 {
	mut b := []u8{}
	http2.write_frame_header(mut b, .ping, http2.flag_ack, 0, 8)
	b << [u8(0xca), 0xfe, 0xba, 0xbe, 0x00, 0x11, 0x22, 0x33]
	return b
}

fn test_http2_cleartext_end_to_end() {
	$if linux {
		out := vtest.drive(server.ServerConfig{
			io_multiplexing: .epoll
			handler:         handle
		}, [
			// Conn 0 — the full choreography on one connection: opening burst
			// (preface + SETTINGS + GET pipelined), a second request, then a
			// PING. The client closes the connection at script end (a peer
			// GOAWAY would not close it — §6.8 — the engine reaps our EOF).
			vtest.Script{
				rounds: [
					vtest.Round{
						send:  e2e_get_opening()
						until: e2e_until_bytes(e2e_home_body)
					},
					vtest.Round{
						send:  e2e_post_echo(3, 'ping-pong-payload')
						until: e2e_until_bytes('ping-pong-payload'.bytes())
					},
					vtest.Round{
						send:  e2e_ping()
						until: e2e_until_bytes(e2e_ping_ack())
					},
				]
			},
			// Conn 1 — plain HTTP/1.1 on the same port, same handler: the
			// protocols coexist per connection, not per server.
			vtest.Script{
				rounds: [
					vtest.Round{
						send:  'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
						until: e2e_until_bytes(e2e_home_body)
					},
				]
			},
			// Conn 2 — ASYNC over http2 (the .suspend-over-the-seam follow-up
			// of issue #136): /slow parks stream 1 on a timerfd while / on
			// stream 3 answers immediately; the parked stream completes when
			// the timer fires and resumes the connection.
			vtest.Script{
				rounds: [
					vtest.Round{
						send:  e2e_async_opening()
						until: e2e_until_bytes(e2e_slow_body)
					},
				]
			},
			// Conn 3 — the SAME async route over plain h1: the engine parks
			// the request (pre-existing machinery, proven undisturbed).
			vtest.Script{
				rounds: [
					vtest.Round{
						send:  'GET /slow HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
						until: e2e_until_bytes(e2e_slow_body)
					},
				]
			},
		]) or {
			assert false, err.msg()
			return
		}
		full := out.conns[0]
		assert full.connect_err == '', full.connect_err
		assert !full.unmet, 'choreography ended early: ${full.raw.bytestr()}'
		// The server preface (a SETTINGS frame) must be the very first bytes.
		assert full.raw.len >= 9
		assert full.raw[3] == u8(0x04), 'first frame must be SETTINGS'
		assert e2e_index_bytes(full.raw, e2e_home_body) >= 0

		h1 := out.conns[1]
		assert h1.connect_err == '', h1.connect_err
		assert !h1.unmet
		assert e2e_index_bytes(h1.raw, 'HTTP/1.1 200 OK'.bytes()) >= 0

		async := out.conns[2]
		assert async.connect_err == '', async.connect_err
		assert !async.unmet, 'async choreography ended early: ${async.raw.bytestr()}'
		home_at := e2e_index_bytes(async.raw, e2e_home_body)
		slow_at := e2e_index_bytes(async.raw, e2e_slow_body)
		assert home_at >= 0
		// The ready stream must not wait behind the parked one: / answers in
		// microseconds, the timer holds /slow for 30 ms.
		assert slow_at > home_at, 'the parked stream blocked the ready one'

		h1slow := out.conns[3]
		assert h1slow.connect_err == '', h1slow.connect_err
		assert !h1slow.unmet, 'h1 /slow never resumed: ${h1slow.raw.bytestr()}'
	}
}
