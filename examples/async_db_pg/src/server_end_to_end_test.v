module main

// End-to-end: the example's own handler, on_db_ready and build_pool (make_state)
// against a FAKE PostgreSQL — a few lines of wire protocol (AuthenticationOk,
// then one canned reply per Sync) — so it needs no database. The fake can HOLD
// replies, which parks every /db on its pooled connection long enough for the
// clients to disconnect mid-query (vanilla#190). Linux-only (epoll backend).
import os
import time
import server
import socket
import transport
import testkit
import vtest
import sync.stdatomic

#include <sys/socket.h>

fn C.recv(fd int, buf voidptr, n usize, flags int) int
fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.close(fd int) int

const db_req = 'GET /db HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// The rows the fake returns, with a `"` and a `\` that must come back escaped.
const fake_rows = ['alpha', 'be"ta', 'gam\\ma']

const want_body = r'[{"id":1,"name":"alpha"},{"id":2,"name":"be\"ta"},{"id":3,"name":"gam\\ma"}]'

const want_resp = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${want_body.len}\r\nConnection: keep-alive\r\n\r\n${want_body}'.bytes()

const fake_reply = build_fake_reply()

// FakePg is the fake server's state, shared by its threads and the test
// (atomics only).
struct FakePg {
mut:
	hold     i64 // 1: a query's reply waits until this is cleared
	held     i64 // queries received while hold was set
	eofs     i64 // pooled connections the server side closed
	kill     i64 // 1: the next reply is sent, then that connection is closed (and this cleared)
	killed   i64 // connections closed that way
	startups i64 // connections that completed the startup
}

const fake = &FakePg{}

fn test_parked_client_disconnects_do_not_leak_pool_slots() {
	$if linux {
		mut f := unsafe { fake }
		lfd := socket.create_server_socket(0)
		socket.set_blocking(lfd, true)
		port := socket.local_port(lfd)
		spawn fake_pg_accept(lfd)
		os.setenv('PGHOST', '127.0.0.1', true)
		os.setenv('PGPORT', port.str(), true)
		os.setenv('PGUSER', 'vanilla', true)
		os.setenv('PGPASSWORD', '', true)
		os.setenv('PGDATABASE', 'vanilla', true)
		stdatomic.store_i64(&f.hold, 1)
		mut h := vtest.start(server.ServerConfig{
			handler:    handler
			make_state: build_pool
			workers:    1
		}) or {
			assert false, err.msg()
			return
		}
		defer {
			h.stop()
		}

		// One /db per pool slot, each parked on its pooled connection with the
		// reply held: the whole pool is busy.
		mut clients := []int{}
		for _ in 0 .. pool_size {
			fd := transport.dial_tcp('127.0.0.1', h.port()) or {
				assert false, err.msg()
				return
			}
			assert testkit.fd_write_all(fd, db_req, 2000)
			clients << fd
		}
		assert settle(fn () bool {
			mut g := unsafe { fake }
			return stdatomic.load_i64(&g.held) == pool_size
		}), 'only ${stdatomic.load_i64(&f.held)} of ${pool_size} queries reached the database'

		// Every client disconnects mid-query; wait until the worker tore each
		// connection down (with its parked request).
		for fd in clients {
			transport.close_fd(fd)
		}
		srv := h.server_ref()
		assert settle(fn [srv] () bool {
			return stdatomic.load_i64(&srv.active_conns.n) == 0
		}), 'the server did not notice the disconnects'
		assert stdatomic.load_i64(&f.eofs) == 0, 'a client disconnect closed a pooled PostgreSQL connection'

		// The replies arrive now, for requests nobody waits for. Their
		// continuations must still drain them and release the slots: then
		// pool_size + 1 more /db all get 200, not 503. (A 503 can show up only
		// until those continuations ran; a leaked slot never comes back.)
		stdatomic.store_i64(&f.hold, 0)
		for i in 0 .. pool_size + 1 {
			got := db_until_not_503(mut h)
			assert got == want_resp, 'request ${i}: ${got.bytestr()}'
		}
		assert stdatomic.load_i64(&f.eofs) == 0, 'a pooled PostgreSQL connection was closed'
	}
}

// db_until_not_503 sends GET /db on a fresh connection, again while the pool
// sheds it (503), within a bound; returns the last response.
fn db_until_not_503(mut h vtest.Harness) []u8 {
	mut last := []u8{}
	for _ in 0 .. 300 {
		o := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: db_req
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

// --- the fake PostgreSQL ------------------------------------------------------

fn fake_pg_accept(lfd int) {
	for {
		fd := socket.accept_client(lfd)
		if fd < 0 {
			return
		}
		socket.set_blocking(fd, true)
		spawn fake_pg_conn(fd)
	}
}

// fake_pg_conn serves one pooled connection: trust auth, then for every query
// (everything up to its Sync) the canned reply, held while hold is set.
fn fake_pg_conn(fd int) {
	mut f := unsafe { fake }
	defer {
		C.close(fd)
	}
	// StartupMessage: a self-inclusive int32 length, no type byte.
	len_bytes := read_exact(fd, 4) or { return }
	read_exact(fd, be32(len_bytes, 0) - 4) or { return }
	mut ready := []u8{}
	pg_msg(mut ready, `R`, [u8(0), 0, 0, 0]) // AuthenticationOk
	pg_msg(mut ready, `Z`, [u8(`I`)])
	stdatomic.add_i64(&f.startups, 1)
	send_all(fd, ready)
	for {
		head := read_exact(fd, 5) or {
			stdatomic.add_i64(&f.eofs, 1)
			return
		}
		read_exact(fd, be32(head, 1) - 4) or {
			stdatomic.add_i64(&f.eofs, 1)
			return
		}
		match head[0] {
			`X` {
				return // Terminate
			}
			`S` {
				if stdatomic.load_i64(&f.hold) == 1 {
					stdatomic.add_i64(&f.held, 1)
					for stdatomic.load_i64(&f.hold) == 1 {
						if peer_closed(fd) {
							stdatomic.add_i64(&f.eofs, 1)
							return
						}
						time.sleep(time.millisecond)
					}
				}
				send_all(fd, fake_reply)
				if stdatomic.load_i64(&f.kill) == 1 {
					// The server side ends this connection right after the
					// reply: a restart / pg_terminate_backend, as the pool sees it.
					stdatomic.store_i64(&f.kill, 0)
					stdatomic.add_i64(&f.killed, 1)
					return
				}
			}
			else {} // Parse / Bind / Describe / Execute
		}
	}
}

// build_fake_reply is one query's full reply: ParseComplete, BindComplete, a
// DataRow per fake row (binary int4 id, text name), CommandComplete,
// ReadyForQuery.
fn build_fake_reply() []u8 {
	mut out := []u8{}
	pg_msg(mut out, `1`, []u8{})
	pg_msg(mut out, `2`, []u8{})
	for i, name in fake_rows {
		mut row := [u8(0), 2] // two columns
		put32(mut row, 4)
		put32(mut row, i + 1)
		put32(mut row, name.len)
		row << name.bytes()
		pg_msg(mut out, `D`, row)
	}
	pg_msg(mut out, `C`, 'SELECT 3\0'.bytes())
	pg_msg(mut out, `Z`, [u8(`I`)])
	return out
}

fn pg_msg(mut out []u8, typ u8, payload []u8) {
	out << typ
	put32(mut out, payload.len + 4)
	out << payload
}

fn put32(mut out []u8, n int) {
	out << u8(n >> 24)
	out << u8(n >> 16)
	out << u8(n >> 8)
	out << u8(n)
}

fn be32(b []u8, i int) int {
	return int(u32(b[i]) << 24 | u32(b[i + 1]) << 16 | u32(b[i + 2]) << 8 | u32(b[i + 3]))
}

fn read_exact(fd int, n int) ?[]u8 {
	mut buf := []u8{len: n}
	mut got := 0
	for got < n {
		r := C.recv(fd, unsafe { &buf[got] }, usize(n - got), 0)
		if r <= 0 {
			return none
		}
		got += r
	}
	return buf
}

fn send_all(fd int, b []u8) {
	mut off := 0
	for off < b.len {
		n := C.send(fd, unsafe { &b[off] }, usize(b.len - off), C.MSG_NOSIGNAL)
		if n <= 0 {
			return
		}
		off += n
	}
}

// peer_closed reports whether the server side closed the connection (EOF).
fn peer_closed(fd int) bool {
	mut b := u8(0)
	return C.recv(fd, &b, 1, C.MSG_PEEK | C.MSG_DONTWAIT) == 0
}

// A connection the server closes (vanilla#191) is never handed out again: the
// query it carried got its reply, the next requests use the other connections,
// and the maintenance timer (on_worker_start) re-dials it — so no /db fails.
fn test_connections_the_server_closes_are_redialed() {
	$if linux {
		mut f := unsafe { fake }
		stdatomic.store_i64(&f.hold, 0)
		lfd := socket.create_server_socket(0)
		socket.set_blocking(lfd, true)
		port := socket.local_port(lfd)
		spawn fake_pg_accept(lfd)
		os.setenv('PGHOST', '127.0.0.1', true)
		os.setenv('PGPORT', port.str(), true)
		os.setenv('PGUSER', 'vanilla', true)
		os.setenv('PGPASSWORD', '', true)
		os.setenv('PGDATABASE', 'vanilla', true)
		base := stdatomic.load_i64(&f.startups)
		mut h := vtest.start(server.ServerConfig{
			handler:         handler
			make_state:      build_pool
			on_worker_start: start_maintenance
			workers:         1
		}) or {
			assert false, err.msg()
			return
		}
		defer {
			h.stop()
		}
		// The worker brings its pool up in make_state, which may still be
		// running when the server starts accepting.
		startups0 := base + pool_size
		assert settle(fn [startups0] () bool {
			g := unsafe { fake }
			return stdatomic.load_i64(&g.startups) >= startups0
		})
		for i in 0 .. 3 * pool_size {
			stdatomic.store_i64(&f.kill, 1) // this reply is its connection's last
			// The first answer, not a retry: no request is ever given the dead
			// connection, so none is shed or fails.
			o := h.fire([
				vtest.Script{
					rounds: [vtest.Round{
						send: db_req
						want: 1
					}]
				},
			]) or {
				assert false, err.msg()
				return
			}
			got := if o.conns[0].frames.len > 0 { o.conns[0].frames[0] } else { o.conns[0].raw }
			assert got == want_resp, 'request ${i}: ${got.bytestr()}'
			// The closed connection is re-dialed before the next request.
			assert settle(fn [startups0, i] () bool {
				g := unsafe { fake }
				return stdatomic.load_i64(&g.startups) >= startups0 + i + 1
			}), 'not re-dialed after request ${i}'
		}
		assert stdatomic.load_i64(&f.killed) >= 3 * pool_size
	}
}
