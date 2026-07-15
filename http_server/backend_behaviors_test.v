module http_server

// Behavioural end-to-end tests for the connection state machine, run against
// BOTH Linux backends (epoll and io_uring): HTTP/1.1 pipelining, request
// framing across TCP segments, max_connections, read timeout, and graceful
// shutdown. Each test drives a real server (spawned on a thread) with raw
// client sockets via the `net` module.
//
// The checks are backend-agnostic (the server enforces the same behaviour
// either way), so each is written once as a check_* helper and invoked per
// backend. These backends are Linux-only, so every test is a no-op elsewhere.
// Timing assertions use wide margins (server timeouts small, client waits large)
// so they assert behaviour, not exact latency.
import net
import time
import sync.stdatomic
import http_server.testkit
import http1_1.request_parser
import http1_1.response
import http_server.core

fn bb_ok_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
	return .done
}

// bb_upload_handler answers a /upload by the DECLARED Content-Length only — it
// never touches the body. This is the shape the large-body streaming path
// requires (the head alone is passed; the body is drained + discarded), mirroring
// the HttpArena vanilla /upload handler.
fn bb_upload_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	cl := hr.content_length()
	body := cl.str()
	res << 'HTTP/1.1 200 OK\r\nContent-Length: ${body.len}\r\nConnection: keep-alive\r\n\r\n${body}'.bytes()
	return .done
}

const bb_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'

// The deadline-bounded framed readers (read_until_count, read_full) live in
// http_server.testkit; connecting is net.dial_tcp and counting occurrences is
// `string.count` on the response bytes, used inline below.

// BbHarness carries a client thread's result string from the after_server_start
// hook (server thread) to the test's main thread. `done` is the atomic
// happens-before barrier that publishes `th`. `phase` is a second barrier for the
// few checks that need the main thread to act (e.g. server.shutdown) BETWEEN client
// steps: the client stores/spins on it to hand control back and forth.
struct BbHarness {
mut:
	th    thread string
	done  u64
	phase u64
}

// bb_await spins on the `done` barrier, then joins the client thread and returns
// its result string ("ok" on success, else a diagnostic the caller asserts on).
fn (mut h BbHarness) bb_await() string {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.th.wait()
}

// bb_spawn wires the standard shape: the hook spawns `client` (so it returns and
// the accept loop starts), then flips `done` to publish the handle. Returns a
// closure suitable for ServerConfig.after_server_start.
// (Inlined per-test below because V closures capture the specific client fn.)

// --- client workloads -----------------------------------------------------

// bb_cli_pipelining: 8 pipelined requests → 8 responses (one write), then a request
// split across two writes → 1 response (partial-read framing). "ok" or diagnostic.
fn bb_cli_pipelining(port int) string {
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }
	c.write(bb_req.repeat(8).bytes()) or { return 'write8: ${err}' }
	got := testkit.read_until_count(mut c, 'HTTP/1.1 200', 8, 2000)
	c.close() or {}
	if got != 8 {
		return 'pipelining expected 8 responses, got ${got}'
	}

	mut c2 := net.dial_tcp('127.0.0.1:${port}') or { return 'dial2: ${err}' }
	c2.write('GET / HTTP/1.1\r\nHo'.bytes()) or { return 'write2a: ${err}' }
	time.sleep(50 * time.millisecond)
	c2.write('st: x\r\n\r\n'.bytes()) or { return 'write2b: ${err}' }
	got2 := testkit.read_until_count(mut c2, 'HTTP/1.1 200', 1, 2000)
	c2.close() or {}
	if got2 != 1 {
		return 'split request expected 1 response, got ${got2}'
	}
	return 'ok'
}

// bb_cli_max_connections: hold 4 served keep-alive conns, then confirm the 5th
// (over max_connections=4) is refused / gets no response. "ok" or diagnostic.
fn bb_cli_max_connections(port int) string {
	mut conns := []&net.TcpConn{}
	for i in 0 .. 4 {
		mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial ${i}: ${err}' }
		c.write(bb_req.bytes()) or { return 'write ${i}: ${err}' }
		got := testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
		if got != 1 {
			return 'connection ${i} should be served, got ${got}'
		}
		conns << c
	}
	mut served5 := 0
	if mut c5 := net.dial_tcp('127.0.0.1:${port}') {
		c5.write(bb_req.bytes()) or {}
		served5 = testkit.read_until_count(mut c5, 'HTTP/1.1 200', 1, 1500)
		c5.close() or {}
	}
	for mut c in conns {
		c.close() or {}
	}
	if served5 != 0 {
		return 'connection over max_connections=4 must be refused, got ${served5} responses'
	}
	return 'ok'
}

// bb_cli_read_timeout: send a partial request that never completes; the server must
// END it promptly (408-then-close on epoll, EOF on io_uring) — never a 200, and
// well under the 2s client wait. "ok" or diagnostic.
fn bb_cli_read_timeout(port int) string {
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }
	c.write('GET / HTTP/1.1\r\nHo'.bytes()) or { return 'write: ${err}' } // partial: never completes
	c.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 1024}
	sw := time.new_stopwatch()
	nr := c.read(mut buf) or { 0 } // first byte of a 408, or EOF on a bare close
	elapsed := sw.elapsed().milliseconds()
	c.close() or {}
	resp := if nr > 0 { buf[..nr].bytestr() } else { '' }
	if elapsed >= 1500 {
		return 'server should end the stalled request promptly, took ${elapsed}ms'
	}
	if resp.contains('200 OK') {
		return 'stalled partial request must not be served a 200, got: ${resp}'
	}
	return 'ok'
}

// bb_cli_half_close: send a complete request, half-close the WRITE side (SHUT_WR),
// and require the full response still arrives on the open read side (RFC 9112 §9.6,
// issue #103). "ok" or diagnostic.
fn bb_cli_half_close(port int) string {
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }
	c.write(bb_req.bytes()) or { return 'write: ${err}' }
	net.shutdown(c.sock.handle, how: .write)
	got := testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 3000)
	c.close() or {}
	if got != 1 {
		return 'response must arrive after a half-close (SHUT_WR), got ${got} — issue #103'
	}
	return 'ok'
}

// bb_cli_expect_100: send the head with Expect: 100-continue and hold the body; the
// server must prompt an interim 100, then the final 200 after the body. "ok" or diag.
fn bb_cli_expect_100(port int) string {
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }
	c.write('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()) or {
		return 'write head: ${err}'
	}
	got100 := testkit.read_until_count(mut c, 'HTTP/1.1 100', 1, 3000)
	if got100 != 1 {
		return 'Expect: 100-continue must be answered with an interim 100, got ${got100}'
	}
	c.write('hello'.bytes()) or { return 'write body: ${err}' }
	got200 := testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 3000)
	c.close() or {}
	if got200 != 1 {
		return 'final response must follow the body after 100 Continue, got ${got200}'
	}
	return 'ok'
}

// bb_cli_large_upload: two 2 MiB uploads on ONE keep-alive connection. Upload 0
// probes drain-then-respond ORDERING (head + one chunk must draw NO response yet);
// upload 1 probes EXACT-drain + keep-alive. "ok" or diagnostic.
fn bb_cli_large_upload(port int) string {
	body_len := 2 * 1024 * 1024 // 2 MiB > 1 MiB threshold ⇒ drain path
	chunk := []u8{len: 64 * 1024, init: u8(0x61)}
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${body_len}\r\n\r\n'.bytes()
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }

	// Upload 0 ORDERING probe: head + ONE chunk, then the server must stay SILENT.
	c.write(head) or { return 'u0 head: ${err}' }
	c.write(chunk) or { return 'u0 chunk: ${err}' }
	c.set_read_timeout(500 * time.millisecond)
	mut probe := []u8{len: 256}
	pn := c.read(mut probe) or { 0 }
	if pn != 0 {
		return 'response arrived before the body finished — respond-before-drain (desyncs wrk/curl), got ${pn} bytes'
	}
	mut sent := chunk.len
	for sent < body_len {
		n := if body_len - sent < chunk.len { body_len - sent } else { chunk.len }
		c.write(chunk[..n]) or { return 'u0 body: ${err}' }
		sent += n
	}
	acc0 := bb_read_one_200(mut c, 5000)
	if acc0.bytestr().count('HTTP/1.1 200') != 1 {
		return 'upload 0 not answered after the body completed'
	}
	if !acc0.bytestr().contains('\r\n\r\n${body_len}') {
		return 'upload 0 must echo Content-Length ${body_len}, got: ${acc0.bytestr()#[-40..]}'
	}

	// Upload 1 EXACT-drain + keep-alive: a second full upload on the SAME connection.
	c.write(head) or { return 'u1 head: ${err}' }
	mut sent1 := 0
	for sent1 < body_len {
		n := if body_len - sent1 < chunk.len { body_len - sent1 } else { chunk.len }
		c.write(chunk[..n]) or { return 'u1 body: ${err}' }
		sent1 += n
	}
	acc1 := bb_read_one_200(mut c, 5000)
	c.close() or {}
	if acc1.bytestr().count('HTTP/1.1 200') != 1 {
		return 'keep-alive after a drained upload broke (drain over-read or under-read?)'
	}
	if !acc1.bytestr().contains('\r\n\r\n${body_len}') {
		return 'upload 1 must echo Content-Length ${body_len}, got: ${acc1.bytestr()#[-40..]}'
	}
	return 'ok'
}

// --- backend-agnostic behaviour checks ------------------------------------
// Each builds the server with an after_server_start hook that spawns the client
// workload and publishes the handle via the atomic barrier; the main thread awaits,
// tears the server down, and asserts on the returned string.

fn check_pipelining_and_framing(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_pipelining(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

fn check_max_connections(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_max_connections(port)
			stdatomic.store_u64(&h.done, 1)
		}
		limits:             Limits{
			max_connections: 4
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

fn check_read_timeout(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_read_timeout(port)
			stdatomic.store_u64(&h.done, 1)
		}
		limits:             Limits{
			read_timeout_ms: 400
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

// bb_cli_graceful: FIRST phase runs in the client thread — get served once, then
// signal `phase=1` and spin until the main thread has called server.shutdown()
// (`phase=2`), then confirm all 10 new connections are refused. The main thread
// does the shutdown + times it BETWEEN the two phases. Returns "ok" or diagnostic.
fn bb_cli_graceful(port int, mut h BbHarness) string {
	mut c := net.dial_tcp('127.0.0.1:${port}') or { return 'dial: ${err}' }
	c.write(bb_req.bytes()) or { return 'write: ${err}' }
	got := testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
	c.close() or {}
	if got != 1 {
		return 'server should serve before shutdown, got ${got}'
	}
	// Hand control to main: it will shut the server down (and time it), then set phase=2.
	stdatomic.store_u64(&h.phase, 1)
	for stdatomic.load_u64(&h.phase) != 2 {
		time.sleep(time.millisecond)
	}
	// Every listener is now stopped → all new connections refused.
	mut refused := 0
	for _ in 0 .. 10 {
		mut nc := net.dial_tcp('127.0.0.1:${port}') or {
			refused++
			continue
		}
		nc.set_read_timeout(500 * time.millisecond)
		mut b := []u8{len: 64}
		nr := nc.read(mut b) or { 0 }
		if nr <= 0 {
			refused++
		}
		nc.close() or {}
	}
	if refused != 10 {
		return 'after shutdown all 10 new connections should be refused, got ${refused}'
	}
	return 'ok'
}

fn check_graceful_shutdown(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_graceful(port, mut h)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	// Wait for the client's phase-1 signal (it has been served once), then do the
	// idle drain on THIS thread and time it, and hand phase-2 back to the client.
	for stdatomic.load_u64(&h.phase) != 1 {
		time.sleep(time.millisecond)
	}
	sw := time.new_stopwatch()
	server.shutdown(2000)
	assert sw.elapsed().milliseconds() < 1000, '${backend}: idle shutdown should be fast'
	time.sleep(100 * time.millisecond) // let the listeners fully stop before the refusal probe
	stdatomic.store_u64(&h.phase, 2)

	got := h.bb_await()
	assert got == 'ok', '${backend}: ${got}'
}

// bb_read_one_200 reads from c (up to deadline_ms) until one '200' status line has
// arrived, returning everything accumulated. Used to read a single upload response.
fn bb_read_one_200(mut c net.TcpConn, deadline_ms int) []u8 {
	c.set_read_timeout(deadline_ms * time.millisecond)
	mut buf := []u8{len: 65536}
	mut acc := []u8{}
	for acc.bytestr().count('HTTP/1.1 200') < 1 {
		nr := c.read(mut buf) or { break }
		if nr <= 0 {
			break
		}
		acc << buf[..nr]
	}
	return acc
}

// check_large_upload_drain drives bodies larger than the streaming threshold
// (sm_stream_body_above / iou_stream_body_above = 1 MiB) so they take the drain
// path: the head is answered and the body is consumed off the socket without ever
// being buffered. It guards three distinct properties:
//   • drain-then-respond ORDERING — upload 0 writes the head + only one body chunk
//     and asserts that NO response has arrived yet: the answer must be withheld
//     until the whole body is consumed. A respond-BEFORE-drain server answers here,
//     which desyncs a response-framed client (wrk/curl: it treats the request as
//     done and reinterprets the trailing body as the next request). This assertion
//     fails against an early-flush server even though byte accounting is correct.
//   • EXACT drain + keep-alive — upload 1 is a second full upload on the SAME
//     connection; it frames only if the drain consumed EXACTLY upload 0's body (no
//     over-read into this request, no under-read leaving the connection stuck) and
//     keep-alive survived the drain.
//   • the head-only handler answers by the declared Content-Length.
fn check_large_upload_drain(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_upload_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_large_upload(port)
			stdatomic.store_u64(&h.done, 1)
		}
		limits:             Limits{
			max_request_bytes: 8 * 1024 * 1024 // headroom for the 2 MiB bodies
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

// check_half_close_after_request: a client that sends a complete request and
// then half-closes its WRITE side (net.shutdown .write == shutdown(SHUT_WR))
// must still receive the full response on the still-open read side (RFC 9112
// §9.6). Regression test for issue #103, where the recv→0 (EOF) tore the
// connection down before the already-computed response was flushed.
fn check_half_close_after_request(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_half_close(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

// check_expect_100_continue: a client that sends the head with
// `Expect: 100-continue` and holds the body must be prompted with an interim
// `100 Continue` (RFC 9110 §10.1.1); after it sends the body it gets the final
// response. Without the prompt the server would wait for a body the client is
// deliberately withholding, and the request would stall.
fn check_expect_100_continue(backend IOBackend, port int) ! {
	mut h := &BbHarness{}
	mut server := new_server(ServerConfig{
		port:               port
		io_multiplexing:    backend
		handler:            bb_ok_handler
		after_server_start: fn [mut h, port] () {
			h.th = spawn bb_cli_expect_100(port)
			stdatomic.store_u64(&h.done, 1)
		}
	})!
	spawn fn [mut server] () {
		server.run()
	}()
	got := h.bb_await()
	server.shutdown(500)
	assert got == 'ok', '${backend}: ${got}'
}

// --- io_uring -------------------------------------------------------------
//
// Each io_uring test compiles only on Linux ($if linux — the .io_uring enum value
// is Linux-only) AND self-skips at runtime when io_uring_setup is blocked
// (iou_backend_available() — true of GitHub's hosted runners under seccomp). That
// lets `v test http_server/` run the whole file without a -run-only filter: the
// io_uring cases simply skip where the syscall is denied, the epoll cases run.

fn test_iouring_large_upload_drain() ! {
	$if linux {
		if iou_backend_available() {
			check_large_upload_drain(.io_uring, 8125)!
		}
	}
}

fn test_iouring_pipelining_and_framing() ! {
	$if linux {
		if iou_backend_available() {
			check_pipelining_and_framing(.io_uring, 8121)!
		}
	}
}

fn test_iouring_max_connections() ! {
	$if linux {
		if iou_backend_available() {
			check_max_connections(.io_uring, 8122)!
		}
	}
}

fn test_iouring_read_timeout() ! {
	$if linux {
		if iou_backend_available() {
			check_read_timeout(.io_uring, 8123)!
		}
	}
}

fn test_iouring_graceful_shutdown() ! {
	$if linux {
		if iou_backend_available() {
			check_graceful_shutdown(.io_uring, 8124)!
		}
	}
}

fn test_iouring_half_close_after_request() ! {
	$if linux {
		if iou_backend_available() {
			check_half_close_after_request(.io_uring, 8126)!
		}
	}
}

// --- iocp (Windows) ---------------------------------------------------------
// The same backend-agnostic checks, against the Windows IOCP backend. On
// Windows `IOBackend` has the single member `iocp` (= 0), so the casts keep
// this file compiling on every OS. (check_expect_100_continue is NOT invoked
// here: the interim-100 prompt is implemented on epoll only so far.)

fn test_iocp_large_upload_drain() ! {
	$if windows {
		check_large_upload_drain(unsafe { IOBackend(0) }, 8145)!
	}
}

fn test_iocp_pipelining_and_framing() ! {
	$if windows {
		check_pipelining_and_framing(unsafe { IOBackend(0) }, 8141)!
	}
}

fn test_iocp_max_connections() ! {
	$if windows {
		check_max_connections(unsafe { IOBackend(0) }, 8142)!
	}
}

fn test_iocp_read_timeout() ! {
	$if windows {
		check_read_timeout(unsafe { IOBackend(0) }, 8143)!
	}
}

fn test_iocp_graceful_shutdown() ! {
	$if windows {
		check_graceful_shutdown(unsafe { IOBackend(0) }, 8144)!
	}
}

fn test_iocp_half_close_after_request() ! {
	$if windows {
		check_half_close_after_request(unsafe { IOBackend(0) }, 8146)!
	}
}

// --- epoll (default backend) ----------------------------------------------

fn test_epoll_large_upload_drain() ! {
	$if linux {
		check_large_upload_drain(.epoll, 8135)!
	}
}

fn test_epoll_pipelining_and_framing() ! {
	$if linux {
		check_pipelining_and_framing(.epoll, 8131)!
	}
}

fn test_epoll_max_connections() ! {
	$if linux {
		check_max_connections(.epoll, 8132)!
	}
}

fn test_epoll_read_timeout() ! {
	$if linux {
		check_read_timeout(.epoll, 8133)!
	}
}

fn test_epoll_graceful_shutdown() ! {
	$if linux {
		check_graceful_shutdown(.epoll, 8134)!
	}
}

fn test_epoll_half_close_after_request() ! {
	$if linux {
		check_half_close_after_request(.epoll, 8136)!
	}
}

fn test_epoll_expect_100_continue() ! {
	$if linux {
		check_expect_100_continue(.epoll, 8137)!
	}
}
