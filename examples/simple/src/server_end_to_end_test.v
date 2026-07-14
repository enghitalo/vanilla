module main

import http_server
import http_server.testkit
import http_server.http1_1.response
import sync.stdatomic
import time

// End-to-end test driving the REAL server (epoll on Linux, kqueue on macOS) over
// client sockets via http_server.testkit. Replaces the old `server.test()` helper:
// framed reads with a per-read deadline (no unbounded recv loop). Each case runs on
// its OWN connection, driven CONCURRENTLY (one thread each) — distinct connections,
// so it is safe on every backend. The four byte-for-byte assertions are preserved.
//
// The whole client workload runs INSIDE after_server_start (which fires on the
// server thread the instant it is accepting), so the test needs no separate
// readiness step. The result crosses back to the main thread through `Harness`: the
// hook fills `threads`, then flips the atomic `done` flag — an acquire/release
// barrier that publishes the fully-built `threads` array. The main thread spins on
// `done` before reading `threads`, so the array is only ever WRITTEN by the hook
// thread and only READ by main after the barrier (no data race; verified under
// -fsanitize=thread).

struct Case {
	name string
	req  []u8
	want []u8
}

// Harness is shared between the main thread and the after_server_start hook. `done`
// is the atomic happens-before barrier that publishes `threads`.
struct Harness {
mut:
	threads []thread []u8
	done    u64
}

// drive runs one case end to end on its own connection and returns the raw
// response bytes. A named fn (not an inline closure) so `spawn drive(...)` copies
// its args by value — the loop variable can't race. Panics on a connection error
// (a spawned []u8-returning fn cannot propagate a Result).
fn drive(port int, req []u8) []u8 {
	mut conn := testkit.dial(port) or { panic('dial: ${err}') }
	conn.write(req) or { panic('write: ${err}') }
	resp := testkit.read_response(mut conn, 2000)
	conn.close() or {}
	return resp
}

fn test_server_end_to_end() ! {
	port := 8160

	req2_want :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
	cases := [
		Case{'home', 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), http_ok_response},
		Case{'user', 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), req2_want},
		Case{'create', 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes(), http_created_response},
		Case{'invalid', 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), response.tiny_bad_request_response},
	]

	mut h := &Harness{}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:               port
		handler:            handle_request
		io_multiplexing:    unsafe { http_server.IOBackend(0) }
		after_server_start: fn [mut h, cases, port] () {
			// Runs on the server thread the instant it is accepting: fire one
			// connection per case, then publish the thread handles via the barrier.
			for c in cases {
				h.threads << spawn drive(port, c.req)
			}
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()

	// Wait for the hook to publish `threads` (barrier), then collect the responses.
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	got := h.threads.wait()

	server.shutdown(500)

	for i, c in cases {
		assert got[i] == c.want, '${c.name}: got ${got[i].bytestr()}'
	}
}
