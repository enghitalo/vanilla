module main

import net
import http_server
import http_server.testkit
import http_server.core
import http_server.http1_1.response
import sync.stdatomic
import time

// End-to-end test driving the REAL server (epoll on Linux, kqueue on macOS) over
// client sockets via http_server.testkit. Replaces the old `server.test()` helper:
// framed reads with a per-read deadline. Each case runs on its OWN connection,
// driven CONCURRENTLY (one thread each). The four byte-for-byte assertions are
// preserved. The handler is wired through the same App closure main.v uses; App{}
// leaves the db_pool unset, which the exercised routes never touch.
//
// The whole client workload runs INSIDE after_server_start (fires on the server
// thread the instant it is accepting). The hook spawns one drive() thread per case
// — returning immediately so the accept loop starts — records the handles in a
// Harness, then flips the atomic `done` flag (an acquire/release barrier that
// publishes the fully-built `threads`). The main thread spins on `done`, joins, and
// asserts. No polling, no testkit.serve.

struct Case {
	name string
	req  []u8
	want []u8
}

struct Harness {
mut:
	threads []thread []u8
	done    u64
}

fn (mut h Harness) await() [][]u8 {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.threads.wait()
}

// drive runs one case on its own connection and returns the raw response bytes. A
// named fn (not an inline closure) so `spawn drive(...)` copies its args by value —
// the loop variable can't race. Panics on a connection error (a spawned
// []u8-returning fn cannot propagate a Result).
fn drive(port int, req []u8) []u8 {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { panic('dial: ${err}') }
	conn.write(req) or { panic('write: ${err}') }
	resp := testkit.read_response(mut conn, 2000)
	conn.close() or {}
	return resp
}

fn test_server_end_to_end() ! {
	app := App{}
	port := 8161

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
		handler:            fn [app] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return app.handle_request(req_buffer, mut out, -1, unsafe { nil }, mut event_loop)
		}
		io_multiplexing:    unsafe { http_server.IOBackend(0) }
		after_server_start: fn [mut h, cases, port] () {
			for c in cases {
				h.threads << spawn drive(port, c.req)
			}
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()

	got := h.await()
	server.shutdown(500)

	for i, c in cases {
		assert got[i] == c.want, '${c.name}: got ${got[i].bytestr()}'
	}
}
