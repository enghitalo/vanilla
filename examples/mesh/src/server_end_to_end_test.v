module main

// End-to-end: edge (TCP, ephemeral port) → backend (UDS) over the per-worker
// connection pool, twice — the second request proves the keep-alive pool
// reuses a connection instead of redialing. Client plumbing is
// transport.dial_tcp + testkit's fd_* deadline loops (the raw-fd pattern
// every transport e2e in the tree shares). Linux-only invocation (the
// .epoll enum value); the wiring mirrors main() with ephemeral everything.
import os
import time
import server
import socket
import testkit
import transport
import vtest
import sync.stdatomic

#include <sys/socket.h>

const e2e_req = 'GET /mesh HTTP/1.1\r\nHost: e\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn test_mesh_end_to_end() {
	$if linux {
		path := os.join_path(os.temp_dir(), 'vanilla_mesh_e2e_${os.getpid()}.sock')
		backend_ready := chan bool{cap: 1}
		mut backend := server.new_server(server.ServerConfig{
			unix_socket_path:   path
			handler:            backend_handler
			after_server_start: fn [backend_ready] () {
				backend_ready <- true
			}
		}) or {
			assert false, err.msg()
			return
		}
		spawn fn [mut backend] () {
			backend.run()
		}()
		_ := <-backend_ready

		edge_ready := chan bool{cap: 1}
		mut edge := server.new_server(server.ServerConfig{
			port:               0
			handler:            edge_handler
			make_state:         fn [path] () voidptr {
				return new_edge_state(path)
			}
			after_server_start: fn [edge_ready] () {
				edge_ready <- true
			}
		}) or {
			assert false, err.msg()
			return
		}
		spawn fn [mut edge] () {
			edge.run()
		}()
		_ := <-edge_ready

		fd := transport.dial_tcp('127.0.0.1', edge.port) or {
			assert false, err.msg()
			return
		}
		defer {
			transport.close_fd(fd)
		}
		// Non-blocking connect: writable == connected (loopback).
		assert testkit.fd_wait_writable(fd, 2000), 'connect to edge did not complete'
		// Two mesh calls on one client conn: the second reuses the pooled
		// worker→backend connection (and the edge's own keep-alive).
		for round in 0 .. 2 {
			assert testkit.fd_write_all(fd, e2e_req, 2000)
			got := testkit.fd_read_until(fd, 'hello from the mesh', 3000)
			assert got.starts_with('HTTP/1.1 200'), 'round ${round}: ${got}'
			assert got.contains('"via":"edge"'), 'round ${round}: ${got}'
			assert got.contains('"svc":"backend"'), 'round ${round}: ${got}'
		}
		edge.shutdown(500)
		backend.shutdown(500)
	}
}

// A pooled upstream fd must outlive the clients parked on it (vanilla#190):
// mesh_pool_size /mesh calls park on the pool with the backend's replies held,
// every client disconnects mid-call, then the replies arrive. The pool must
// keep its connections and get every slot back: mesh_pool_size + 1 more calls
// all answer 200, not 503. The backend is a fake on a unix socket that can
// hold its replies.
fn test_mesh_parked_client_disconnects_do_not_leak_pool_slots() {
	$if linux {
		mut f := unsafe { fake_backend }
		path := os.join_path(os.temp_dir(), 'vanilla_mesh_hold_${os.getpid()}.sock')
		lfd := socket.create_unix_server_socket(path) or {
			assert false, err.msg()
			return
		}
		socket.set_blocking(lfd, true)
		spawn fake_backend_accept(lfd)
		stdatomic.store_i64(&f.hold, 1)
		mut h := vtest.start(server.ServerConfig{
			handler:    edge_handler
			workers:    1
			make_state: fn [path] () voidptr {
				return new_edge_state(path)
			}
		}) or {
			assert false, err.msg()
			return
		}
		defer {
			h.stop()
			socket.unlink_socket_path(path)
		}
		mut clients := []int{}
		for _ in 0 .. mesh_pool_size {
			fd := transport.dial_tcp('127.0.0.1', h.port()) or {
				assert false, err.msg()
				return
			}
			assert testkit.fd_write_all(fd, e2e_req, 2000)
			clients << fd
		}
		assert settle(fn () bool {
			mut g := unsafe { fake_backend }
			return stdatomic.load_i64(&g.held) == mesh_pool_size
		}), 'only ${stdatomic.load_i64(&f.held)} of ${mesh_pool_size} calls reached the backend'
		for fd in clients {
			transport.close_fd(fd)
		}
		srv := h.server_ref()
		assert settle(fn [srv] () bool {
			return stdatomic.load_i64(&srv.active_conns.n) == 0
		}), 'the edge did not notice the disconnects'
		assert stdatomic.load_i64(&f.eofs) == 0, 'a client disconnect closed a pooled backend connection'
		// The held replies arrive for calls nobody waits for; a 503 can show
		// up only until their continuations ran.
		stdatomic.store_i64(&f.hold, 0)
		for i in 0 .. mesh_pool_size + 1 {
			got := mesh_until_not_503(mut h).bytestr()
			assert got.starts_with('HTTP/1.1 200') && got.contains('hello from the mesh'), 'call ${i}: ${got}'
		}
		assert stdatomic.load_i64(&f.eofs) == 0, 'a pooled backend connection was closed'
	}
}

// mesh_until_not_503 sends GET /mesh on a fresh connection, again while the
// pool sheds it (503), within a bound; returns the last response.
fn mesh_until_not_503(mut h vtest.Harness) []u8 {
	mut last := []u8{}
	for _ in 0 .. 300 {
		o := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: e2e_req
					want: 1
				}]
			},
		]) or { return err.msg().bytes() }
		if o.conns[0].frames.len == 0 {
			return o.conns[0].raw
		}
		last = o.conns[0].frames[0].clone()
		if !last.bytestr().starts_with('HTTP/1.1 503') {
			return last
		}
		time.sleep(10 * time.millisecond)
	}
	return last
}

// settle polls cond for up to 5 s.
fn settle(cond fn () bool) bool {
	for _ in 0 .. 1000 {
		if cond() {
			return true
		}
		time.sleep(5 * time.millisecond)
	}
	return cond()
}

// FakeBackend is the holding backend's state, shared by its threads and the
// test (atomics only).
struct FakeBackend {
mut:
	hold i64 // 1: a request's reply waits until this is cleared
	held i64 // requests received while hold was set
	eofs i64 // pooled connections the edge closed
}

const fake_backend = &FakeBackend{}

fn fake_backend_accept(lfd int) {
	for {
		fd := socket.accept_client(lfd)
		if fd < 0 {
			return
		}
		socket.set_blocking(fd, true)
		spawn fake_backend_conn(fd)
	}
}

// fake_backend_conn answers each request (no body) on one keep-alive
// connection with backend_response, held while hold is set.
fn fake_backend_conn(fd int) {
	mut f := unsafe { fake_backend }
	defer {
		transport.close_fd(fd)
	}
	mut acc := []u8{}
	mut buf := [4096]u8{}
	for {
		n := C.recv(fd, &buf[0], usize(buf.len), 0)
		if n <= 0 {
			stdatomic.add_i64(&f.eofs, 1)
			return
		}
		unsafe { acc.push_many(&buf[0], n) }
		for {
			end := acc.bytestr().index('\r\n\r\n') or { break }
			acc = acc[end + 4..].clone()
			if stdatomic.load_i64(&f.hold) == 1 {
				stdatomic.add_i64(&f.held, 1)
				for stdatomic.load_i64(&f.hold) == 1 {
					mut b := u8(0)
					if C.recv(fd, &b, 1, C.MSG_PEEK | C.MSG_DONTWAIT) == 0 {
						stdatomic.add_i64(&f.eofs, 1)
						return
					}
					time.sleep(time.millisecond)
				}
			}
			mut off := 0
			for off < backend_response.len {
				w := C.send(fd, unsafe { &backend_response[off] }, usize(backend_response.len - off),
					C.MSG_NOSIGNAL)
				if w <= 0 {
					return
				}
				off += w
			}
		}
	}
}
