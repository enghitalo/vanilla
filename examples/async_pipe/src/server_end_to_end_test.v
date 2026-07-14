module main

import http_server
import http_server.testkit
import sync.stdatomic
import time

// Drives the async runtime end to end through the real backend (epoll on Linux,
// kqueue on macOS): a /async request parks on a pipe watch (.suspend) and is
// answered from the continuation. The ONLY cross-platform validation of the macOS
// kqueue async path in CI, so it runs on IOBackend(0) on both platforms.
//
// The client runs INSIDE after_server_start (fires on the server thread the instant
// it is accepting). The hook `spawn`s the client — so it returns and the accept
// loop starts — records the handle in a Harness, and flips the atomic `done`
// barrier that publishes it; the main thread spins on `done`, joins, and asserts.
// The body `async-ok` is emitted ONLY by the continuation (pipe_done); the
// synchronous path answers `ok`, so the assertion is specific to the watch_fd
// suspend/resume round trip. read_response's per-read deadline means a broken
// suspend/resume path fails fast instead of hanging.

struct Harness {
mut:
	th   thread []u8
	done u64
}

fn (mut h Harness) await() []u8 {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.th.wait()
}

fn cli_async(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	c.write('GET /async HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write: ${err}'.bytes()
	}
	resp := testkit.read_response(mut c, 3000)
	c.close() or {}
	return resp
}

fn test_async_pipe_end_to_end() ! {
	port := 8162
	mut h := &Harness{}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:               port
		handler:            handle
		io_multiplexing:    unsafe { http_server.IOBackend(0) } // epoll on Linux, kqueue on macOS
		after_server_start: fn [mut h, port] () {
			h.th = spawn cli_async(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()

	got := h.await()
	server.shutdown(500)
	assert got.bytestr().contains('async-ok'), 'async continuation must answer via watch_fd/suspend; got: ${got.bytestr()}'
}
