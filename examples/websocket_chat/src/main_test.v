module main

import core
import http1_1.request_parser
import websocket

// The pure halves of the chat, with raw bytes and no sockets: the HTTP routes
// and the upgrade checks (`handle`), and the wake fn's frames (`chat_wake`).
// The chat itself, across workers, is server_end_to_end_test.v.

fn serve(req string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle(req.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	return out.bytestr()
}

fn test_routes() {
	home := serve('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	assert home.starts_with('HTTP/1.1 200 OK')
	assert home.all_after('\r\n\r\n').len == home.all_after('Content-Length: ').all_before('\r\n').int()
	assert serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n').contains('404')
}

fn test_upgrade_needs_a_wellformed_handshake() {
	assert serve('GET /chat HTTP/1.1\r\nHost: x\r\n\r\n').contains('400')
	assert serve('GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: h2c\r\nSec-WebSocket-Key: aaaa\r\n\r\n').contains('400')
}

fn test_query_name() {
	req := 'GET /chat?x=1&name=ana&y=2 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	assert query_name(req, request_parser.Slice{ start: 4, len: 22 }).bytestr() == 'ana'
	assert query_name(req, request_parser.Slice{ start: 4, len: 5 }).len == 0
}

// chat_wake turns a post into a text frame, its timer into a ping (and a
// second unanswered one into a 1001 close), and the shutdown into a 1001.
fn test_wake_frames() {
	mut room := &Room{}
	mut w := &Worker{
		room:    room
		ping_ms: 1000
	}
	mut st := &Chat{}
	msg := 'ana: hi'.bytes()
	mut el := core.EventLoop{
		reason:   .posted
		post_ptr: msg.data
		post_len: msg.len
	}
	mut out := []u8{}
	assert chat_wake(mut out, 3, false, voidptr(st), voidptr(w), mut el) == .done
	h := websocket.frame_head(out)
	assert h.opcode == websocket.op_text && out[h.payload_off..].bytestr() == 'ana: hi'

	mut tl := core.EventLoop{
		reason: .timeout
	}
	out.clear()
	assert chat_wake(mut out, 3, false, voidptr(st), voidptr(w), mut tl) == .done
	assert out == [u8(0x89), 0x00] // a ping
	assert st.pinging
	out.clear()
	assert chat_wake(mut out, 3, false, voidptr(st), voidptr(w), mut tl) == .close
	assert out == [u8(0x88), 0x02, 0x03, 0xe9] // no pong came: 1001

	mut sl := core.EventLoop{
		reason: .shutdown
	}
	out.clear()
	assert chat_wake(mut out, 3, false, voidptr(st), voidptr(w), mut sl) == .close
	assert out == [u8(0x88), 0x02, 0x03, 0xe9]
}
