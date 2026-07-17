module main

import server
import core
import http1_1.response
import vtest

// End-to-end cases against the example's real handler, on vtest (docs/VTEST.md):
// drive() owns the whole lifecycle — ephemeral port, readiness, shutdown — and
// fires all four connections CONCURRENTLY across the workers. Byte-for-byte
// asserts by script index. The handler is wired through the same App closure
// main.v uses; App{} leaves db_pool unset, which these routes never touch.

struct Case {
	name string
	req  []u8
	want []u8
}

fn test_server_end_to_end() ! {
	app := App{}

	req2_want :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
	// 'INVALID' parses (the parser does not police the method token), so the
	// router answers 400 via the fall-through and returns .done — the connection
	// stays keep-alive: a plain framed expectation, not then_eof.
	cases := [
		Case{'home', 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), http_ok_response},
		Case{'user', 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), req2_want},
		Case{'create', 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes(), http_created_response},
		Case{'invalid', 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), response.tiny_bad_request_response},
	]

	mut scripts := []vtest.Script{cap: cases.len}
	for c in cases {
		scripts << vtest.Script{
			rounds: [vtest.Round{
				send: c.req
			}]
		}
	}
	got := vtest.drive(server.ServerConfig{
		handler: fn [app] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return app.handle_request(req_buffer, mut out, -1, unsafe { nil }, mut event_loop)
		}
	}, scripts)!

	for i, c in cases {
		assert got.conns[i].connect_err == '', '${c.name}: ${got.conns[i].connect_err}'
		assert got.conns[i].frames.len == 1, c.name
		assert got.conns[i].frames[0] == c.want, '${c.name}: got ${got.conns[i].frames[0].bytestr()}'
	}
	assert got.inflight_after == 0
}
