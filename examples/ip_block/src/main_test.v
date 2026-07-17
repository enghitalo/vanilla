module main

import core

// SOLUTION: in-memory state test (denylist) + handler gate.
// The blocklist set is pure/in-memory, so block/unblock/is_blocked and the 403
// gate are unit-testable. The peer IP itself comes from the socket
// (socket.peer_addr) — exercised end-to-end via curl, see the README/commands.

fn test_block_unblock_roundtrip() {
	mut b := Blocklist{}
	assert !b.is_blocked('1.2.3.4')
	b.block('1.2.3.4')
	assert b.is_blocked('1.2.3.4')
	b.unblock('1.2.3.4')
	assert !b.is_blocked('1.2.3.4')
}

fn test_allowed_ip_gets_200() {
	mut b := Blocklist{}
	// fd -1 => socket.peer_addr returns '' (not in the list) => allowed.
	mut resp := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut resp, -1, unsafe { nil }, mut
		event_loop, mut b) == .done
	out := resp.bytestr()
	assert out.contains('200 OK')
	assert out.contains('allowed')
}

fn test_blocked_ip_gets_403() {
	mut b := Blocklist{}
	// peer_addr('' for fd -1) — block that to drive the deny path through handle.
	b.block('')
	mut resp := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut resp, -1, unsafe { nil }, mut
		event_loop, mut b) == .done
	assert resp.bytestr().contains('403 Forbidden')
}
