module main

import core
import http1_1.response
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

const get_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'

// serve runs one request through handle and returns the response and the step.
fn serve(req string, fd int, mut b Blocklist) (string, core.Step) {
	mut resp := []u8{}
	mut event_loop := core.EventLoop{}
	step := handle(req.bytes(), mut resp, fd, unsafe { nil }, mut event_loop, mut b)
	return resp.bytestr(), step
}

fn test_peer_without_ipv4_is_allowed() {
	mut b := Blocklist{}
	b.block('127.0.0.1') or { panic(err) }
	// fd -1 => socket.peer_ipv4 is none: on no IPv4 list => allowed.
	out, step := serve(get_req, -1, mut b)
	assert out == ok_response
	assert step == .done
}

fn test_blocked_peer_gets_403_and_close_others_200() ! {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	mut b := Blocklist{}
	b.block('10.0.0.5')!
	// 127.0.0.1 is not listed: the 200, and the connection stays open.
	out, step := serve(get_req, s.sock.handle, mut b)
	assert out == ok_response
	assert step == .done
	// Listed: the 403 and .close, as its `Connection: close` says, so a
	// request pipelined behind it is never answered (#293).
	b.block('127.0.0.1')!
	out2, step2 := serve(get_req, s.sock.handle, mut b)
	assert out2 == forbidden_response
	assert step2 == .close
}

// An allowed peer must send a request the parser accepts: the issue's
// `garbage\r\n\r\n` (#293), which the framer passes whole, gets the canned 400
// and .close, not the 200. A blocked peer is denied before the parse, so the
// same bytes get its 403.
fn test_malformed_request_gets_400_and_close() ! {
	mut b := Blocklist{}
	for bad in ['garbage\r\n\r\n', 'garbage garbage\r\n\r\n', 'GET / HTTP/1.1\r\n'] {
		out, step := serve(bad, -1, mut b)
		assert out.bytes() == response.tiny_bad_request_response, bad
		assert step == .close, bad
	}
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	b.block('127.0.0.1')!
	out, step := serve('garbage\r\n\r\n', s.sock.handle, mut b)
	assert out == forbidden_response
	assert step == .close
}

// Blocked and allowed peers, and an allowed peer's malformed request, each run
// 20k times through one reused buffer, as a worker serves them: the
// collector's allocation counter must not move. A blocked client must not be
// able to make the server allocate (or log) per request.
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
		req := get_req.bytes()
		garbage := 'garbage\r\n\r\n'.bytes()
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
			handle(garbage, mut out, fd, unsafe { nil }, mut event_loop, mut allow)
			unsafe {
				out.len = 0
			}
			handle(req, mut out, fd, unsafe { nil }, mut event_loop, mut deny)
		}
		grown := gc_heap_usage().total_bytes - before
		assert out.bytestr() == forbidden_response
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds * 3} requests'
	}
}
