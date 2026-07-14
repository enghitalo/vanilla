module http_server

// End-to-end tests for the default backend (epoll on Linux, kqueue on macOS,
// IOBackend(0)) driven over a REAL client socket via http_server.testkit.
//
// Replaces the old `server.test()` helper: framed reads with a per-read deadline
// (no unbounded recv loop), and the .close path a router takes on a malformed
// request line is exercised end to end.
//
// The client workload runs INSIDE after_server_start (fires on the server thread
// the instant it is accepting). Because run()'s accept loop only starts AFTER the
// hook returns, the hook must not block on a read — it `spawn`s the client fn (so
// the hook returns immediately and the accept loop starts), stores the thread
// handle in a Harness, and flips the atomic `done` flag (an acquire/release
// barrier that publishes the handle). The main thread spins on `done`, then
// wait()s the client thread and asserts on its returned bytes. No polling, no
// testkit.serve.
import time
import sync.stdatomic
import http_server.testkit
import http1_1.request_parser
import http1_1.response
import http_server.core

fn dummy_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found'.bytes()
		return .done
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
	return .done
}

// closing_handler mirrors the real example routers: a request the parser rejects
// is answered with a 400 and the connection is CLOSED (.close); a valid request is
// a plain keep-alive 200.
fn closing_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
	return .done
}

// Harness carries one client thread's handle from the after_server_start hook
// (server thread) to the test's main thread. `done` is the atomic happens-before
// barrier that publishes `th`.
struct Harness {
mut:
	th   thread []u8
	done u64
}

// await spins on the barrier, then joins the client thread and returns its bytes.
fn (mut h Harness) await() []u8 {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.th.wait()
}

// --- client workloads (each runs on its own thread, spawned from the hook) ---

// cli_get_and_notfound: two requests on ONE keep-alive connection, each response
// read fully before the next is sent (kqueue-safe). Returns "ok" on success,
// otherwise a diagnostic string the main thread asserts against.
fn cli_get_and_notfound(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write1: ${err}'.bytes()
	}
	if testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000) != 1 {
		return 'GET / not answered 200'.bytes()
	}
	c.write('GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write2: ${err}'.bytes()
	}
	if testkit.read_until_count(mut c, 'HTTP/1.1 404', 1, 2000) != 1 {
		return 'GET /notfound not answered 404 on keep-alive conn'.bytes()
	}
	c.close() or {}
	return 'ok'.bytes()
}

// cli_body: fetch GET / and return the FULL raw response bytes (head + body), so
// the main thread can assert the body was delivered through the real send path.
fn cli_body(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write: ${err}'.bytes()
	}
	acc := testkit.read_full(mut c, 40, 2000) // "200 OK" head + "OK" body
	c.close() or {}
	return acc
}

// cli_malformed: send a malformed request line, confirm a 400 arrives, then that
// the connection is CLOSED (follow-up read hits EOF). Returns "ok" or a diagnostic.
fn cli_malformed(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	// No space after the method token: the head frames (ends in \r\n\r\n) so the
	// handler runs, but decode_http_request rejects the request line → 400 + .close.
	c.write('GET/HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or { return 'write: ${err}'.bytes() }
	if testkit.read_until_count(mut c, 'HTTP/1.1 400', 1, 2000) != 1 {
		return 'malformed request not answered 400'.bytes()
	}
	// After .close the server flushes the 400 then shuts the connection: a follow-up
	// read must observe EOF, not another response.
	c.set_read_timeout(2000 * time.millisecond)
	mut buf := []u8{len: 256}
	nr := c.read(mut buf) or { 0 }
	c.close() or {}
	if nr > 0 {
		return 'connection not closed after malformed request; got ${nr} more bytes'.bytes()
	}
	return 'ok'.bytes()
}

// --- tests ---

fn test_server_get_and_notfound() ! {
	port := 8150
	mut h := &Harness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            dummy_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn cli_get_and_notfound(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.await()
	server.shutdown(500)
	assert got.bytestr() == 'ok', got.bytestr()
}

fn test_server_body_delivery() ! {
	port := 8151
	mut h := &Harness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            dummy_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn cli_body(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	acc := h.await()
	server.shutdown(500)
	assert testkit.count_marker(acc, 'HTTP/1.1 200') == 1, 'expected one 200, got: ${acc.bytestr()}'
	assert acc.bytestr().contains('\r\n\r\nOK'), 'body not delivered: ${acc.bytestr()}'
}

fn test_server_malformed_request_closes() ! {
	port := 8155
	mut h := &Harness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            closing_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn cli_malformed(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.await()
	server.shutdown(500)
	assert got.bytestr() == 'ok', got.bytestr()
}

// The after_server_start hook fires exactly once, on the run() thread, at the
// moment the server is accepting. This verifies the hook mechanism itself: it must
// signal within a deadline, and the server must be serving immediately afterwards.
fn test_after_server_start_fires_when_ready() ! {
	ready := chan bool{cap: 1}
	mut server := new_server(ServerConfig{
		port:               8156
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            dummy_handler
		after_server_start: fn [ready] () {
			ready <- true
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()

	select {
		_ := <-ready {}
		2000 * time.millisecond {
			assert false, 'after_server_start did not fire within 2s'
		}
	}

	mut c := testkit.dial(8156)!
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes())!
	assert testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000) == 1, 'server must be serving the instant after_server_start fired'
	c.close() or {}

	server.shutdown(500)
}
