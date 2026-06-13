module http_server

// Behavioural end-to-end tests for the connection state machine: HTTP/1.1
// pipelining, request framing across TCP segments, max_connections, read
// timeout, and graceful shutdown. They drive a real server (spawned on a
// thread) with raw client sockets via the `net` module.
//
// These backends are Linux-only, so every test is a no-op elsewhere. Timing
// assertions use wide margins (server timeouts are set small, client waits
// large) so the tests assert behaviour, not exact latency.
import net
import time

fn bb_ok_handler(req []u8, fd int, mut out []u8) ! {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
}

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
// answers (or panics after ~3s). The caller owns `server`, so the spawned
// thread's reference stays valid for the test's lifetime.
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

const bb_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'

// --- io_uring -------------------------------------------------------------

fn test_iouring_pipelining_and_framing() {
	$if linux {
		port := 8121
		mut server := new_server(ServerConfig{
			port:            port
			io_multiplexing: .io_uring
			request_handler: bb_ok_handler
		})!
		bb_start(mut server, port)

		// 8 requests in ONE write must yield 8 responses (the pipelining fix).
		mut c := net.dial_tcp('127.0.0.1:${port}')!
		c.write(bb_req.repeat(8).bytes())!
		got := read_until_count(mut c, 'HTTP/1.1 200', 8, 2000)
		c.close() or {}
		assert got == 8, 'io_uring pipelining: expected 8 responses, got ${got}'

		// A request split across two writes must frame correctly (partial-read fix).
		mut c2 := net.dial_tcp('127.0.0.1:${port}')!
		c2.write('GET / HTTP/1.1\r\nHo'.bytes())!
		time.sleep(50 * time.millisecond)
		c2.write('st: x\r\n\r\n'.bytes())!
		got2 := read_until_count(mut c2, 'HTTP/1.1 200', 1, 2000)
		c2.close() or {}
		assert got2 == 1, 'io_uring split request: expected 1 response, got ${got2}'

		server.shutdown(500)
	}
}

fn test_iouring_max_connections() {
	$if linux {
		port := 8122
		mut server := new_server(ServerConfig{
			port:            port
			io_multiplexing: .io_uring
			request_handler: bb_ok_handler
			limits:          Limits{
				max_connections: 4
			}
		})!
		bb_start(mut server, port)
		time.sleep(200 * time.millisecond) // let the readiness probe's close settle

		// Hold 4 served keep-alive connections (each accept counted before its 200).
		mut conns := []&net.TcpConn{}
		for i in 0 .. 4 {
			mut c := net.dial_tcp('127.0.0.1:${port}')!
			c.write(bb_req.bytes())!
			got := read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
			assert got == 1, 'connection ${i} should be served, got ${got}'
			conns << c
		}
		// The 5th is over the cap: the server accepts then immediately closes it,
		// so the client sees no response (EOF), or the connect itself is refused.
		mut served5 := 0
		if mut c5 := net.dial_tcp('127.0.0.1:${port}') {
			c5.write(bb_req.bytes()) or {}
			served5 = read_until_count(mut c5, 'HTTP/1.1 200', 1, 1500)
			c5.close() or {}
		}
		for mut c in conns {
			c.close() or {}
		}
		assert served5 == 0, 'connection over max_connections=4 must be refused, got ${served5} responses'

		server.shutdown(500)
	}
}

fn test_iouring_read_timeout() {
	$if linux {
		port := 8123
		mut server := new_server(ServerConfig{
			port:            port
			io_multiplexing: .io_uring
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
		nr := c.read(mut buf) or { 0 } // EOF on server-side close, or 0 if it errors
		elapsed := sw.elapsed().milliseconds()
		c.close() or {}
		// read_timeout (400ms) + sweep interval (250ms) ⇒ the server closes the
		// stalled request well under the 2s client wait. If the timeout did NOT
		// fire, the read would block until the 2s client timeout instead.
		assert nr <= 0, 'stalled partial request should get no response, read ${nr} bytes'
		assert elapsed < 1500, 'server should close the stalled request promptly, took ${elapsed}ms'

		server.shutdown(500)
	}
}

fn test_iouring_graceful_shutdown() {
	$if linux {
		port := 8124
		mut server := new_server(ServerConfig{
			port:            port
			io_multiplexing: .io_uring
			request_handler: bb_ok_handler
		})!
		bb_start(mut server, port)

		// Serves before shutdown.
		mut c := net.dial_tcp('127.0.0.1:${port}')!
		c.write(bb_req.bytes())!
		got := read_until_count(mut c, 'HTTP/1.1 200', 1, 2000)
		c.close() or {}
		assert got == 1, 'server should serve before shutdown, got ${got}'

		// Idle drain returns promptly.
		sw := time.new_stopwatch()
		server.shutdown(2000)
		assert sw.elapsed().milliseconds() < 1000, 'idle shutdown should be fast'

		// Every listener is now stopped → all new connections refused (the fix:
		// previously only worker 0's listener was closed).
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
		assert refused == 10, 'after shutdown all 10 new connections should be refused, got ${refused}'
	}
}

// --- epoll (default backend) ----------------------------------------------

fn test_epoll_pipelining() {
	$if linux {
		port := 8125
		mut server := new_server(ServerConfig{
			port:            port
			io_multiplexing: .epoll
			request_handler: bb_ok_handler
		})!
		bb_start(mut server, port)

		mut c := net.dial_tcp('127.0.0.1:${port}')!
		c.write(bb_req.repeat(8).bytes())!
		got := read_until_count(mut c, 'HTTP/1.1 200', 8, 2000)
		c.close() or {}
		assert got == 8, 'epoll pipelining: expected 8 responses, got ${got}'

		server.shutdown(500)
	}
}
