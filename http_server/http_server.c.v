module http_server

import socket
import time
import sync.stdatomic
import http_server.core
import http_server.backend_epoll
import http_server.tls

const max_thread_pool_size = core.max_thread_pool_size

// Limits is re-exported from `core` so the public config API stays ergonomic
// (`http_server.Limits{...}`). The real definition lives in `core` because the
// backend reads it too, and `core` is the leaf both sides depend on.
pub type Limits = core.Limits

pub struct Server {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = unsafe { IOBackend(0) }
	socket_fd       int
	limits          Limits
	tls_config      &tls.Config = unsafe { nil } // nil ⇒ plain HTTP; set ⇒ HTTPS
pub mut:
	threads         []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	request_handler fn ([]u8, int) ![]u8 @[required]
	// Per-worker in-flight request counters (one per worker, each on its own
	// cache line — written only by its worker, so no contention/false sharing).
	// shutdown() sums them to drain precisely.
	inflight        []&core.Counter = []&core.Counter{len: max_thread_pool_size, init: &core.Counter{}}
	// Global count of open connections (incremented at accept, decremented at
	// close) — enforces max_connections. Touched per CONNECTION, not per request.
	active_conns    &core.Counter = &core.Counter{}
}

// shutdown performs a graceful stop: it closes the listening socket so the
// kernel refuses NEW connections, then waits up to `grace_ms` for in-flight
// request handling to finish before the caller exits the process.
//
// The drain is PRECISE: it sums the per-worker in-flight counters and returns
// the instant they all hit zero, so an idle server shuts down in ~milliseconds
// rather than waiting the whole grace. The counters are per-worker and each on
// its own cache line, so the per-request increment is uncontended and free on
// the hot path (measured: no throughput change). Idle keep-alive connections
// hold no in-flight work, so they're simply dropped on exit.
//
// Call it from a signal handler, then `exit(0)`. It is safe to call from another
// thread while `run()` is blocked in the accept loop: closing the listener fd
// stops new accepts; existing workers finish their current request.
pub fn (s Server) shutdown(grace_ms int) {
	socket.close_socket(s.socket_fd)
	// Precise drain: poll the per-worker in-flight counters and return as soon
	// as they all reach zero (or the grace deadline elapses). An idle server
	// shuts down in ~1 ms instead of waiting the full grace.
	mut waited := 0
	for waited < grace_ms {
		mut active := i64(0)
		for c in s.inflight {
			active += stdatomic.load_i64(&c.n)
		}
		if active == 0 {
			break
		}
		time.sleep(time.millisecond)
		waited++
	}
}

fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.close(__fd int) int

// Test method: send raw HTTP requests directly to the server socket, process sequentially, and shutdown after last response.
pub fn (mut s Server) test(requests [][]u8) ![][]u8 {
	println('[test] Starting server thread...')

	$if windows {
		socket.init_winsock() or { return error('Failed to initialize Winsock: ${err}') }
	}

	// Use a channel to signal when the server is ready
	ready_ch := chan bool{cap: 1}
	mut threads := []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	spawn fn [mut s, mut threads, ready_ch] () {
		println('[test] Server backend setup...')
		ready_ch <- true
		$if linux {
			match s.io_multiplexing {
				.epoll {
					println('[test] Running epoll backend')
					backend_epoll.run_epoll_backend(s.socket_fd, s.request_handler, s.port, s.limits, s.inflight,
						s.active_conns, s.tls_config, mut threads)
				}
				.io_uring {
					println('[test] Running io_uring backend')
					run_io_uring_backend(s.request_handler, s.port, mut threads)
				}
			}
		} $else $if darwin {
			println('[test] Running kqueue backend')
			run_kqueue_backend(s.socket_fd, s.request_handler, s.port, mut threads)
		} $else $if windows {
			println('[test] Running IOCP backend')
			run_iocp_backend(s.socket_fd, s.request_handler, s.port, mut threads)
		} $else {
			eprintln('Unsupported OS for http_server.')
			exit(1)
		}
	}()

	// Wait for the server to signal readiness
	_ := <-ready_ch
	println('[test] Server signaled ready, connecting client...')

	mut responses := [][]u8{cap: requests.len}
	client_fd := socket.connect_to_server(s.port) or {
		eprintln('[test] Failed to connect to server: ${err}')
		return err
	}

	println('[test] Client connected, sending requests...')
	for i, req in requests {
		println('[test] Preparing to send request #${i + 1} (${req.len} bytes)')
		mut sent := 0
		for sent < req.len {
			println('[test] Sending bytes ${sent}..${sent + (req.len - sent)}')
			n := C.send(client_fd, &req[sent], req.len - sent, 0)
			if n <= 0 {
				println('[test] Failed to send request at byte ${sent}')
				C.close(client_fd)
				return error('Failed to send request')
			}
			sent += n
		}
		println('[test] Sent request #${i + 1}, now receiving response...')
		mut buf := []u8{len: 0, cap: 4096}
		mut tmp := [4096]u8{}
		for {
			println('[test] Waiting to receive response bytes...')
			n := C.recv(client_fd, &tmp[0], 4096, 0)
			println('[test] recv returned ${n}')
			if n <= 0 {
				break
			}
			buf << tmp[..n]
			// Try to parse Content-Length if present
			resp_str := buf.bytestr()
			if resp_str.index('\r\n\r\n') != none {
				header_end := resp_str.index('\r\n\r\n') or {
					return error('Failed to find end of headers in response')
				}
				headers := resp_str[..header_end]
				content_length_marker := 'Content-Length: '
				if headers.index(content_length_marker) != none {
					content_length_idx := headers.index(content_length_marker) or {
						return error('Failed to find Content-Length in headers')
					}
					start := content_length_idx + content_length_marker.len
					if headers.index_after('\r\n', start) != none {
						end := headers.index_after('\r\n', start) or {
							return error('Failed to find end of Content-Length header line')
						}
						content_length_str := headers[start..end].trim_space()
						content_length := content_length_str.int()
						total_len := header_end + 4 + content_length
						if buf.len >= total_len {
							break
						}
					} else {
						content_length_str := headers[start..].trim_space()
						content_length := content_length_str.int()
						total_len := header_end + 4 + content_length
						if buf.len >= total_len {
							break
						}
					}
				} else {
					// No Content-Length, just break after headers
					break
				}
			}
		}
		println('[test] Received response #${i + 1} (${buf.len} bytes)')
		responses << buf.clone()
	}

	C.close(client_fd)
	println('[test] Client closed, shutting down server socket...')
	// Shutdown server after last response
	socket.close_socket(s.socket_fd)

	$if windows {
		socket.cleanup_winsock()
	}

	println('[test] Test complete, returning responses')
	return responses
}

pub struct Certificates {
pub:
	cert_pem    []u8
	key_pem     []u8
	ca_cert_pem []u8
}

pub struct ServerConfig {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = unsafe { IOBackend(0) }
	request_handler fn ([]u8, int) ![]u8 @[required]
	certificates    Certificates
	limits          Limits
	tls_config      &tls.Config = unsafe { nil } // set for HTTPS (e.g. tls.new_self_signed())
}

pub fn new_server(config ServerConfig) !Server {
	socket_fd := socket.create_server_socket(config.port)

	// Set default backend based on OS
	io_multiplexing := config.io_multiplexing
	$if windows {
		if io_multiplexing != .iocp {
			return error('Windows only supports IOCP backend')
		}
	} $else $if linux {
		if io_multiplexing != .epoll && io_multiplexing != .io_uring {
			return error('Linux only supports epoll and io_uring backends')
		}
	} $else $if darwin {
		if io_multiplexing != .kqueue {
			return error('macOS only supports kqueue backend')
		}
	}

	return Server{
		port:            config.port
		io_multiplexing: config.io_multiplexing
		socket_fd:       socket_fd
		request_handler: config.request_handler
		limits:          config.limits
		tls_config:      config.tls_config
		threads:         []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	}
}
