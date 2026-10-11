module main

import core
import net

// SOLUTION: in-memory state test (denylist) + handler gate.
// The blocklist set is pure/in-memory, so block/unblock/is_blocked and the 403
// gate are unit-testable. The peer IP itself comes from the socket
// (socket.peer_ipv4): the handler tests below open a real loopback TCP
// connection, so the peer is 127.0.0.1. (`${}` here is test scaffolding.)

fn ip(s string) u32 {
	return parse_ipv4(s) or { panic('bad test address ${s}') }
}

fn test_block_unblock_roundtrip() ! {
	mut b := Blocklist{}
	assert !b.is_blocked(ip('1.2.3.4'))
	b.block('1.2.3.4')!
	assert b.is_blocked(ip('1.2.3.4'))
	assert !b.is_blocked(ip('1.2.3.5'))
	b.unblock('1.2.3.4')!
	assert !b.is_blocked(ip('1.2.3.4'))
}

fn test_block_rejects_what_is_not_ipv4() {
	mut b := Blocklist{}
	for bad in ['', 'localhost', '1.2.3', '256.0.0.1', '2001:db8::1'] {
		if _ := b.block(bad) {
			assert false, 'block must reject ${bad}'
		}
	}
	assert b.ips.len == 0
}

fn serve(fd int, mut b Blocklist) string {
	mut resp := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut resp, fd, unsafe { nil }, mut
		event_loop, mut b) == .done
	return resp.bytestr()
}

fn test_peer_without_ipv4_is_allowed() {
	mut b := Blocklist{}
	b.block('127.0.0.1') or { panic(err) }
	// fd -1 => socket.peer_ipv4 is none: on no IPv4 list => allowed.
	out := serve(-1, mut b)
	assert out.contains('200 OK')
	assert out.contains('allowed')
}

fn test_blocked_peer_gets_403_and_others_200() ! {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	mut b := Blocklist{}
	b.block('10.0.0.5')!
	assert serve(s.sock.handle, mut b).contains('200 OK') // 127.0.0.1 is not listed
	b.block('127.0.0.1')!
	assert serve(s.sock.handle, mut b).contains('403 Forbidden')
}

// Blocked and allowed peers both run 20k times through one reused buffer, as a
// worker serves them: the collector's allocation counter must not move. A
// blocked client must not be able to make the server allocate (or log) per
// request.
fn test_ip_block_allocates_nothing() ! {
	$if gcboehm ? {
		mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
		defer { l.close() or {} }
		mut c := net.dial_tcp(l.addr()!.str())!
		defer { c.close() or {} }
		mut s := l.accept()!
		defer { s.close() or {} }
		fd := s.sock.handle
		mut deny := Blocklist{}
		deny.block('127.0.0.1')!
		mut allow := Blocklist{}
		allow.block('10.0.0.5')!
		req := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut deny) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut allow)
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut deny)
		}
		grown := gc_heap_usage().total_bytes - before
		assert out.bytestr() == forbidden_response
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * 2} requests'
	}
}
