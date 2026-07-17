// End-to-end behavior tests for the platform-default backend (epoll on Linux,
// kqueue on macOS, iocp on Windows — IOBackend(0)), migrated from
// server/server_test.v onto vtest (docs/VTEST.md). Standalone on purpose:
// vtest imports server, so this file lives outside that module and uses
// only public API. No ports (always ephemeral), no timeouts, no readiness
// plumbing — drive() owns the lifecycle, and every test asserts leak-freedom
// via the post-drain inflight counter.
import server
import core
import http1.request_parser
import http1.response
import vtest

const get_root = 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
const get_missing = 'GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
// No space after the method token: the head frames (ends in \r\n\r\n) so the
// handler runs, but decode_http_request rejects the request line → 400 + .close.
const malformed = 'GET/HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
const notfound_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found'.bytes()

fn routing_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << notfound_response
		return .done
	}
	res << ok_response
	return .done
}

// closing_handler mirrors the real example routers: a request the parser rejects
// is answered with a 400 and the connection is CLOSED (.close); a valid request
// is a plain keep-alive 200.
fn closing_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	res << ok_response
	return .done
}

// Routing + keep-alive reuse: 200 then 404 on ONE connection. Rounds sequence
// within the connection, so the second request goes out only after the first
// response arrived (kqueue-safe).
fn test_server_get_and_notfound() ! {
	out := vtest.drive(server.ServerConfig{ handler: routing_handler }, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: get_root
				},
				vtest.Round{
					send: get_missing
				},
			]
		},
	])!
	assert out.conns[0].connect_err == '', out.conns[0].connect_err
	assert out.conns[0].frames.len == 2
	assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')
	assert out.conns[0].frames[1].bytestr().starts_with('HTTP/1.1 404'), 'GET /notfound not answered 404 on keep-alive conn'
	assert out.inflight_after == 0
}

// The body must be delivered through the real send path: the single framed
// response carries the head AND the "OK" body.
fn test_server_body_delivery() ! {
	out := vtest.drive(server.ServerConfig{ handler: routing_handler }, [
		vtest.Script{
			rounds: [vtest.Round{
				send: get_root
			}]
		},
	])!
	assert out.conns[0].frames.len == 1
	got := out.conns[0].frames[0].bytestr()
	assert got.count('HTTP/1.1 200') == 1, 'expected one 200, got: ${got}'
	assert got.ends_with('\r\n\r\nOK'), 'body not delivered: ${got}'
	assert out.inflight_after == 0
}

// A malformed request line is answered 400 and the connection is CLOSED
// (.close path exercised end to end): then_eof requires the SERVER to close,
// and exactly one response must have arrived before it did.
fn test_server_malformed_request_closes() ! {
	out := vtest.drive(server.ServerConfig{ handler: closing_handler }, [
		vtest.Script{
			rounds:   [vtest.Round{
				send: malformed
			}]
			then_eof: true
		},
	])!
	assert out.conns[0].frames.len == 1, 'connection not closed after malformed request; got ${out.conns[0].frames.len} responses'
	assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 400'), 'malformed request not answered 400'
	assert out.conns[0].eof, 'router returned .close — the server must close after the 400'
	assert out.inflight_after == 0
}
