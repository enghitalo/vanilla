module main

// The pool reuses a backend connection only when the response allows it
// (#229): the client.Framer frames a close-delimited body at the close, and
// says whether the connection may carry the next call. Against a fake backend
// on a unix socket that counts its accepts:
//
//   mode 1: a body delimited by closing the connection → relayed whole, and
//           every call re-dials;
//   mode 2: Content-Length + `Connection: close`, the connection left open →
//           every call re-dials;
//   mode 0: keep-alive → one dial, then the connection is reused.
//
// Its own file, so its own process: a server stopped by an earlier test in the
// same process can keep accepting on a reused listener fd number (#163).
import os
import time
import server
import socket
import transport
import vtest
import sync.stdatomic

#include <sys/socket.h>

const reuse_req = 'GET /mesh HTTP/1.1\r\nHost: e\r\n\r\n'.bytes()

const close_delimited_reply = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n${backend_body}'.bytes()
const connection_close_reply = 'HTTP/1.1 200 OK\r\nContent-Length: ${backend_body.len}\r\nConnection: close\r\n\r\n${backend_body}'.bytes()

struct ReuseBackend {
mut:
	mode    i64
	accepts i64
}

const reuse_backend = &ReuseBackend{}

fn test_mesh_reuse_follows_the_framer() {
	$if linux {
		mut f := unsafe { reuse_backend }
		path := os.join_path(os.temp_dir(), 'vanilla_mesh_reuse_${os.getpid()}.sock')
		lfd := socket.create_unix_server_socket(path) or {
			assert false, err.msg()
			return
		}
		socket.set_blocking(lfd, true)
		spawn reuse_backend_accept(lfd)
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
		want_body := '{"via":"edge","backend":${backend_body}}'
		mut want_accepts := i64(0)
		for mode in [i64(1), 2, 0] {
			stdatomic.store_i64(&f.mode, mode)
			for i in 0 .. 3 {
				o := h.fire([vtest.Script{
					rounds: [vtest.Round{
						send: reuse_req
						want: 1
					}]
				}]) or {
					assert false, err.msg()
					return
				}
				assert o.conns[0].frames.len == 1, 'mode ${mode} call ${i}: ${o.conns[0].raw.bytestr()}'
				got := o.conns[0].frames[0].bytestr()
				assert got.starts_with('HTTP/1.1 200') && got.ends_with(want_body), 'mode ${mode} call ${i}: ${got}'
				// Modes 1 and 2 dial every call; the last mode-2 connection is
				// dropped too, so mode 0 dials once, then reuses its connection.
				if mode != 0 || i == 0 {
					want_accepts++
				}
				for _ in 0 .. 200 {
					if stdatomic.load_i64(&f.accepts) >= want_accepts {
						break
					}
					time.sleep(5 * time.millisecond)
				}
				assert stdatomic.load_i64(&f.accepts) == want_accepts, 'mode ${mode} call ${i}'
			}
		}
	}
}

fn reuse_backend_accept(lfd int) {
	mut f := unsafe { reuse_backend }
	for {
		fd := socket.accept_client(lfd)
		if fd < 0 {
			return
		}
		socket.set_blocking(fd, true)
		stdatomic.add_i64(&f.accepts, 1)
		spawn reuse_backend_conn(fd)
	}
}

// reuse_backend_conn answers each request (no body) on one connection with the
// reply the current mode asks for.
fn reuse_backend_conn(fd int) {
	mut f := unsafe { reuse_backend }
	defer {
		transport.close_fd(fd)
	}
	mut acc := []u8{}
	mut buf := [4096]u8{}
	for {
		n := C.recv(fd, &buf[0], usize(buf.len), 0)
		if n <= 0 {
			return
		}
		unsafe { acc.push_many(&buf[0], n) }
		for {
			end := acc.bytestr().index('\r\n\r\n') or { break }
			acc = acc[end + 4..].clone()
			mode := stdatomic.load_i64(&f.mode)
			reply := match mode {
				1 { close_delimited_reply }
				2 { connection_close_reply }
				else { backend_response.bytes() }
			}
			mut off := 0
			for off < reply.len {
				w := C.send(fd, unsafe { &reply[off] }, usize(reply.len - off), C.MSG_NOSIGNAL)
				if w <= 0 {
					return
				}
				off += w
			}
			if mode == 1 {
				return // the close ends the body
			}
		}
	}
}
