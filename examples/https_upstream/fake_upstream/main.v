// fake_upstream — a scriptable fake third-party HTTP(S) API for the
// http1_1/upstream client's end-to-end tests (../src/upstream_e2e_test.v,
// which builds and starts it as its own process).
//
// usage: fake_upstream --port-file F --stats-file S [--bind IP] [--tls CERTDIR [--cert server|wronghost]]
//
// Listens on 127.0.0.1:<ephemeral>, or on --bind's address (::1); the port
// goes to --port-file once it listens. One thread per connection. With --tls
// it serves TLS 1.3 through vanilla's own tls server side, with
// CERTDIR/<cert>.crt / .key (from pg_async/testdata/gen_test_ca.sh).
// Keep-alive HTTP/1.1; the path picks the answer:
//
//   /ok           200, Content-Length JSON (HEAD: no body)
//   /host         200, the request's Host field value as the body
//   /chunked      200, chunked body "hello world" with a trailer
//   /continue     100 Continue, then 201 Created "ok"
//   /nocontent    204
//   /connclose    200 + Connection: close, then closes
//   /close        200, body delimited by closing the connection (TLS: close_notify first)
//   /trunc        200, close-delimited body, then a bare close (TLS: no close_notify)
//   /idleclose    200, then closes the idle connection after 100 ms
//   /drop         reads the request, closes without answering
//   /slow         never answers (until the client goes away)
//   /echo         200, the request body's length and sha256 (hex)
//   /cont100      100 Continue right after the head, then as /echo once the body is in
//   /delay/<ms>   200, after <ms> milliseconds
//   /big/<n>      200, an n-byte body
//   /e413         413 + Connection: close right after the head; reads nothing more for 1 s
//
// The stats file holds key=value lines: accepted, handshakes, requests, and
// path:<path>=<count>.
//
// It exits within 200 ms of its parent process (the test) exiting: a test that
// panics never runs its deferred stop(), and a fake left behind would keep the
// test binary's stdout/stderr open, so `v test` would wait for their EOF
// instead of reporting the failure.
module main

import os
import sync
import time
import crypto.sha256
import tls
import transport

#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>

fn C.socket(domain int, typ int, protocol int) int
fn C.bind(fd int, addr voidptr, len u32) int
fn C.listen(fd int, backlog int) int
fn C.accept(fd int, addr voidptr, len voidptr) int
fn C.getsockname(fd int, addr voidptr, len &u32) int
fn C.setsockopt(fd int, level int, name int, val voidptr, len u32) int
fn C.recv(fd int, buf voidptr, n usize, flags int) int
fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.shutdown(fd int, how int) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.poll(fds voidptr, n u64, timeout int) int

const ok_body = '{"status":"paid"}'
const ok_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${ok_body.len}\r\n\r\n'
const chunked_resp = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: abc\r\n\r\n'
const xs = []u8{len: 65536, init: `x`}

// io_wait_ms bounds every wait on a peer: a stalled test fails, it never hangs here.
const io_wait_ms = 10_000

@[heap]
struct App {
mut:
	cfg        &tls.Config = unsafe { nil }
	mu         &sync.Mutex = sync.new_mutex()
	counts     map[string]int
	stats_path string
}

// bump counts one event and rewrites the stats file (atomically: a reader sees
// the old file or the new one).
fn (mut a App) bump(key string) {
	a.mu.lock()
	a.counts[key] = a.counts[key] + 1
	mut lines := []string{}
	for k, v in a.counts {
		lines << '${k}=${v}'
	}
	tmp := a.stats_path + '.tmp'
	os.write_file(tmp, lines.join('\n') + '\n') or {}
	os.mv(tmp, a.stats_path) or {}
	a.mu.unlock()
}

// Conn is one accepted connection: a non-blocking socket, and its TLS session
// when serving TLS. Every call waits with poll(2), bounded by io_wait_ms.
struct Conn {
mut:
	fd   int
	sess tls.Session
}

// wait polls the socket for `events` (POLLIN / POLLOUT) up to `ms`. EINTR
// (the GC stops threads with signals) is no answer: poll again.
fn (c &Conn) wait(events int, ms int) bool {
	mut p := [2]i32{} // struct pollfd: int fd; short events, revents
	p[0] = i32(c.fd)
	p[1] = i32(events)
	for {
		r := C.poll(voidptr(&p[0]), 1, ms)
		if r < 0 && C.errno == C.EINTR {
			continue
		}
		return r > 0
	}
	return false
}

fn (mut c Conn) handshake() bool {
	for {
		r := c.sess.handshake()
		if r == 0 {
			return true
		}
		if r == tls.want {
			if !c.wait(C.POLLIN, io_wait_ms) {
				return false
			}
			c.sess.mark_readable()
		} else if r == tls.want_write {
			if !c.wait(C.POLLOUT, io_wait_ms) {
				return false
			}
		} else {
			return false // the client gave up (a certificate it does not trust)
		}
	}
	return false
}

// read appends what arrives to buf: the byte count, 0 at the peer's close, -1
// on an error or after io_wait_ms.
fn (mut c Conn) read(mut buf []u8) int {
	if buf.cap - buf.len < 16384 {
		unsafe { buf.grow_cap(buf.cap + 65536) }
	}
	p := unsafe { &u8(buf.data) + buf.len }
	room := buf.cap - buf.len
	for {
		mut n := 0
		if c.sess.active() {
			n = c.sess.read_into(p, room)
			if n == tls.want {
				if !c.wait(C.POLLIN, io_wait_ms) {
					return -1
				}
				c.sess.mark_readable()
				continue
			}
			if n == tls.want_write {
				if !c.wait(C.POLLOUT, io_wait_ms) {
					return -1
				}
				continue
			}
			if n < 0 {
				return if c.sess.peer_closed() { 0 } else { -1 }
			}
		} else {
			n = C.recv(c.fd, p, usize(room), 0)
			if n < 0 {
				if C.errno == C.EINTR {
					continue
				}
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
					if !c.wait(C.POLLIN, io_wait_ms) {
						return -1
					}
					continue
				}
				return -1
			}
		}
		unsafe {
			buf.len += n
		}
		return n
	}
	return -1
}

// write sends all of b; false if the peer went away.
fn (mut c Conn) write(b []u8) bool {
	mut off := 0
	mut wlen := 0 // a TLS record to retry with the same length
	for off < b.len {
		if c.sess.active() {
			l := if wlen > 0 {
				wlen
			} else if b.len - off > 16384 {
				16384
			} else {
				b.len - off
			}
			n := c.sess.write_from(unsafe { &u8(b.data) + off }, l)
			if n > 0 {
				off += n
				wlen = 0
				continue
			}
			if n == tls.want || n == tls.want_write {
				wlen = l
				if !c.wait(if n == tls.want { C.POLLIN } else { C.POLLOUT }, io_wait_ms) {
					return false
				}
				if n == tls.want {
					c.sess.mark_readable()
				}
				continue
			}
			return false
		}
		n := C.send(c.fd, unsafe { &u8(b.data) + off }, usize(b.len - off), C.MSG_NOSIGNAL)
		if n > 0 {
			off += n
			continue
		}
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			if !c.wait(C.POLLOUT, io_wait_ms) {
				return false
			}
			continue
		}
		return false
	}
	return true
}

fn (mut c Conn) write_str(s string) bool {
	return c.write(s.bytes())
}

// close ends the connection: over TLS with a close_notify first.
fn (mut c Conn) close() {
	if c.sess.active() {
		c.sess.free() // sends close_notify
		c.sess = tls.Session{}
	}
	C.close(c.fd)
}

// close_bare ends the connection with a bare FIN: over TLS no close_notify
// (the socket is shut down before the session goes).
fn (mut c Conn) close_bare() {
	C.shutdown(c.fd, C.SHUT_RDWR)
	c.close()
}

// wait_closed waits, answering nothing, until the client goes away (or 60 s).
fn (mut c Conn) wait_closed() {
	sw := time.new_stopwatch()
	mut scratch := []u8{cap: 4096}
	for sw.elapsed().seconds() < 60 {
		if !c.wait(C.POLLIN, 50) {
			continue
		}
		scratch.clear()
		if c.read(mut scratch) <= 0 {
			return
		}
	}
}

fn head_end(buf []u8) int {
	for i in 3 .. buf.len {
		if buf[i] == `\n` && buf[i - 1] == `\r` && buf[i - 2] == `\n` && buf[i - 3] == `\r` {
			return i + 1
		}
	}
	return -1
}

// field is the value of the head's first `name` field (lowercase name), ''
// when absent.
fn field(head string, name string) string {
	for line in head.split('\r\n')[1..] {
		if line.all_before(':').trim_space().to_lower() == name {
			return line.all_after(':').trim_space()
		}
	}
	return ''
}

fn serve(mut a App, fd int) {
	a.bump('accepted')
	C.fcntl(fd, C.F_SETFL, C.fcntl(fd, C.F_GETFL, 0) | C.O_NONBLOCK)
	mut c := Conn{
		fd: fd
	}
	if a.cfg != unsafe { nil } {
		c.sess = a.cfg.new_session(fd) or {
			C.close(fd)
			return
		}
		if !c.handshake() {
			c.close()
			return
		}
		a.bump('handshakes')
	}
	mut buf := []u8{cap: 65536}
	for {
		mut he := head_end(buf)
		for he < 0 {
			if c.read(mut buf) <= 0 {
				c.close()
				return
			}
			he = head_end(buf)
		}
		head := buf[..he].bytestr()
		line := head.all_before('\r\n').split(' ')
		method := line[0]
		path := if line.len > 1 { line[1] } else { '' }
		a.bump('requests')
		a.bump('path:' + path)
		n := field(head, 'content-length').int()
		if path == '/e413' {
			c.write_str('HTTP/1.1 413 Content Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
			time.sleep(time.second) // reads nothing more meanwhile
			c.close()
			return
		}
		if path == '/cont100' {
			c.write_str('HTTP/1.1 100 Continue\r\n\r\n')
		}
		for buf.len < he + n {
			if c.read(mut buf) <= 0 {
				c.close()
				return
			}
		}
		body := buf[he..he + n].clone()
		rest := buf[he + n..].clone()
		buf.clear()
		buf << rest
		match true {
			path == '/ok' {
				c.write_str(if method == 'HEAD' { ok_head } else { ok_head + ok_body })
			}
			path == '/host' {
				h := field(head, 'host')
				c.write_str('HTTP/1.1 200 OK\r\nContent-Length: ${h.len}\r\n\r\n${h}')
			}
			path == '/chunked' {
				c.write_str(chunked_resp)
			}
			path == '/continue' {
				c.write_str('HTTP/1.1 100 Continue\r\n\r\n')
				time.sleep(20 * time.millisecond)
				c.write_str('HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok')
			}
			path == '/nocontent' {
				c.write_str('HTTP/1.1 204 No Content\r\n\r\n')
			}
			path == '/connclose' {
				c.write_str('HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok')
				c.close()
				return
			}
			path == '/close' {
				c.write_str('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose-delimited body')
				c.close()
				return
			}
			path == '/trunc' {
				c.write_str('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\ncut sho')
				c.close_bare()
				return
			}
			path == '/idleclose' {
				c.write_str(ok_head + ok_body)
				time.sleep(100 * time.millisecond)
				c.close()
				return
			}
			path == '/drop' {
				c.close()
				return
			}
			path == '/slow' {
				c.wait_closed()
				c.close()
				return
			}
			path == '/echo' || path == '/cont100' {
				b := '${body.len} ${sha256.sum(body).hex()}'
				c.write_str('HTTP/1.1 200 OK\r\nContent-Length: ${b.len}\r\n\r\n${b}')
			}
			path.starts_with('/delay/') {
				time.sleep(path.all_after('/delay/').int() * time.millisecond)
				c.write_str(ok_head + ok_body)
			}
			path.starts_with('/big/') {
				size := path.all_after('/big/').int()
				c.write_str('HTTP/1.1 200 OK\r\nContent-Length: ${size}\r\n\r\n')
				mut left := size
				for left > 0 {
					k := if left > xs.len { xs.len } else { left }
					if !c.write(unsafe { (&u8(xs.data)).vbytes(k) }) {
						break
					}
					left -= k
				}
			}
			else {
				c.write_str('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
			}
		}
	}
}

fn main() {
	// Once the parent is gone this process is re-parented: getppid() changes.
	parent := os.getppid()
	spawn fn [parent] () {
		for os.getppid() == parent {
			time.sleep(200 * time.millisecond)
		}
		exit(0)
	}()
	mut port_file := ''
	mut stats_file := ''
	mut bind := '127.0.0.1'
	mut certs := ''
	mut cert := 'server'
	for i := 1; i + 1 < os.args.len; i += 2 {
		match os.args[i] {
			'--port-file' { port_file = os.args[i + 1] }
			'--stats-file' { stats_file = os.args[i + 1] }
			'--bind' { bind = os.args[i + 1] }
			'--tls' { certs = os.args[i + 1] }
			'--cert' { cert = os.args[i + 1] }
			else { panic('fake_upstream: unknown option ${os.args[i]}') }
		}
	}
	if port_file == '' || stats_file == '' {
		eprintln('usage: fake_upstream --port-file F --stats-file S [--bind IP] [--tls CERTDIR [--cert server|wronghost]]')
		exit(2)
	}
	mut app := &App{
		stats_path: stats_file
	}
	if certs != '' {
		app.cfg = tls.new_from_pem(os.read_bytes(os.join_path(certs, cert + '.crt'))!,
			os.read_bytes(os.join_path(certs, cert + '.key'))!)!
	}
	mut a := transport.ip_addr(bind, 0) or { panic('fake_upstream: bad --bind ${bind}') }
	lfd := C.socket(a.family, C.SOCK_STREAM, 0)
	one := i32(1)
	C.setsockopt(lfd, C.SOL_SOCKET, C.SO_REUSEADDR, &one, 4)
	if C.bind(lfd, voidptr(&a.data[0]), a.len) != 0 || C.listen(lfd, 128) != 0 {
		panic('fake_upstream: cannot listen')
	}
	mut sl := u32(a.data.len)
	C.getsockname(lfd, voidptr(&a.data[0]), &sl)
	port := (int(a.data[2]) << 8) | int(a.data[3]) // sin_port / sin6_port, network order
	os.write_file(port_file + '.tmp', port.str())!
	os.mv(port_file + '.tmp', port_file)!
	for {
		fd := C.accept(lfd, unsafe { nil }, unsafe { nil })
		if fd < 0 {
			if C.errno == C.EINTR {
				continue
			}
			panic('fake_upstream: accept failed (errno ${C.errno})')
		}
		spawn serve(mut app, fd)
	}
}
