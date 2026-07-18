// Local-mesh demo — the first consumer of the http1_1/client codec (issue
// #122 Client story): TWO servers in one process, an EDGE on TCP and a
// BACKEND on a unix domain socket, with the edge calling the backend
// service-to-service over UDS using the readiness path the #122 client
// study measured as the portable floor:
//
//   transport.dial_unix (pooled per worker via make_state — a dial costs
//   ~4× a request, so dial-per-request would dominate) → client.write_get
//   into a reused scratch → send → event_loop.watch_fd(.readable) +
//   .suspend → recv → client.frame_response → answer from the continuation.
//
// UDS is the mesh transport on purpose: 2.3–2.7× the throughput of TCP
// loopback at ~half the CPU per request (issue #122 client study).
//
// Run:  v run examples/mesh/src
// Try:  curl http://localhost:8095/mesh   -> edge-wrapped backend answer
//       curl http://localhost:8095/       -> edge-only answer
module main

import os
import strconv
import server
import core
import transport
import http1_1.client

fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.recv(fd int, buf voidptr, n usize, flags int) int

const edge_port = 8095

const backend_body = '{"svc":"backend","msg":"hello from the mesh"}'
const backend_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${backend_body.len}\r\nConnection: keep-alive\r\n\r\n${backend_body}'.bytes()

const edge_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nedge'.bytes()
const edge_bad_gateway = 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
const edge_busy = 'HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const edge_mesh_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()
const edge_mesh_sep = '\r\nConnection: keep-alive\r\n\r\n'.bytes()
const edge_mesh_pre = '{"via":"edge","backend":'.bytes()
const edge_mesh_post = '}'.bytes()

const mesh_route = 'GET /mesh '.bytes()

// ws/wi — the zero-alloc append helpers (docs/BEST_PRACTICES.md §3b).
@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// MeshConn is one pooled upstream connection: its fd, its in-flight flag and
// its own response-accumulation buffer (each in-flight exchange needs a
// private buffer — responses interleave across connections).
struct MeshConn {
mut:
	fd       int = -1
	busy     bool
	resp_buf []u8
}

// EdgeState is THIS worker's private mesh client: a small FIXED pool of
// keep-alive UDS connections plus a reused request scratch. Lock-free by
// construction — make_state builds one per worker thread (the pg_async
// idiom), so up to mesh_pool_size /mesh calls per worker fly concurrently;
// beyond that the handler answers 503 instead of corrupting an in-flight
// exchange. Connections are dialed lazily and redialed when they go stale.
const mesh_pool_size = 4

struct EdgeState {
mut:
	socket_path string
	req_scratch []u8
	conns       [mesh_pool_size]MeshConn
}

fn backend_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << backend_response
	return .done
}

// acquire returns the index of a free pooled connection ((re)dialing it on
// demand), or -1 when the whole pool is in flight.
fn (mut st EdgeState) acquire() int {
	for i in 0 .. mesh_pool_size {
		if st.conns[i].busy {
			continue
		}
		if st.conns[i].fd < 0 {
			st.conns[i].fd = transport.dial_unix(st.socket_path) or { continue }
		}
		return i
	}
	return -1
}

// conn_by_fd maps a continuation's ready_fd back to its pool slot.
fn (mut st EdgeState) conn_by_fd(fd int) int {
	for i in 0 .. mesh_pool_size {
		if st.conns[i].fd == fd {
			return i
		}
	}
	return -1
}

fn (mut st EdgeState) drop_conn(i int) {
	if st.conns[i].fd >= 0 {
		transport.close_fd(st.conns[i].fd)
		st.conns[i].fd = -1
	}
	st.conns[i].busy = false
	st.conns[i].resp_buf.clear()
}

fn is_mesh_route(req []u8) bool {
	if req.len < mesh_route.len {
		return false
	}
	for i in 0 .. mesh_route.len {
		if req[i] != mesh_route[i] {
			return false
		}
	}
	return true
}

fn edge_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !is_mesh_route(req) {
		res << edge_ok
		return .done
	}
	mut st := unsafe { &EdgeState(worker_state) }
	ci := st.acquire()
	if ci < 0 {
		res << edge_busy // whole pool in flight on THIS worker
		return .done
	}
	fd := st.conns[ci].fd
	// Serialize the upstream request into the reused scratch and send it.
	// Small request + pooled idle connection ⇒ the socket buffer takes it in
	// one send on any realistic setup; a production client would park on
	// .writable for the partial-send case (readiness path, #122 study).
	st.req_scratch.clear()
	client.write_get(mut st.req_scratch, '/hello', 'backend.local')
	mut off := 0
	for off < st.req_scratch.len {
		n :=
			C.send(fd, unsafe { &u8(st.req_scratch.data) + off }, usize(st.req_scratch.len - off), 0)
		if n <= 0 {
			st.drop_conn(ci) // stale pooled conn (backend restarted) — fail this one
			res << edge_bad_gateway
			return .done
		}
		off += n
	}
	st.conns[ci].busy = true
	event_loop.watch_fd(fd, .readable, on_backend_reply, unsafe { nil })
	return .suspend
}

// on_backend_reply — the continuation: accumulate, frame, answer (or re-arm
// while the response is still incomplete — the multi-step chain contract).
fn on_backend_reply(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &EdgeState(worker_state) }
	ci := st.conn_by_fd(ready_fd)
	if ci < 0 {
		out << edge_bad_gateway // conn vanished from the pool (defensive)
		return .done
	}
	if ready_fd_error {
		st.drop_conn(ci)
		out << edge_bad_gateway
		return .done
	}
	mut chunk := [4096]u8{}
	n := C.recv(ready_fd, &chunk[0], usize(4096), 0)
	if n <= 0 {
		st.drop_conn(ci) // EOF/reset mid-response
		out << edge_bad_gateway
		return .done
	}
	unsafe { st.conns[ci].resp_buf.push_many(&chunk[0], n) }
	total := client.frame_response(st.conns[ci].resp_buf)
	if total == client.incomplete {
		event_loop.watch_fd(ready_fd, .readable, on_backend_reply, unsafe { nil })
		return .suspend
	}
	if total < 0 {
		st.drop_conn(ci) // unframeable upstream — drop the (desynced) conn too
		out << edge_bad_gateway
		return .done
	}
	if client.status_code(st.conns[ci].resp_buf) != 200 {
		st.conns[ci].busy = false
		st.conns[ci].resp_buf.clear()
		out << edge_bad_gateway
		return .done
	}
	// Frame the edge reply around the DECODED backend body without `${}`/`+`
	// — append_body handles Content-Length and chunked upstreams alike, so a
	// scratch assembly is needed to know the decoded length first.
	st.req_scratch.clear()
	if !client.append_body(mut st.req_scratch, st.conns[ci].resp_buf, total) {
		st.drop_conn(ci)
		out << edge_bad_gateway
		return .done
	}
	wb(mut out, edge_mesh_head)
	wi(mut out, i64(edge_mesh_pre.len + st.req_scratch.len + edge_mesh_post.len))
	wb(mut out, edge_mesh_sep)
	wb(mut out, edge_mesh_pre)
	wb(mut out, st.req_scratch)
	wb(mut out, edge_mesh_post)
	// Exchange complete — the pooled keep-alive conn is free for the next call.
	st.conns[ci].busy = false
	st.conns[ci].resp_buf.clear()
	return .done
}

fn mesh_socket_path() string {
	return os.join_path(os.temp_dir(), 'vanilla_mesh_${os.getpid()}.sock')
}

// new_edge_state builds one worker's client state (make_state target). The
// pool slots are explicitly reset — fixed-array elements don't run struct
// field defaults, so fd must be forced to "not dialed yet".
fn new_edge_state(path string) voidptr {
	mut st := &EdgeState{
		socket_path: path
		req_scratch: []u8{cap: 4096}
	}
	for i in 0 .. mesh_pool_size {
		st.conns[i].fd = -1
		st.conns[i].resp_buf = []u8{cap: 4096}
	}
	return voidptr(st)
}

fn main() {
	path := mesh_socket_path()
	backend_ready := chan bool{cap: 1}
	mut backend := server.new_server(server.ServerConfig{
		unix_socket_path:   path
		handler:            backend_handler
		after_server_start: fn [backend_ready] () {
			backend_ready <- true
		}
	})!
	spawn fn [mut backend] () {
		backend.run()
	}()
	_ := <-backend_ready

	mut edge := server.new_server(server.ServerConfig{
		port:       edge_port
		handler:    edge_handler
		make_state: fn [path] () voidptr {
			return new_edge_state(path)
		}
	})!
	println('mesh up: edge http://localhost:${edge_port}/mesh -> backend unix:${path}')
	edge.run()
}
