module main

// The chat end to end on the epoll plain worker (vanilla#230), with raw
// WebSocket clients: two members on different workers talk both ways; the
// keepalive pings through wake_after and closes a peer that never answers
// (1001); a member that leaves is gone from the room (.closed), and a message
// sent after that reaches only those still there. Takeover is inert under
// tcc (#173): these run with gcc / clang.
import time
import transport
import vtest

#include <sys/socket.h>

fn C.recv(fd int, buf voidptr, len usize, flags int) int

// WsClient is a raw WebSocket client: it masks what it sends and parses the
// server's (unmasked) frames out of what it reads.
struct WsClient {
	fd int
mut:
	acc []u8
}

struct WsFrame {
	opcode  u8
	payload string
}

fn ws_connect(port int, name string) !WsClient {
	fd := transport.dial_tcp('127.0.0.1', port)!
	mut c := WsClient{
		fd: fd
	}
	c.send_raw(('GET /chat?name=' + name +
		' HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n').bytes())!
	for !c.acc.bytestr().contains('\r\n\r\n') {
		if !c.fill(3000) {
			return error('no handshake answer: ${c.acc.bytestr()}')
		}
	}
	head := c.acc.bytestr().all_before('\r\n\r\n')
	if !head.starts_with('HTTP/1.1 101') {
		return error('not upgraded: ${head}')
	}
	rest := c.acc[head.len + 4..].clone()
	c.acc = rest
	return c
}

fn (mut c WsClient) send_raw(b []u8) ! {
	mut off := 0
	for _ in 0 .. 3000 {
		n := C.send(c.fd, &b[off], usize(b.len - off), C.MSG_NOSIGNAL)
		if n > 0 {
			off += n
			if off == b.len {
				return
			}
			continue
		}
		time.sleep(time.millisecond) // still connecting
	}
	return error('send failed')
}

// send masks and sends one frame (payloads < 126 bytes here).
fn (mut c WsClient) send(opcode u8, payload string) ! {
	key := [u8(0x12), 0x34, 0x56, 0x78]
	mut f := []u8{cap: 6 + payload.len}
	f << (u8(0x80) | opcode)
	f << u8(0x80 | payload.len)
	f << key
	for i, b in payload.bytes() {
		f << (b ^ key[i & 3])
	}
	c.send_raw(f)!
}

// fill reads what is there, waiting up to ms for something: false on EOF or
// when nothing came.
fn (mut c WsClient) fill(ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for time.sys_mono_now() < deadline {
		n := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			return true
		}
		if n == 0 {
			return false
		}
		time.sleep(time.millisecond)
	}
	return false
}

// next returns the next whole server frame, waiting up to ms.
fn (mut c WsClient) next(ms int) ?WsFrame {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	for {
		if c.acc.len >= 2 {
			len7 := int(c.acc[1] & 0x7f)
			mut off := 2
			mut n := len7
			if len7 == 126 && c.acc.len >= 4 {
				n = int(c.acc[2]) << 8 | int(c.acc[3])
				off = 4
			}
			if len7 != 126 || c.acc.len >= 4 {
				if c.acc.len >= off + n {
					f := WsFrame{
						opcode:  c.acc[0] & 0x0f
						payload: c.acc[off..off + n].bytestr()
					}
					c.acc = c.acc[off + n..].clone()
					return f
				}
			}
		}
		left := i64(deadline) - i64(time.sys_mono_now())
		if left <= 0 || !c.fill(int(left / 1_000_000) + 1) {
			return none
		}
	}
	return none
}

// text_until returns the next text frame, answering pings meanwhile.
fn (mut c WsClient) text_until(ms int) ?string {
	for {
		f := c.next(ms)?
		if f.opcode == 0x9 {
			c.send(0xa, f.payload) or { return none }
			continue
		}
		if f.opcode == 0x1 {
			return f.payload
		}
	}
	return none
}

fn (mut c WsClient) close() {
	transport.close_fd(c.fd)
}

// ws_join connects and reads the welcome: the client and its worker.
fn ws_join(port int, name string) !(WsClient, string) {
	mut c := ws_connect(port, name)!
	welcome := c.text_until(3000) or { return error('no welcome') }
	if !welcome.starts_with('joined, worker ') {
		return error('unexpected welcome: ${welcome}')
	}
	return c, welcome.all_after('worker ')
}

fn test_chat_between_workers() ! {
	$if tinyc {
		eprintln('[test] takeover is inert under tcc; skipping')
		return
	}
	cfg := new_config(0, 2, 60_000, &Room{})
	mut h := vtest.start(cfg)!
	defer {
		h.stop()
	}
	mut ana, ana_worker := ws_join(h.port(), 'ana')!
	defer {
		ana.close()
	}
	// Accept round-robins: the next connections alternate workers.
	mut bo, bo_worker := ws_join(h.port(), 'bo')!
	mut extra := []WsClient{}
	for bo_worker == ana_worker && extra.len < 3 {
		extra << bo
		bo, bo_worker = ws_join(h.port(), 'bo')!
	}
	defer {
		bo.close()
		for mut x in extra {
			x.close()
		}
	}
	assert bo_worker != ana_worker, 'both members on worker ${ana_worker}'
	ana.send(0x1, 'hi bo')!
	assert bo.text_until(3000)? == 'ana: hi bo'
	assert ana.text_until(3000)? == 'ana: hi bo' // the sender sees the room's copy
	bo.send(0x1, 'hello ana')!
	assert ana.text_until(3000)? == 'bo: hello ana'
	// Pings are answered by the server; the connections keep reading.
	ana.send(0x9, 'ka')!
	f := ana.next(3000)?
	assert f.opcode == 0xa && f.payload == 'ka'
}

fn test_chat_member_that_leaves_is_dropped() ! {
	$if tinyc {
		return
	}
	mut room := &Room{}
	cfg := new_config(0, 1, 60_000, room)
	mut h := vtest.start(cfg)!
	defer {
		h.stop()
	}
	mut ana, _ := ws_join(h.port(), 'ana')!
	defer {
		ana.close()
	}
	mut bo, _ := ws_join(h.port(), 'bo')!
	assert room.size() == 2
	bo.send(0x8, '\x03\xe8')! // close 1000
	f := bo.next(3000)?
	assert f.opcode == 0x8
	bo.close()
	// bo's .closed takes it out of the room.
	for _ in 0 .. 3000 {
		if room.size() == 1 {
			break
		}
		time.sleep(time.millisecond)
	}
	assert room.size() == 1, 'the member that left is still in the room'
	ana.send(0x1, 'anyone?')!
	assert ana.text_until(3000)? == 'ana: anyone?'
	// A member who joins later gets what is sent after.
	mut cl, _ := ws_join(h.port(), 'cl')!
	defer {
		cl.close()
	}
	ana.send(0x1, 'cl, hi')!
	assert cl.text_until(3000)? == 'ana: cl, hi'
}

fn test_chat_keepalive_closes_a_silent_peer() ! {
	$if tinyc {
		return
	}
	mut room := &Room{}
	cfg := new_config(0, 1, 200, room)
	mut h := vtest.start(cfg)!
	defer {
		h.stop()
	}
	mut quiet, _ := ws_join(h.port(), 'quiet')!
	defer {
		quiet.close()
	}
	sw := time.new_stopwatch()
	ping := quiet.next(3000)?
	assert ping.opcode == 0x9, 'no keepalive ping'
	// Not answered: at the next interval the server says goodbye (1001).
	bye := quiet.next(3000)?
	assert bye.opcode == 0x8 && bye.payload.bytes() == [u8(0x03), 0xe9]
	assert !quiet.fill(2000), 'not closed after the goodbye'
	took := sw.elapsed().milliseconds()
	assert took >= 300 && took < 3000, 'closed after ${took} ms'
	for _ in 0 .. 3000 {
		if room.size() == 0 {
			break
		}
		time.sleep(time.millisecond)
	}
	assert room.size() == 0, 'the reaped peer is still in the room'
	// A peer that answers stays.
	mut live, _ := ws_join(h.port(), 'live')!
	defer {
		live.close()
	}
	for _ in 0 .. 3 {
		p := live.next(3000)?
		assert p.opcode == 0x9
		live.send(0xa, p.payload)!
	}
	live.send(0x1, 'still here')!
	assert live.text_until(3000)? == 'live: still here'
}
