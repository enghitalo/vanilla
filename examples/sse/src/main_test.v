module main

// SOLUTION: handler-state test (works today) + Solution-2/7 streaming note.
// We can assert the KEY property of the rewrite without a socket: subscribing
// registers an fd in epoll-resident state and spawns NO per-client thread.

fn test_subscribe_returns_event_stream_and_registers_fd() ! {
	mut clients := Clients{}
	out := handle('GET /events HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 7, mut clients)!.bytestr()
	assert out.contains('Content-Type: text/event-stream')
	assert !out.contains('Content-Length:') // a stream stays open, no fixed length
	assert clients.snapshot().len == 1 // fd registered; cost is one map entry
}

fn test_broadcast_endpoint_accepts() ! {
	mut clients := Clients{} // empty set: no real fds to write to
	out := handle('POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello'.bytes(), 7, mut
		clients)!.bytestr()
	assert out.contains('200 OK')
}

fn test_unknown_route_is_bad_request() ! {
	mut clients := Clients{}
	assert handle('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 7, mut clients)!.bytestr().contains('400')
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
