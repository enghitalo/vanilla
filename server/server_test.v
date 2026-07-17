module server

// Hook-contract test for `after_server_start`. This file deliberately stays
// hand-rolled (chan + select + testkit) because it tests the readiness hook
// mechanism ITSELF — vtest's drive()/start() are built on that hook, so they
// cannot be used to verify it (docs/VTEST.md, "What stays hand-rolled").
//
// The end-to-end behavior tests that used to live here (keep-alive GET → 404
// routing, body delivery, malformed request → 400 + close) moved to
// tests/server_default_backend_test.v, on vtest.
import net
import time
import testkit
import core

fn dummy_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found'.bytes()
		return .done
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
	return .done
}

// The after_server_start hook fires exactly once, on the run() thread, at the
// moment the server is accepting. This verifies the hook mechanism itself: it must
// signal within a deadline, and the server must be serving immediately afterwards.
fn test_after_server_start_fires_when_ready() ! {
	ready := chan bool{cap: 1}
	mut srv := new_server(ServerConfig{
		port:               8156
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            dummy_handler
		after_server_start: fn [ready] () {
			ready <- true
		}
	})!
	spawn fn [mut srv] () {
		srv.run()
	}()

	select {
		_ := <-ready {}
		2000 * time.millisecond {
			assert false, 'after_server_start did not fire within 2s'
		}
	}

	mut c := net.dial_tcp('127.0.0.1:8156')!
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes())!
	assert testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000) == 1, 'server must be serving the instant after_server_start fired'
	c.close() or {}

	srv.shutdown(500)
}
