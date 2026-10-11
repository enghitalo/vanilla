module main

import server
import core
import http1_1.response
import vtest

// End-to-end cases against the example's real handler, on vtest (docs/VTEST.md):
// drive() owns the whole lifecycle — ephemeral port, readiness, shutdown — and
// fires all the connections CONCURRENTLY across the workers. Byte-for-byte
// asserts by script index. The handler is wired through the same App closure
// main.v uses; App{} leaves db_pool unset, which these routes never touch.

struct Case {
	name string
	req  []u8
	want []u8
}

// config wires `app` in through the same closure main() uses (drive() binds
// an ephemeral port instead of main's 3000).
fn config(app App) server.ServerConfig {
	return server.ServerConfig{
		handler: fn [app] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return app.handle_request(req_buffer, mut out, client_fd, worker_state, mut event_loop)
		}
	}
}

fn test_server_end_to_end() ! {
	app := App{}

	req2_want :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
	query_want :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n7'.bytes()
	// 'INVALID' parses (the parser does not police the method token), so no
	// route matches and the router answers 404 with .done.
	cases := [
		Case{'home', 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), http_ok_response.bytes()},
		Case{'user', 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), req2_want},
		Case{'create', 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes(), http_created_response.bytes()},
		Case{'invalid', 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), http_not_found_response.bytes()},
		Case{'query', 'GET /user/7?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), query_want},
		Case{'empty id', 'GET /user/ HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), http_not_found_response.bytes()},
	]

	mut scripts := []vtest.Script{cap: cases.len}
	for c in cases {
		scripts << vtest.Script{
			rounds: [vtest.Round{
				send: c.req
			}]
		}
	}
	got := vtest.drive(config(app), scripts)!

	for i, c in cases {
		assert got.conns[i].connect_err == '', '${c.name}: ${got.conns[i].connect_err}'
		assert got.conns[i].frames.len == 1, c.name
		assert got.conns[i].frames[0] == c.want, '${c.name}: got ${got.conns[i].frames[0].bytestr()}'
	}
	assert got.inflight_after == 0
}

// The 404 says `Connection: keep-alive` and the handler returns .done, so the
// server keeps the connection: a second request on it is answered too.
fn test_not_found_keeps_the_connection_open() ! {
	got := vtest.drive(config(App{}), [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: 'GET /?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
			]
		},
	])!
	assert got.conns[0].frames.len == 2
	assert got.conns[0].frames[0] == http_not_found_response.bytes()
	assert got.conns[0].frames[1] == http_ok_response.bytes()
	assert !got.conns[0].eof
	assert got.inflight_after == 0
}

// A request line with no spaces still frames (the head ends in CRLFCRLF), so
// it reaches the handler, and decode_into rejects it: the canned 400 says
// `Connection: close` and the handler returns .close, so the server closes.
fn test_malformed_head_gets_400_and_close() ! {
	got := vtest.drive(config(App{}), [
		vtest.Script{
			rounds:   [vtest.Round{
				send: 'GET/HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
			}]
			then_eof: true
		},
	])!
	assert got.conns[0].frames.len == 1
	assert got.conns[0].frames[0] == response.tiny_bad_request_response
	assert got.conns[0].eof
	assert got.inflight_after == 0
}
