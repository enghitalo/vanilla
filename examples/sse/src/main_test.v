module main

// Handler-state tests (run today) + an aspirational raw-streaming note below.
// We can assert the KEY property of the rewrite without a socket: subscribing
// registers an fd in epoll-resident state and spawns NO per-client thread.
import http_server.core

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect, alongside the handler's
// Step. Callers pass their own Clients so they can inspect subscriber state
// afterwards. fd -1 keeps any accidental send() harmless (EBADF), never a
// write to a real descriptor.
fn serve(req string, mut clients Clients) (string, core.Step) {
	mut out := []u8{}
	step := handle(req.bytes(), -1, mut out, mut clients)
	return out.bytestr(), step
}

fn test_subscribe_returns_event_stream_and_registers_fd() {
	mut clients := Clients{}
	out, step := serve('GET /events HTTP/1.1\r\nHost: x\r\n\r\n', mut clients)
	assert step == .done
	assert out.contains('Content-Type: text/event-stream')
	assert !out.contains('Content-Length:') // a stream stays open, no fixed length
	assert clients.snapshot().len == 1 // fd registered; cost is one map entry
}

fn test_broadcast_endpoint_accepts() {
	mut clients := Clients{} // empty set: no real fds to write to
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello', mut clients)
	assert step == .done
	assert out.contains('200 OK')
}

fn test_broadcast_empty_body_is_ok() {
	// exercises the body.len == 0 guard: `data: \n\n` is still a valid SSE event
	mut clients := Clients{}
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 0\r\n\r\n', mut clients)
	assert step == .done
	assert out.contains('200 OK')
}

fn test_unknown_route_is_bad_request() {
	mut clients := Clients{}
	out, step := serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n', mut clients)
	assert step == .done
	assert out.contains('400')
}

fn test_malformed_request_errors() {
	mut clients := Clients{}
	// not even a request line — decode_http_request must reject it
	out1, step1 := serve('garbage', mut clients)
	assert step1 == .close, 'garbage input must close, not be routed'
	assert out1.contains('400')
	// truncated head: request line parses, but the header block never terminates
	out2, step2 := serve('GET /events HTTP/1.1\r\nHost: x', mut clients)
	assert step2 == .close, 'truncated request must close, not be routed'
	assert out2.contains('400')
	assert clients.snapshot().len == 0 // nothing was registered along the way
}

/*
ASPIRATIONAL — Solution 2 (programmable client) + Solution 7 (concurrency).
This is the test that proves real push fan-out; it needs the raw streaming
client (Server.test() can't: it frames by Content-Length and would hang on an
open stream). Run under V's thread sanitizer to catch races on the client set:

  mut subs := []TestConn{}
  for _ in 0 .. 50 { mut s := testkit.dial(port); s.send('GET /events HTTP/1.1\r\n\r\n')
                     s.read_until('\r\n\r\n'); subs << s }          // 50 open streams
  mut pub := testkit.dial(port); pub.send('POST /broadcast ... hello')
  for mut s in subs { assert s.read_until('\n\n').contains('data: hello') }  // ALL receive
*/
