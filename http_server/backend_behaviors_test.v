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

// count_marker counts non-overlapping occurrences of `needle` in `haystack`.
fn count_marker(haystack []u8, needle string) int {
	if needle.len == 0 || haystack.len < needle.len {
		return 0
	}
	mut count := 0
	mut i := 0
	for i <= haystack.len - needle.len {
		mut hit := true
		for j in 0 .. needle.len {
			if haystack[i + j] != needle[j] {
				hit = false
				break
			}
		}
		if hit {
			count++
			i += needle.len
		} else {
			i++
		}
	}
	return count
}

// read_until_count reads until `needle` has appeared `want` times, the peer
// closes, or `deadline_ms` elapses; returns how many were seen.
fn read_until_count(mut c net.TcpConn, needle string, want int, deadline_ms int) int {
	c.set_read_timeout(deadline_ms * time.millisecond)
	mut acc := []u8{}
	mut buf := []u8{len: 65536}
	for {
		nr := c.read(mut buf) or { break }
		if nr <= 0 {
			break
		}
		acc << buf[..nr]
		if count_marker(acc, needle) >= want {
			break
		}
	}
	return count_marker(acc, needle)
}

// bb_start spawns `server.run()` on a thread and blocks until the server
// answers (or panics after ~3s). The CALLER owns `server`, so the spawned
// thread's reference stays valid for the test's lifetime; after the test
// returns the run() thread only sleeps / blocks in the event loop and the
// workers use copied parameters, so it never dereferences the freed value.
fn bb_start(mut server Server, port int) {
	spawn fn [mut server] () {
		server.run()
	}()
	for _ in 0 .. 200 {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			time.sleep(15 * time.millisecond)
			continue
		}
		c.close() or {}
		return
	}
	panic('server never came up on port ${port}')
}

// --- backend-agnostic behaviour checks ------------------------------------

fn check_pipelining_and_framing(backend IOBackend, port int) ! {
	mut server := new_server(ServerConfig{
		port:            port
		io_multiplexing: backend
		handler:         bb_ok_handler
	})!
	bb_start(mut server, port)

	// 8 requests in ONE write must yield 8 responses (pipelining).
	mut c := net.dial_tcp('127.0.0.1:${port}')!
	c.write(bb_req.repeat(8).bytes())!
	got := read_until_count(mut c, 'HTTP/1.1 200', 8, 2000)
	c.close() or {}
	assert got == 8, '${backend}: pipelining expected 8 responses, got ${got}'

	// A request split across two writes must frame correctly (partial reads).
	mut c2 := net.dial_tcp('127.0.0.1:${port}')!
	c2.write('GET / HTTP/1.1\r\nHo'.bytes())!
	time.sleep(50 * time.millisecond)
	c2.write('st: x\r\n\r\n'.bytes())!
	got2 := read_until_count(mut c2, 'HTTP/1.1 200', 1, 2000)
	c2.close() or {}
	assert got2 == 1, '${backend}: split request expected 1 response, got ${got2}'

	server.shutdown(500)
}

fn check_max_connections(backend IOBackend, port int) ! {
	mut server := new_server(ServerConfig{
		port:            port
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          Limits{
			max_connections: 4
		}
	})!
	bb_start(mut server, port)
	time.sleep(200 * time.millisecond) // let the readiness probe's close settle

	// Hold 4 served keep-alive connections (each accept is counted before its 200).
	mut conns := []&net.TcpConn{}
	for i in 0 .. 4 {
		mut c := net.dial_tcp('127.0.0.1:${port}')!
		c.write(bb_req.bytes())!
		got := read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
		assert got == 1, '${backend}: connection ${i} should be served, got ${got}'
		conns << c
	}
	// The 5th is over the cap: the server accepts then immediately closes it (no
	// response / EOF), or the connect itself is refused.
	mut served5 := 0
	if mut c5 := net.dial_tcp('127.0.0.1:${port}') {
		c5.write(bb_req.bytes()) or {}
		served5 = read_until_count(mut c5, 'HTTP/1.1 200', 1, 1500)
		c5.close() or {}
	}
	for mut c in conns {
		c.close() or {}
	}
	assert served5 == 0, '${backend}: connection over max_connections=4 must be refused, got ${served5} responses'

	server.shutdown(500)
}

fn check_read_timeout(backend IOBackend, port int) ! {
	mut server := new_server(ServerConfig{
		port:            port
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          Limits{
			read_timeout_ms: 400
		}
	})!
	bb_start(mut server, port)

	mut c := net.dial_tcp('127.0.0.1:${port}')!
	c.write('GET / HTTP/1.1\r\nHo'.bytes())! // partial: never completes
	c.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 1024}
	sw := time.new_stopwatch()
	nr := c.read(mut buf) or { 0 } // first byte of a 408, or EOF on a bare close
	elapsed := sw.elapsed().milliseconds()
	c.close() or {}
	resp := if nr > 0 { buf[..nr].bytestr() } else { '' }
	// read_timeout (400ms) + sweep interval (250ms) ⇒ the server acts on the
	// stalled request well under the 2s client wait. If the timeout did NOT fire,
	// the read would block until the 2s client timeout instead — caught by the
	// elapsed bound. The two backends end a timed-out partial request differently
	// (both correct): epoll sends a 408 then closes; io_uring half-closes (EOF).
	// Either way the partial must NEVER be answered with a normal 200.
	assert elapsed < 1500, '${backend}: server should end the stalled request promptly, took ${elapsed}ms'
	assert !resp.contains('200 OK'), '${backend}: stalled partial request must not be served a 200, got: ${resp}'

	server.shutdown(500)
}

fn check_graceful_shutdown(backend IOBackend, port int) ! {
	mut server := new_server(ServerConfig{
		port:            port
		io_multiplexing: backend
		handler:         bb_ok_handler
	})!
	bb_start(mut server, port)

	// Serves before shutdown.
	mut c := net.dial_tcp('127.0.0.1:${port}')!
	c.write(bb_req.bytes())!
	got := read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
	c.close() or {}
	assert got == 1, '${backend}: server should serve before shutdown, got ${got}'

	// Idle drain returns promptly.
	sw := time.new_stopwatch()
	server.shutdown(2000)
	assert sw.elapsed().milliseconds() < 1000, '${backend}: idle shutdown should be fast'

	// Every listener is now stopped → all new connections refused. (For io_uring
	// this is the fix: previously only worker 0's listener was closed.)
	time.sleep(100 * time.millisecond)
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
	assert refused == 10, '${backend}: after shutdown all 10 new connections should be refused, got ${refused}'
}

// bb_read_one_200 reads from c (up to deadline_ms) until one '200' status line has
// arrived, returning everything accumulated. Used to read a single upload response.
fn bb_read_one_200(mut c net.TcpConn, deadline_ms int) []u8 {
	c.set_read_timeout(deadline_ms * time.millisecond)
	mut buf := []u8{len: 65536}
	mut acc := []u8{}
	for count_marker(acc, 'HTTP/1.1 200') < 1 {
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
	mut server := new_server(ServerConfig{
		port:            port
		io_multiplexing: backend
		handler:         bb_upload_handler
		limits:          Limits{
			max_request_bytes: 8 * 1024 * 1024 // headroom for the 2 MiB bodies
		}
	})!
	bb_start(mut server, port)

	body_len := 2 * 1024 * 1024 // 2 MiB > 1 MiB threshold ⇒ drain path
	chunk := []u8{len: 64 * 1024, init: u8(0x61)}
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${body_len}\r\n\r\n'.bytes()
	mut c := net.dial_tcp('127.0.0.1:${port}')!

	// ── Upload 0: ORDERING probe ──
	// Send the head + ONE chunk (body far from complete), then assert the server
	// stays SILENT: drain-then-respond must withhold the answer until the body is
	// fully drained. An early answer here is the respond-before-drain bug.
	c.write(head)!
	c.write(chunk)!
	c.set_read_timeout(500 * time.millisecond)
	mut probe := []u8{len: 256}
	pn := c.read(mut probe) or { 0 }
	assert pn == 0, '${backend}: response arrived before the body finished — respond-before-drain (desyncs wrk/curl), got ${pn} bytes'
	// Finish upload 0's body; now the response must arrive, echoing the declared length.
	mut sent := chunk.len
	for sent < body_len {
		n := if body_len - sent < chunk.len { body_len - sent } else { chunk.len }
		c.write(chunk[..n])!
		sent += n
	}
	acc0 := bb_read_one_200(mut c, 5000)
	assert count_marker(acc0, 'HTTP/1.1 200') == 1, '${backend}: upload 0 not answered after the body completed'
	assert acc0.bytestr().contains('\r\n\r\n${body_len}'), '${backend}: upload 0 must echo Content-Length ${body_len}, got: ${acc0.bytestr()#[-40..]}'

	// ── Upload 1: EXACT-drain + keep-alive guard ──
	// A second full upload on the SAME connection must frame correctly.
	c.write(head)!
	mut sent1 := 0
	for sent1 < body_len {
		n := if body_len - sent1 < chunk.len { body_len - sent1 } else { chunk.len }
		c.write(chunk[..n])!
		sent1 += n
	}
	acc1 := bb_read_one_200(mut c, 5000)
	c.close() or {}
	assert count_marker(acc1, 'HTTP/1.1 200') == 1, '${backend}: keep-alive after a drained upload broke (drain over-read or under-read?)'
	assert acc1.bytestr().contains('\r\n\r\n${body_len}'), '${backend}: upload 1 must echo Content-Length ${body_len}, got: ${acc1.bytestr()#[-40..]}'

	server.shutdown(500)
}

// --- io_uring -------------------------------------------------------------

fn test_iouring_large_upload_drain() ! {
	$if linux {
		check_large_upload_drain(.io_uring, 8125)!
	}
}

fn test_iouring_pipelining_and_framing() ! {
	$if linux {
		check_pipelining_and_framing(.io_uring, 8121)!
	}
}

fn test_iouring_max_connections() ! {
	$if linux {
		check_max_connections(.io_uring, 8122)!
	}
}

fn test_iouring_read_timeout() ! {
	$if linux {
		check_read_timeout(.io_uring, 8123)!
	}
}

fn test_iouring_graceful_shutdown() ! {
	$if linux {
		check_graceful_shutdown(.io_uring, 8124)!
	}
}

// --- iocp (Windows) ---------------------------------------------------------
// The same backend-agnostic checks, against the Windows IOCP backend. On
// Windows `IOBackend` has the single member `iocp` (= 0), so the casts keep
// this file compiling on every OS.

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
