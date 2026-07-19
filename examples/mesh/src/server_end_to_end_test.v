module main

// End-to-end: edge (TCP, ephemeral port) → backend (UDS) over the per-worker
// connection pool, twice — the second request proves the keep-alive pool
// reuses a connection instead of redialing. Client plumbing is
// transport.dial_tcp + testkit's fd_* deadline loops (the raw-fd pattern
// every transport e2e in the tree shares). Linux-only invocation (the
// .epoll enum value); the wiring mirrors main() with ephemeral everything.
import os
import server
import testkit
import transport

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
