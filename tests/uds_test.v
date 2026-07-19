// End-to-end coverage for unix-domain-socket listeners (issue #122 step 0)
// and the transport/ dial helpers (step 2): serve HTTP/1.1 over
// `unix_socket_path` on epoll and io_uring (io_uring self-skips where
// io_uring_setup is sandboxed, e.g. GitHub's hosted runners), assert prompt
// idle shutdown (the io_uring path exercises the dummy-connect wake poke —
// shutdown(2) on an AF_UNIX listener yields NO CQE), assert the socket file
// is unlinked on shutdown, and prove the path is immediately rebindable.
// Client plumbing is transport.dial_* + testkit's fd_* deadline loops; the
// scripted protocol behaviour over UDS is vtest's job (test_uds_vtest_scripts
// below — a UDS e2e is a TCP e2e plus one config line).
// Linux-only invocations: the .epoll/.io_uring enum values exist only there.
import os
import time
import server
import core
import socket
import testkit
import transport
import vtest

const uds_req = 'GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n'.bytes()
const uds_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'.bytes()

fn uds_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << uds_ok
	return .close
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
	assert testkit.fd_write_all(fd, uds_req, 2000)
	got := testkit.fd_read_until(fd, 'HTTP/1.1 200', 3000)
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
		assert testkit.fd_wait_writable(fd, 2000), 'dial_tcp connect did not complete'
		assert testkit.fd_write_all(fd, uds_req, 2000)
		got := testkit.fd_read_until(fd, 'HTTP/1.1 200', 3000)
		assert got.starts_with('HTTP/1.1 200'), 'dial_tcp request failed, got: ${got}'
		srv.shutdown(2000)
	}
}

// --- scripted protocol behaviour over UDS (vtest) --------------------------

const uds_keep_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

fn uds_keep_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << uds_keep_ok
	return .done
}

// The issue-#122 step-2 promise made concrete: vtest drives UDS exactly like
// TCP — the ONLY difference from a TCP script test is the unix_socket_path
// config line (fire() dials through transport.dial_unix instead of dial_tcp).
// Two concurrent connections against the single shared UDS listener: one
// pipelines 4 requests in one write then keeps the connection alive for a
// 5th, the other is a plain request — and drive()'s shutdown must leave
// nothing in flight and unlink the socket file.
fn test_uds_vtest_scripts() {
	$if linux {
		path := uds_socket_path('vtest')
		mut pipelined := []u8{cap: uds_req.len * 4}
		for _ in 0 .. 4 {
			pipelined << 'GET / HTTP/1.1\r\nHost: local\r\n\r\n'.bytes()
		}
		out := vtest.drive(server.ServerConfig{
			unix_socket_path: path
			io_multiplexing:  .epoll
			handler:          uds_keep_handler
		}, [
			vtest.Script{
				rounds: [
					vtest.Round{
						send: pipelined
						want: 4
					},
					vtest.Round{
						send: 'GET / HTTP/1.1\r\nHost: local\r\n\r\n'.bytes()
						want: 1
					},
				]
			},
			vtest.Script{
				rounds: [
					vtest.Round{
						send: 'GET / HTTP/1.1\r\nHost: local\r\n\r\n'.bytes()
					},
				]
			},
		]) or {
			assert false, err.msg()
			return
		}
		pipe := out.conns[0]
		assert pipe.connect_err == '', pipe.connect_err
		assert pipe.frames.len == 5, 'UDS pipelining + keep-alive expected 5 responses, got ${pipe.frames.len}'
		for f in pipe.frames {
			assert f == uds_keep_ok
		}
		single := out.conns[1]
		assert single.connect_err == '', single.connect_err
		assert single.frames.len == 1
		assert out.inflight_after == 0
		assert !os.exists(path), 'drive() shutdown must unlink the socket file'
	}
}

// --- peer credentials (LOCAL_IPC §6) ---------------------------------------

const cred_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\ncred-ok'.bytes()
const cred_forbidden = 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

// cred_handler authorizes by kernel-verified identity instead of anything in
// the request: the caller must be THIS uid and THIS pid (the test client
// lives in the same process). That is the §6 trust model end-to-end — the
// path gates who may connect, peer_cred says who each connection is.
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
		assert testkit.fd_write_all(fd, uds_req, 2000)
		got := testkit.fd_read_until(fd, 'cred-ok', 3000)
		assert got.contains('cred-ok'), 'peer_cred must identify this process over UDS, got: ${got}'
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
		assert testkit.fd_wait_writable(fd, 2000)
		assert testkit.fd_write_all(fd, uds_req, 2000)
		// A TCP connection has no unix peer: peer_cred must answer none (403).
		got := testkit.fd_read_until(fd, 'HTTP/1.1 403', 3000)
		assert got.starts_with('HTTP/1.1 403'), 'peer_cred over TCP must be none (403 here), got: ${got}'
		srv.shutdown(500)
	}
}
