module main

// End-to-end: edge (TCP, ephemeral port) → backend (UDS) over the pooled
// per-worker client conn, twice — the second request proves the depth-1
// keep-alive pool reuses the connection. Linux-only invocation (the .epoll
// enum value); the wiring mirrors main() with ephemeral everything.
import os
import time
import server
import core
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

const e2e_req = 'GET /mesh HTTP/1.1\r\nHost: e\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn e2e_read_until(fd int, needle string, timeout_ms int) string {
	mut acc := []u8{cap: 1024}
	mut buf := [1024]u8{}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < timeout_ms {
		mut pfd := C.pollfd{
			fd:     fd
			events: i16(C.POLLIN)
		}
		if C.poll(&pfd, 1, 50) <= 0 {
			continue
		}
		n := C.read(fd, voidptr(&buf[0]), usize(1024))
		if n <= 0 {
			break
		}
		unsafe { acc.push_many(&buf[0], n) }
		if acc.bytestr().contains(needle) {
			break
		}
	}
	return acc.bytestr()
}

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
				return voidptr(&EdgeState{
					socket_path: path
					req_scratch: []u8{cap: 256}
					resp_buf:    []u8{cap: 4096}
				})
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

		fd := socket_connect_loopback(edge.port) or {
			assert false, err.msg()
			return
		}
		// Two mesh calls on one client conn: the second reuses the pooled
		// worker→backend connection (and the edge's own keep-alive).
		for round in 0 .. 2 {
			assert C.write(fd, voidptr(&e2e_req[0]), usize(e2e_req.len)) == e2e_req.len
			got := e2e_read_until(fd, 'hello from the mesh', 3000)
			assert got.starts_with('HTTP/1.1 200'), 'round ${round}: ${got}'
			assert got.contains('"via":"edge"'), 'round ${round}: ${got}'
			assert got.contains('"svc":"backend"'), 'round ${round}: ${got}'
		}
		edge.shutdown(500)
		backend.shutdown(500)
	}
}

// socket_connect_loopback dials 127.0.0.1:port non-blocking and waits for
// the connect to complete (writability — the readiness path).
fn socket_connect_loopback(port int) !int {
	fd := transport.dial_tcp('127.0.0.1', port)!
	mut pfd := C.pollfd{
		fd:     fd
		events: i16(C.POLLOUT)
	}
	if C.poll(&pfd, 1, 2000) != 1 {
		transport.close_fd(fd)
		return error('connect to edge did not complete')
	}
	return fd
}
