// vtest build: !windows
// main.v needs POSIX pipe(2)/<unistd.h> and the .suspend watch reactor, which
// exist on epoll (Linux) and kqueue (macOS) but not on the Windows/IOCP backend.
module main

import http_server
import vtest

// Drives the async runtime end to end on vtest (docs/VTEST.md): /async parks the
// request on a pipe watch (.suspend) and is answered from the continuation. The
// body `async-ok` is emitted ONLY by pipe_done — the synchronous path answers
// `ok` — so the assert is specific to the watch_fd suspend/resume round trip.

fn test_async_pipe_end_to_end() ! {
	out := vtest.drive(http_server.ServerConfig{ handler: handle }, [
		vtest.Script{
			rounds: [vtest.Round{
				send: 'GET /async HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
			}]
		},
	])!
	assert out.conns[0].connect_err == '', out.conns[0].connect_err
	assert out.conns[0].frames.len == 1
	assert out.conns[0].frames[0].bytestr().contains('async-ok'), 'async continuation must answer via watch_fd/suspend; got: ${out.conns[0].raw.bytestr()}'
	assert out.inflight_after == 0
}
