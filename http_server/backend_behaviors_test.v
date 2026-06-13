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

fn bb_ok_handler(req []u8, fd int, mut out []u8) ! {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
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
		request_handler: bb_ok_handler
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
		request_handler: bb_ok_handler
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
		request_handler: bb_ok_handler
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
		request_handler: bb_ok_handler
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

// --- io_uring -------------------------------------------------------------

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

// --- epoll (default backend) ----------------------------------------------

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
