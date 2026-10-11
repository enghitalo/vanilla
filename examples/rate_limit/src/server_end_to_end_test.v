// vtest build: linux
// End-to-end over a real socket (vtest, see docs/VTEST.md): the key comes from
// the real `socket.peer_ipv4`, so a client sending a different forged
// X-Forwarded-For on every request still drains ONE bucket — its own.
module main

import core
import server
import vtest

fn test_e2e_real_peer_spoofed_xff_is_limited() ! {
	mut limiter := &Limiter{
		rate:     0.0 // no refill: exhaustion is deterministic under the real clock
		capacity: 3.0
	}
	mut rounds := []vtest.Round{}
	for i in 0 .. 10 { // `${}` is test scaffolding, not handler code
		rounds << vtest.Round{
			send: 'GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 198.51.100.${i}\r\n\r\n'.bytes()
		}
	}
	o := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		workers:         1
		handler:         fn [mut limiter] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, mut out, client_fd, worker_state, mut event_loop, mut
				limiter)
		}
	}, [vtest.Script{
		rounds: rounds
	}])!
	conn := o.conns[0]
	assert conn.connect_err == '', conn.connect_err
	assert conn.frames.len == 10
	for i, f in conn.frames {
		want := if i < 3 { 'HTTP/1.1 200' } else { 'HTTP/1.1 429' }
		assert f.bytestr().starts_with(want), 'request ${i}: ${f.bytestr()}'
	}
	// One bucket, keyed on the socket peer — not one per forged header.
	assert limiter.buckets.len == 1
	assert u32(0x7f000001) in limiter.buckets // 127.0.0.1
}
