module main

// End-to-end proof of the conn-mode seam (issue #136) through a real epoll
// worker, on vtest: the same connection speaks HTTP/1.1 (the upgrade
// request), then RFC 6455 frames — including the seam's trickiest ordering,
// frames pipelined in the SAME segment as the upgrade request. Raw bytes in
// scripts, until-predicates over raw bytes out (WebSocket frames are not
// Content-Length-framed, so `want` counting never applies here).
// Linux-only invocation: the takeover seam is epoll-first.
import server
import vtest

const hs = 'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'.bytes()

// The RFC 6455 §1.3 accept value for the key above — seeing it in the 101
// asserts the whole handshake end-to-end.
const rfc_accept = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='

// masked_frame builds a client frame (test scaffolding — clients mask).
fn masked_frame(opcode u8, payload string) []u8 {
	key := [u8(0x37), 0xfa, 0x21, 0x3d]
	mut f := []u8{cap: 6 + payload.len}
	f << (u8(0x80) | opcode)
	f << u8(0x80 | payload.len) // test payloads are always < 126
	f << key
	for i, c in payload.bytes() {
		f << (c ^ key[i & 3])
	}
	return f
}

fn index_bytes(acc []u8, needle []u8) int {
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

// until_bytes packages "this exact byte sequence arrived" as a Round predicate.
fn until_bytes(needle []u8) fn (acc []u8) bool {
	return fn [needle] (acc []u8) bool {
		return index_bytes(acc, needle) >= 0
	}
}

// hs_with_pipelined_frame is the seam's ordering probe: the upgrade request
// and a websocket frame in ONE client write.
fn hs_with_pipelined_frame() []u8 {
	mut b := []u8{cap: hs.len + 16}
	b << hs
	b << masked_frame(0x1, 'pipelined')
	return b
}

// Server close frames the demo sends: normal (1000) and protocol-error (1002).
const close_normal_frame = [u8(0x88), 0x02, 0x03, 0xe8]
const close_protocol_frame = [u8(0x88), 0x02, 0x03, 0xea]

fn test_websocket_echo_end_to_end() {
	$if linux {
		out := vtest.drive(server.ServerConfig{
			io_multiplexing: .epoll
			handler:         handle
		}, [
			// Conn 0 — the full choreography, one round per protocol step:
			// handshake -> echo -> ping/pong -> close handshake -> server EOF.
			vtest.Script{
				rounds:   [
					vtest.Round{
						send:  hs
						until: vtest.count(rfc_accept, 1)
					},
					vtest.Round{
						send:  masked_frame(0x1, 'hello over the seam')
						until: until_bytes([u8(0x81), 0x13]) // unmasked echo header, len 19
					},
					vtest.Round{
						send:  masked_frame(0x9, 'ka')
						until: until_bytes([u8(0x8a), 0x02, `k`, `a`]) // the pong
					},
					vtest.Round{
						send:  masked_frame(0x8, '\x03\xe8') // close, code 1000
						until: until_bytes(close_normal_frame)
					},
				]
				then_eof: true
			},
			// Conn 1 — handshake AND a frame in ONE write: the frame bytes sit
			// behind the upgrade request in the same segment, so they MUST be
			// consumed by the takeover drain, not the HTTP parser (the seam's
			// ordering rule).
			vtest.Script{
				rounds: [
					vtest.Round{
						send:  hs_with_pipelined_frame()
						until: until_bytes([u8(0x81), 0x09, `p`, `i`, `p`, `e`, `l`, `i`, `n`,
							`e`, `d`])
					},
				]
			},
			// Conn 2 — an UNMASKED client frame after the handshake: the server
			// must fail the connection (close 1002 + EOF), RFC 6455 §5.1.
			vtest.Script{
				rounds:   [
					vtest.Round{
						send:  hs
						until: vtest.count(rfc_accept, 1)
					},
					vtest.Round{
						send:  [u8(0x81), 0x02, `h`, `i`] // unmasked — a violation
						until: until_bytes(close_protocol_frame)
					},
				]
				then_eof: true
			},
		]) or {
			assert false, err.msg()
			return
		}
		full := out.conns[0]
		assert full.connect_err == '', full.connect_err
		assert !full.unmet, 'choreography ended early: ${full.raw.bytestr()}'
		assert full.eof, 'server must close after the close handshake'
		echoed := index_bytes(full.raw, 'hello over the seam'.bytes())
		assert echoed >= 0, 'echo payload missing'

		pipelined := out.conns[1]
		assert pipelined.connect_err == '', pipelined.connect_err
		assert !pipelined.unmet, 'pipelined-behind-upgrade frame lost: ${pipelined.raw.bytestr()}'

		violated := out.conns[2]
		assert violated.connect_err == '', violated.connect_err
		assert !violated.unmet
		assert violated.eof, 'an unmasked client frame must end the connection'
		assert out.inflight_after == 0
	}
}
