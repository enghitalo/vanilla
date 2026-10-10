// vtest build: !windows
// main.v needs POSIX pipe(2)/<unistd.h> and the .suspend watch reactor, which
// exist on epoll (Linux) and kqueue (macOS) but not on the Windows/IOCP backend.
module main

import server
import vtest
import http1_1.response

// Drives the async runtime end to end on vtest (docs/VTEST.md): /async parks the
// request on a pipe watch (.suspend) and is answered from the continuation. The
// body `async-ok` is emitted ONLY by pipe_done — the synchronous path answers
// `ok` — so the assert is specific to the watch_fd suspend/resume round trip.

fn test_async_pipe_end_to_end() ! {
	out := vtest.drive(server.ServerConfig{ handler: handle }, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /async HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
			]
		},
	])!
	assert out.conns[0].connect_err == '', out.conns[0].connect_err
	assert out.conns[0].frames.len == 1
	assert out.conns[0].frames[0].bytestr() == resp_async, 'async continuation must answer via watch_fd/suspend; got: ${out.conns[0].raw.bytestr()}'
	assert out.inflight_after == 0
}

// Routing compares the path in place, without its query string: only /async
// parks. A request the parser rejects gets 400 and the connection closes.
fn test_async_pipe_routing() ! {
	out := vtest.drive(server.ServerConfig{ handler: handle }, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /async?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: 'GET /asynchronous HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: 'GET /x?async HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
			]
		},
		vtest.Script{
			rounds:   [vtest.Round{
				send: 'GET\r\n\r\n'.bytes()
			}]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 3
	assert c.frames[0].bytestr() == resp_async
	assert c.frames[1].bytestr() == resp_ok
	assert c.frames[2].bytestr() == resp_ok
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
	assert out.active_after == 0
}
