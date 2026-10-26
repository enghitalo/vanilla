// vtest build: linux
module main

// The SSE example end to end on the epoll worker: subscribers on real streams
// across workers, the fan-out, a request pipelined behind GET /events, the
// heartbeat, a departed subscriber whose fd numbers new connections take
// (#232: a post to its handle reaches nobody), and shutdown. Takeover is inert
// under tcc (#173): there GET /events answers 501, and that is what the first
// test checks. Run with gcc or clang to exercise the rest.
import core
import time
import transport
import vtest

#include <sys/socket.h>
#include "@VMODROOT/socket/sock_shim.h"

fn C.vanilla_recv(fd int, buf voidptr, n u64, flags int) int
fn C.vanilla_send(fd int, buf voidptr, n u64, flags int) int
fn C.getsockname(fd int, addr voidptr, addrlen &u32) int
fn C.getpeername(fd int, addr voidptr, addrlen &u32) int

const subscribe_req = 'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n'

const broadcast_req = 'POST /broadcast HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello'

const event_marker = 'data: hello\n\n'

const n_subscribers = 8

// Client is a raw client connection that accumulates what it reads.
struct Client {
	fd int
mut:
	acc []u8
}

fn dial(port int, req string) !Client {
	c := Client{
		fd: transport.dial_tcp('127.0.0.1', port)!
	}
	c.send(req)!
	return c
}

fn (c Client) send(s string) ! {
	if s.len == 0 {
		return
	}
	for _ in 0 .. 2000 {
		n := C.vanilla_send(c.fd, s.str, u64(s.len), C.MSG_NOSIGNAL)
		if n == s.len {
			return
		}
		if n > 0 {
			return error('short send')
		}
		time.sleep(time.millisecond) // still connecting
	}
	return error('send failed')
}

// until reads until `needle` is in what was read (true), or EOF or `ms` pass.
fn (mut c Client) until(needle string, ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for {
		if c.acc.bytestr().contains(needle) {
			return true
		}
		n := C.vanilla_recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			continue
		}
		if n == 0 || time.sys_mono_now() > deadline {
			return c.acc.bytestr().contains(needle)
		}
		time.sleep(time.millisecond)
	}
	return false
}

// eof reads until the server closes (true) or `ms` pass.
fn (mut c Client) eof(ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for time.sys_mono_now() < deadline {
		n := C.vanilla_recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			continue
		}
		if n == 0 || (n < 0 && C.errno != C.EAGAIN) {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

fn (c Client) close() {
	transport.close_fd(c.fd)
}

// sse_server starts the example's server on an ephemeral port.
fn sse_server(workers int, heartbeat_ms int) !(&vtest.Harness, &Hub) {
	hub := new_hub(heartbeat_ms)
	h := vtest.start(new_config(0, workers, hub))!
	return h, hub
}

// handle_at is subscriber i's handle, read under the hub's lock.
fn (mut hub Hub) handle_at(i int) core.ConnHandle {
	hub.mu.lock()
	h := hub.subs[i].handle
	hub.mu.unlock()
	return h
}

fn wait_hub(mut hub Hub, n int, ms int) int {
	for _ in 0 .. ms {
		if hub.size() == n {
			break
		}
		time.sleep(time.millisecond)
	}
	return hub.size()
}

// 8 subscribers on two workers open real streams, one POST /broadcast fans
// the event out to every one of them, and wait() blocks until each stream
// received it. The subscriber is in the hub before its head goes out, so once
// headers_seen holds the broadcast cannot miss it.
fn test_sse_fanout_end_to_end() ! {
	mut h, mut hub := sse_server(2, 15_000)!
	defer {
		h.stop()
	}
	subs := h.fire(vtest.repeat(n_subscribers, vtest.Script{
		rounds: [vtest.Round{
			send:  subscribe_req.bytes()
			until: vtest.headers_seen
		}]
	}))!
	$if tinyc {
		for c in subs.conns {
			assert c.raw.bytestr().starts_with(not_implemented), c.raw.bytestr()
		}
		eprintln('[test] takeover is inert under tcc: GET /events is 501; skipping the streams')
		return
	}
	for c in subs.conns {
		assert c.connect_err == '', c.connect_err
		assert c.raw.bytestr() == sse_head
	}
	assert hub.size() == n_subscribers
	ack := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: broadcast_req.bytes()
		}]
	}])!
	assert ack.conns[0].frames[0].bytestr() == ok_response
	// Every stream must receive `data: hello\n\n`, delivered by its own worker;
	// a stream the server closed before the event arrived would surface as unmet.
	got := h.wait(subs.group, vtest.count(event_marker, 1))!
	for i, c in got.conns {
		assert !c.unmet, 'subscriber ${i} lost its stream before the event'
		assert c.raw.bytestr() == sse_head + event_marker, 'subscriber ${i} got: ${c.raw.bytestr()}'
	}
}

// A client that pipelines more requests behind GET /events subscribes once:
// the bytes behind it are the stream's, and drain_conn drops them.
fn test_pipelined_subscribe_registers_once() ! {
	$if tinyc {
		return
	}
	mut h, mut hub := sse_server(1, 15_000)!
	defer {
		h.stop()
	}
	mut a := dial(h.port(), subscribe_req + subscribe_req + subscribe_req)!
	defer {
		a.close()
	}
	assert a.until(sse_head, 2000)
	assert wait_hub(mut hub, 1, 100) == 1
	mut b := dial(h.port(), broadcast_req)!
	assert b.until(ok_response, 2000)
	b.close()
	assert a.until(event_marker, 2000)
	time.sleep(50 * time.millisecond)
	assert a.acc.bytestr() == sse_head + event_marker
	assert hub.size() == 1
}

// The heartbeat is the subscription's wake_after timer, with no Limits: a
// `: keepalive` comment every interval, and the stream stays open (and keeps
// receiving events) in between.
fn test_heartbeat_ticks() ! {
	$if tinyc {
		return
	}
	mut h, _ := sse_server(1, 100)!
	defer {
		h.stop()
	}
	mut a := dial(h.port(), subscribe_req)!
	defer {
		a.close()
	}
	assert a.until(sse_head, 2000)
	sw := time.new_stopwatch()
	assert a.until(keepalive_event + keepalive_event + keepalive_event, 2000), a.acc.bytestr()
	took := sw.elapsed().milliseconds()
	assert took >= 250 && took < 1500, 'three heartbeats of 100 ms took ${took} ms'
	mut b := dial(h.port(), broadcast_req)!
	assert b.until(ok_response, 2000)
	b.close()
	assert a.until(event_marker, 2000), a.acc.bytestr()
}

// local_port and peer_port read a TCP socket's own and its peer's port.
fn local_port(fd int) int {
	mut addr := [128]u8{} // a sockaddr_storage
	mut len := u32(128)
	if C.getsockname(fd, voidptr(&addr[0]), &len) != 0 {
		return -1
	}
	return int(addr[2]) << 8 | int(addr[3]) // sin_port, network byte order
}

fn peer_port(fd int) int {
	mut addr := [128]u8{}
	mut len := u32(128)
	if C.getpeername(fd, voidptr(&addr[0]), &len) != 0 {
		return -1
	}
	return int(addr[2]) << 8 | int(addr[3])
}

// takes_number waits until the server's socket `fd` is the accepted end of
// client `c` (the server runs in this process, so the test sees its fds).
fn takes_number(fd int, c Client, ms int) bool {
	for _ in 0 .. ms {
		p := peer_port(fd)
		if p > 0 && p == local_port(c.fd) {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

// Repros D and F (#232) against the example, with no Limits: subscriber A
// leaves, and idle connections that send nothing take its fd numbers. Then
// neither a post to A's old handle nor a broadcast reaches them: the post is
// dropped on the worker as stale, and the hub no longer lists A.
fn test_departed_subscriber_reaches_nobody() ! {
	$if tinyc {
		return
	}
	mut h, mut hub := sse_server(1, 15_000)!
	defer {
		h.stop()
	}
	mut a := dial(h.port(), subscribe_req)!
	assert a.until(sse_head, 2000)
	assert wait_hub(mut hub, 1, 2000) == 1
	a_handle := hub.handle_at(0)
	a.close()
	assert wait_hub(mut hub, 0, 2000) == 0, 'the hub kept a departed subscriber'
	// B, C (and more if need be) connect and send nothing, until one of them
	// is the server's socket with A's number: the kernel gives the lowest free
	// numbers, so that is B, unless something else closed an fd meanwhile.
	mut idle := []Client{}
	defer {
		for c in idle {
			c.close()
		}
	}
	mut reused := false
	for idle.len < 2 || (!reused && idle.len < 6) {
		idle << dial(h.port(), '')!
		reused = reused || takes_number(a_handle.fd, idle.last(), 200)
	}
	assert reused, 'no new connection took the departed subscriber fd number ${a_handle.fd}'
	before := h.server_ref().push_stats()
	assert a_handle.post_bytes(0, 'patient-A:queue-position=3'.bytes()) == .ok
	assert a_handle.post_wake(1) == .ok
	mut d := dial(h.port(), 'POST /broadcast HTTP/1.1\r\nHost: x\r\nContent-Length: 26\r\n\r\npatient-A:queue-position=3')!
	assert d.until(ok_response, 2000)
	d.close()
	for _ in 0 .. 2000 {
		if h.server_ref().push_stats().stale >= before.stale + 2 {
			break
		}
		time.sleep(time.millisecond)
	}
	after := h.server_ref().push_stats()
	assert after.stale == before.stale + 2
	assert after.delivered == before.delivered
	for i, mut c in idle {
		assert !c.until('patient', 100) && c.acc.len == 0, 'idle connection ${i} got a departed subscriber event: ${c.acc.bytestr()}'
	}
}

// Server.shutdown(grace) does not wait for the streams: every subscriber gets
// .shutdown and its stream ends at once, and the hub empties as they go.
fn test_shutdown_ends_the_streams() ! {
	$if tinyc {
		return
	}
	mut h, mut hub := sse_server(2, 15_000)!
	defer {
		h.stop()
	}
	mut a := dial(h.port(), subscribe_req)!
	defer {
		a.close()
	}
	mut b := dial(h.port(), subscribe_req)!
	defer {
		b.close()
	}
	assert a.until(sse_head, 2000) && b.until(sse_head, 2000)
	sw := time.new_stopwatch()
	h.server_ref().shutdown(5000)
	waited := sw.elapsed().milliseconds()
	assert waited < 2000, 'the streams held shutdown(5000) for ${waited} ms'
	assert a.eof(2000) && b.eof(2000), 'a stream outlived the shutdown'
	assert a.acc.bytestr() == sse_head && b.acc.bytestr() == sse_head
	assert wait_hub(mut hub, 0, 2000) == 0
}
