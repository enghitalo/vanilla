module main

import core
import websocket

// Both halves of the example are pure functions, so both are unit-testable
// with raw bytes and no sockets: `handle` (the HTTP side — routing, upgrade
// validation, the 501 fallback when no takeover-capable worker runs) and
// `ws_echo_conn` (the post-upgrade ConnHandler — echo, ping/pong, close,
// partial-frame and protocol-violation behaviour). The full upgrade hand-off
// through a real epoll worker is covered in server_end_to_end_test.v.

fn serve(req string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	return out.bytestr()
}

fn test_routes() {
	assert serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n').contains('200 OK')
	assert serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n').contains('404')
	assert serve('POST /ws HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n').contains('404')
}

fn test_upgrade_needs_wellformed_handshake() {
	// No Upgrade header / no key -> 400, connection closed.
	assert serve('GET /ws HTTP/1.1\r\nHost: x\r\n\r\n').contains('400')
	assert serve('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n').contains('400')
	assert serve('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: h2c\r\nSec-WebSocket-Key: aaaa\r\n\r\n').contains('400')
}

fn test_upgrade_without_capable_worker_is_501() {
	// This test binary never calls core.enable_takeover(), so queue_takeover
	// reports false — exactly the situation on a non-epoll backend. The
	// handler must answer an explicit 501, never a dead 101.
	got :=
		serve('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n')
	assert got.contains('501'), got
	assert !got.contains('101'), 'must not promise an upgrade nobody will serve: ${got}'
}

// --- ws_echo_conn (the post-upgrade ConnHandler) ---------------------------

fn echo_step(frame []u8) (int, core.Step, []u8) {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	mut buf := frame.clone() // the handler unmasks in place
	consumed, step := ws_echo_conn(buf, mut out, -1, unsafe { nil }, unsafe { nil }, mut event_loop)
	return consumed, step, out
}

// RFC 6455 §5.7's masked "Hello" text frame.
const rfc_hello_masked = [u8(0x81), 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]

fn test_echo_text_frame() {
	consumed, step, out := echo_step(rfc_hello_masked)
	assert consumed == rfc_hello_masked.len
	assert step == .done
	// Echo comes back as an UNMASKED server frame: 0x81 0x05 "Hello".
	assert out == [u8(0x81), 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
}

fn test_two_frames_one_burst_and_partial_tail() {
	mut buf := rfc_hello_masked.clone()
	buf << rfc_hello_masked
	buf << rfc_hello_masked[..4] // a partial third frame stays unconsumed
	consumed, step, out := echo_step(buf)
	assert consumed == 2 * rfc_hello_masked.len
	assert step == .done
	assert out.len == 2 * 7
}

fn test_ping_answered_with_pong() {
	// Masked ping carrying "ka": pong must echo the payload (RFC 6455 §5.5.3).
	key := [u8(0x11), 0x22, 0x33, 0x44]
	mut ping := [u8(0x89), 0x82]
	ping << key
	ping << [u8(`k`) ^ key[0], u8(`a`) ^ key[1]]
	consumed, step, out := echo_step(ping)
	assert consumed == ping.len
	assert step == .done
	assert out == [u8(0x8a), 0x02, `k`, `a`]
}

fn test_close_handshake() {
	// Masked close frame (code 1000) -> close reply + .close.
	key := [u8(0x01), 0x02, 0x03, 0x04]
	mut close_frame := [u8(0x88), 0x82]
	close_frame << key
	close_frame << [u8(0x03) ^ key[0], u8(0xe8) ^ key[1]]
	consumed, step, out := echo_step(close_frame)
	assert consumed == close_frame.len
	assert step == .close
	assert out == [u8(0x88), 0x02, 0x03, 0xe8]
}

fn test_unmasked_client_frame_fails_connection() {
	// RFC 6455 §5.1: server MUST fail the connection on an unmasked frame.
	consumed, step, out := echo_step([u8(0x81), 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
	assert consumed == 0
	assert step == .close
	h := websocket.frame_head(out)
	assert h.opcode == websocket.op_close
	assert int(out[h.payload_off]) << 8 | int(out[h.payload_off + 1]) == 1002
}

fn test_partial_frame_consumes_nothing() {
	consumed, step, out := echo_step(rfc_hello_masked[..3])
	assert consumed == 0
	assert step == .done
	assert out.len == 0
}

fn test_fragmented_message_rejected_by_demo() {
	// fin=0 text frame: the demo answers close 1003 (whole-message echo only).
	key := [u8(0x0a), 0x0b, 0x0c, 0x0d]
	mut frag := [u8(0x01), 0x81]
	frag << key
	frag << [u8(`x`) ^ key[0]]
	_, step, out := echo_step(frag)
	assert step == .close
	h := websocket.frame_head(out)
	assert h.opcode == websocket.op_close
	assert int(out[h.payload_off]) << 8 | int(out[h.payload_off + 1]) == 1003
}
