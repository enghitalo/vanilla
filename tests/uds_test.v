// End-to-end coverage for unix-domain-socket listeners (issue #122 step 0)
// and the transport/ dial helpers (step 2): serve HTTP/1.1 over
// `unix_socket_path` on epoll and io_uring (io_uring self-skips where
// io_uring_setup is sandboxed, e.g. GitHub's hosted runners), assert prompt
// idle shutdown (the io_uring path exercises the dummy-connect wake poke —
// shutdown(2) on an AF_UNIX listener yields NO CQE), assert the socket file
// is unlinked on shutdown, and prove the path is immediately rebindable.
// Linux-only invocations: the .epoll/.io_uring enum values exist only there.
import os
import time
import server
import core
import socket
import transport

#include <poll.h>

struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u64, timeout int) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int

const uds_req = 'GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n'.bytes()
const uds_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'.bytes()

fn uds_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << uds_ok
	return .close
}

// read_until_deadline reads from a (possibly non-blocking) fd until `needle`
// appears in the accumulated bytes or `timeout_ms` elapses — poll(2)-paced,
// so a stalled stream fails the assert instead of hanging the test binary.
fn read_until_deadline(fd int, needle string, timeout_ms int) string {
	mut acc := []u8{cap: 512}
	mut buf := [512]u8{}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < timeout_ms {
		mut pfd := C.pollfd{
			fd:     fd
			events: i16(C.POLLIN)
		}
		if C.poll(&pfd, 1, 50) <= 0 {
			continue
		}
		n := C.read(fd, voidptr(&buf[0]), usize(512))
		if n == 0 {
			break // EOF
		}
		if n > 0 {
			unsafe { acc.push_many(&buf[0], n) }
			if acc.bytestr().contains(needle) {
				break
			}
		}
	}
	return acc.bytestr()
}

fn uds_socket_path(tag string) string {
	return os.join_path(os.temp_dir(), 'vanilla_uds_${tag}_${os.getpid()}.sock')
}

// serve_once_over_uds starts a server on a fresh socket path, drives one
// request through transport.dial_unix, and returns (server, path) with the
// server still running so the caller owns the shutdown assertions.
fn serve_once_over_uds(backend server.IOBackend, tag string) !(server.Server, string) {
	path := uds_socket_path(tag)
	ready := chan bool{cap: 1}
	mut srv := server.new_server(server.ServerConfig{
		unix_socket_path:   path
		io_multiplexing:    backend
		handler:            uds_handler
		after_server_start: fn [ready] () {
			ready <- true
		}
	})!
	assert srv.unix_socket_path == path
	assert srv.listener_fds.len == 1, 'UDS must use ONE shared listener (no SO_REUSEPORT group), got ${srv.listener_fds.len}'
	spawn fn [mut srv] () {
		srv.run()
	}()
	_ := <-ready
	fd := transport.dial_unix(path)!
	defer {
		transport.close_fd(fd)
	}
	assert C.write(fd, voidptr(&uds_req[0]), usize(uds_req.len)) == uds_req.len
	got := read_until_deadline(fd, 'HTTP/1.1 200', 3000)
	assert got.starts_with('HTTP/1.1 200'), '${backend}: expected a 200 over unix:${path}, got: ${got}'
	return srv, path
}

fn check_uds_serve_shutdown_rebind(backend server.IOBackend) ! {
	srv, path := serve_once_over_uds(backend, 'a')!
	// Idle shutdown must return in ~ms (precise drain), not eat the grace: on
	// io_uring this passes only because the dummy-connect poke wakes workers
	// parked on an AF_UNIX accept that listener shutdown alone never completes.
	sw := time.new_stopwatch()
	srv.shutdown(2000)
	elapsed := sw.elapsed().milliseconds()
	assert elapsed < 1500, '${backend}: idle UDS shutdown should be prompt, took ${elapsed}ms'
	assert !os.exists(path), '${backend}: shutdown must unlink the socket file'
	// The path must be immediately rebindable — a second server, same path.
	srv2, path2 := serve_once_over_uds(backend, 'a')!
	srv2.shutdown(2000)
	assert !os.exists(path2)
}

fn test_uds_epoll() {
	$if linux {
		check_uds_serve_shutdown_rebind(.epoll) or { assert false, err.msg() }
	}
}

fn test_uds_io_uring() {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('io_uring unavailable in this sandbox — skipping')
			return
		}
		check_uds_serve_shutdown_rebind(.io_uring) or { assert false, err.msg() }
	}
}

fn test_dial_unix_absent_path_errors() {
	$if linux {
		if _ := transport.dial_unix('/nonexistent/vanilla_${os.getpid()}.sock') {
			assert false, 'dial_unix to an absent path must error'
		}
	}
}

fn test_dial_tcp() {
	$if linux {
		ready := chan bool{cap: 1}
		mut srv := server.new_server(server.ServerConfig{
			port:               0
			io_multiplexing:    .epoll
			handler:            uds_handler
			after_server_start: fn [ready] () {
				ready <- true
			}
		}) or {
			assert false, err.msg()
			return
		}
		spawn fn [mut srv] () {
			srv.run()
		}()
		_ := <-ready
		fd := transport.dial_tcp('127.0.0.1', srv.port) or {
			assert false, err.msg()
			return
		}
		defer {
			transport.close_fd(fd)
		}
		// Non-blocking connect: wait for writability = connected (loopback).
		mut pfd := C.pollfd{
			fd:     fd
			events: i16(C.POLLOUT)
		}
		assert C.poll(&pfd, 1, 2000) == 1, 'dial_tcp connect did not complete'
		assert C.write(fd, voidptr(&uds_req[0]), usize(uds_req.len)) == uds_req.len
		got := read_until_deadline(fd, 'HTTP/1.1 200', 3000)
		assert got.starts_with('HTTP/1.1 200'), 'dial_tcp request failed, got: ${got}'
		srv.shutdown(2000)
	}
}

// --- peer credentials (LOCAL_IPC §6) ---------------------------------------

const cred_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\ncred-ok'.bytes()
const cred_forbidden = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

// cred_handler authorizes by kernel-verified identity instead of anything in
// the request: the caller must be THIS uid and THIS pid (the test client
// lives in the same process). That is the §6 trust model end-to-end — the
// gates who may connect, peer_cred says who each connection is.
fn cred_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	cred := socket.peer_cred(client_fd) or {
		res << cred_forbidden
		return .close
	}
	if cred.uid == os.getuid() && cred.gid >= 0 && cred.pid == os.getpid() {
		// Same-process client (this test) ⇒ pid must be OUR pid — the
		// strictest assertion available without spawning a child.
		res << cred_ok
		return .close
	}
	res << cred_forbidden
	return .close
}

fn test_uds_peer_cred() {
	$if linux {
		path := uds_socket_path('cred')
		ready := chan bool{cap: 1}
		mut srv := server.new_server(server.ServerConfig{
			unix_socket_path:   path
			io_multiplexing:    .epoll
			handler:            cred_handler
			after_server_start: fn [ready] () {
				ready <- true
			}
		}) or {
			assert false, err.msg()
			return
		}
		spawn fn [mut srv] () {
			srv.run()
		}()
		_ := <-ready
		fd := transport.dial_unix(path) or {
			assert false, err.msg()
			return
		}
		defer {
			transport.close_fd(fd)
		}
		assert C.write(fd, voidptr(&uds_req[0]), usize(uds_req.len)) == uds_req.len
		got := read_until_deadline(fd, 'cred-ok', 3000)
		assert got.contains('cred-ok'), 'peer_cred must identify this process over UDS, got: ${got}'
		// A TCP connection has no unix peer: peer_cred must answer none.
		srv.shutdown(500)
	}
}

fn test_peer_cred_none_on_tcp() {
	$if linux {
		ready := chan bool{cap: 1}
		mut srv := server.new_server(server.ServerConfig{
			port:               0
			io_multiplexing:    .epoll
			handler:            cred_handler
			after_server_start: fn [ready] () {
				ready <- true
			}
		}) or {
			assert false, err.msg()
			return
		}
		spawn fn [mut srv] () {
			srv.run()
		}()
		_ := <-ready
		fd := transport.dial_tcp('127.0.0.1', srv.port) or {
			assert false, err.msg()
			return
		}
		defer {
			transport.close_fd(fd)
		}
		mut pfd := C.pollfd{
			fd:     fd
			events: i16(C.POLLOUT)
		}
		assert C.poll(&pfd, 1, 2000) == 1
		assert C.write(fd, voidptr(&uds_req[0]), usize(uds_req.len)) == uds_req.len
		got := read_until_deadline(fd, 'HTTP/1.1 403', 3000)
		assert got.starts_with('HTTP/1.1 403'), 'peer_cred over TCP must be none (403 here), got: ${got}'
		srv.shutdown(500)
	}
}
