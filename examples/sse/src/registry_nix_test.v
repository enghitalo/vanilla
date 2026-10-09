module main

// The subscriber registry with real sockets (a socketpair stands in for an
// accepted connection), POSIX-only (`_nix`): subscribing registers the
// registry's own dup() of the connection, a connection it cannot dup is
// refused, and a departed subscriber's events never reach the connection that
// reuses its fd number (#232). On Windows the registry keys the core's handle
// (no dup() for a SOCKET); its subscribe path runs in server_end_to_end_test.v.
import core
import os

#include <sys/socket.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.recv(fd int, buf voidptr, n usize, flags int) int
fn C.dup2(oldfd int, newfd int) int

// A send to a departed peer must fail, not kill the test: macOS has no
// MSG_NOSIGNAL (the server sets SO_NOSIGPIPE on each accepted socket instead).
fn testsuite_begin() {
	os.signal_ignore(.pipe)
}

// conn_pair is a connected AF_UNIX pair: (server end, client end). The events
// are small, so blocking sends never wait; reads use MSG_DONTWAIT.
fn conn_pair() (int, int) {
	mut sv := [2]i32{} // C ints: V's int is 64-bit
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	return int(sv[0]), int(sv[1])
}

// pending is what `fd` has buffered to read, without waiting.
fn pending(fd int) string {
	mut buf := []u8{len: 256}
	n := C.recv(fd, buf.data, buf.len, C.MSG_DONTWAIT)
	if n <= 0 {
		return ''
	}
	return buf[..n].bytestr()
}

fn subscribe(fd int, mut clients Clients) (string, core.Step) {
	mut out := []u8{}
	step := handle('GET /events HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), fd, mut out, mut clients)
	return out.bytestr(), step
}

fn test_subscribe_returns_event_stream_and_registers_a_dup() {
	mut clients := Clients{}
	srv, cli := conn_pair()
	out, step := subscribe(srv, mut clients)
	assert step == .done
	assert out.contains('Content-Type: text/event-stream')
	assert !out.contains('Content-Length:') // a stream stays open, no fixed length
	subs := clients.snapshot()
	assert subs.len == 1 // one extra fd + one map entry, NO per-client thread
	assert subs[0] != srv // the registry's own descriptor, never the core's number
	clients.broadcast('data: hi\n\n'.bytes())
	assert pending(cli) == 'data: hi\n\n' // the dup reaches the same connection
	C.close(subs[0])
	C.close(srv)
	C.close(cli)
}

// A connection the registry cannot dup (here no connection at all, fd -1;
// in production EMFILE) is refused with 503 and closed, not subscribed.
fn test_subscribe_without_a_spare_descriptor_is_503() {
	mut clients := Clients{}
	out, step := subscribe(-1, mut clients)
	assert step == .close
	assert out.starts_with('HTTP/1.1 503')
	assert clients.snapshot().len == 0
}

// The kernel gives a closed fd's number to the next connection. A departed
// subscriber's events and heartbeats must never reach the connection that
// gets its number, even one that never sends a request (#232).
fn test_recycled_fd_number_gets_no_events() {
	mut clients := Clients{}
	a_srv, a_cli := conn_pair()
	assert clients.add(a_srv)
	C.close(a_cli) // A leaves
	C.close(a_srv) // the core closes A's fd, without telling the app
	b_new, b_cli := conn_pair()
	// B's end takes A's old number, as the next accepted connection would.
	mut b_srv := b_new
	if b_new != a_srv {
		b_srv = C.dup2(b_new, a_srv)
		C.close(b_new)
	}
	assert b_srv == a_srv
	clients.broadcast('data: patient-A:queue-position=3\n\n'.bytes())
	clients.broadcast(keepalive_event)
	assert pending(b_cli) == ''
	assert clients.snapshot().len == 0 // A's stream ended on its failed send
	C.close(b_srv)
	C.close(b_cli)
}
