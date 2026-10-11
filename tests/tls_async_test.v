// vtest build: linux && vanilla_tls?
// HTTPS connections on the epoll worker's own state machine and reactor
// (backend_epoll/tls_conn_linux.c.v): what the old TLS worker could not do,
// over TLS:
//   * .suspend: a request parked on a watch is answered by its continuation,
//     and the requests pipelined behind it after it, in order;
//   * park deadlines: Limits.park_timeout_ms answers a hung park with 504;
//   * a parked request's client leaving cleanly (close_notify, then FIN) is
//     noticed at once, while one that pipelined a request and then a FIN is
//     answered when the park ends;
//   * on_worker_start: a clientless timer watch armed on every worker;
//   * takeover and server push: a line protocol over TLS, a post from the
//     test thread delivered through the mailbox, and .closed exactly once;
//   * a .close sends all of its response, then closes, whatever the socket
//     takes per write (vanilla#275: one best-effort write before);
//   * a large upload is streamed (drained) rather than buffered, and
//     Expect: 100-continue gets its interim 100 before the body;
//   * a request pipelined behind a large file the worker could not send at
//     once is held until the file is out (no read deadline meanwhile), and
//     an Expect: 100-continue head held so, or read while parked, gets its
//     100 once it is its turn.
// Each case runs over userspace Mbed TLS (set_ktls(false)) and, when the
// `tls` kernel module is loaded, over kTLS.
//
//   v -cc gcc -d vanilla_tls test tests/tls_async_test.v
//
// The client is vlib's net.openssl, as in tls_timeouts_test.v (not
// net.mbedtls: its bundled Mbed TLS clashes with the -lmbedtls the server
// links). Its read timeout is only a hang backstop.
import os
import time
import net.openssl
import server
import core
import tls
import sync
import sync.stdatomic
import vtest

#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/socket.h>

fn C.eventfd(initval u32, flags int) int
fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.pipe(fds &i32) int
fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.shutdown(fd int, how int) int

const ta_backstop = time.Duration(5 * time.second)
const ta_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
const ta_parked = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nparked'
const ta_waited = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nwaited'
const ta_504 = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const ta_up = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nup'
const ta_100 = 'HTTP/1.1 100 Continue\r\n\r\n'
const ta_101 = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n'
const ta_count_head = 'HTTP/1.1 200 OK\r\nContent-Length: '
// The body of GET /close: far more than one write of a 4 KiB send buffer.
const ta_close_len = 512 * 1024
const ta_close_head = 'HTTP/1.1 200 OK\r\nContent-Length: 524288\r\nConnection: close\r\n\r\n'
// An upload large enough to be streamed (backend_epoll's sm_stream_body_above
// is 1 MiB) rather than buffered.
const ta_upload_len = 3 * 1024 * 1024
// GET /file: a 12 MiB sparse file handed to the worker (core.queue_file),
// larger than the 8 MiB pending-write cap.
const ta_file_len = 12 << 20
const ta_file_head = 'HTTP/1.1 200 OK\r\nContent-Length: 12582912\r\nConnection: keep-alive\r\n\r\n'
const ta_expect_head = 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'
// How long a client that stops reading waits for the worker to park (only
// reaching the park depends on it).
const ta_park_wait = time.Duration(200 * time.millisecond)

// TaShared is what the handlers and the test thread share: atomics, and the
// push registry under its mutex.
struct TaShared {
mut:
	hang_r   i64 = -1 // the read end of a pipe nobody writes: GET /hang parks on it
	hang_w   i64 = -1
	wait_w   i64 = -1 // the write end of the pipe the last GET /wait parks on: the test's to write and close
	file_fd  i64 = -1 // GET /file's sparse file (ta_file)
	resumes  i64 // continuation runs of GET /park
	timeouts i64 // continuation runs of GET /hang with event_loop.timed_out()
	closed   i64 // .closed notifications of push subscriptions
	mu       &sync.Mutex = sync.new_mutex()
	handle   core.ConnHandle // the latest subscription, for the test to post to
}

const ta = &TaShared{}

// TaWorker is one worker's state: its on_worker_start timer's ticks.
struct TaWorker {
mut:
	ticks i64
}

fn ta_state() voidptr {
	return voidptr(&TaWorker{})
}

fn ta_prefix(b []u8, p string) bool {
	if b.len < p.len {
		return false
	}
	for i in 0 .. p.len {
		if b[i] != p[i] {
			return false
		}
	}
	return true
}

// ta_dec appends n's decimal digits (n >= 0).
fn ta_dec(mut out []u8, n i64) {
	if n >= 10 {
		ta_dec(mut out, n / 10)
	}
	out << u8(`0` + n % 10)
}

fn ta_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if ta_prefix(req, 'GET /park ') {
		// An eventfd that is readable at once: the continuation runs on the
		// worker's next pass, after the requests behind this one were read.
		efd := C.eventfd(1, C.EFD_CLOEXEC | C.EFD_NONBLOCK)
		event_loop.watch_fd(efd, .readable, ta_park_done, unsafe { nil })
		return .suspend
	}
	if ta_prefix(req, 'GET /hang ') {
		s := unsafe { ta }
		event_loop.watch_fd(int(stdatomic.load_i64(&s.hang_r)), .readable, ta_hang_done,
			unsafe { nil })
		return .suspend
	}
	if ta_prefix(req, 'GET /file ') {
		s := unsafe { ta }
		fd := int(stdatomic.load_i64(&s.file_fd))
		core.append_str(mut out, ta_file_head)
		if !core.queue_file(fd, 0, ta_file_len) {
			core.append_file_region(mut out, fd, 0, ta_file_len) // a tcc build
		}
		return .done
	}
	if ta_prefix(req, 'GET /wait ') {
		// Parks on a fresh pipe until the test writes it (or the client goes).
		mut fds := [2]i32{}
		C.pipe(&fds[0])
		mut s := unsafe { ta }
		stdatomic.store_i64(&s.wait_w, i64(fds[1]))
		event_loop.watch_fd(int(fds[0]), .readable, ta_wait_done, unsafe { nil })
		return .suspend
	}
	if ta_prefix(req, 'GET /ticks ') {
		// The count as the body, then the close: the client reads to the end.
		w := unsafe { &TaWorker(worker_state) }
		mut body := []u8{cap: 20}
		ta_dec(mut body, w.ticks)
		core.append_str(mut out, ta_count_head)
		ta_dec(mut out, body.len)
		core.append_str(mut out, '\r\nConnection: close\r\n\r\n')
		out << body
		return .close
	}
	if ta_prefix(req, 'GET /close ') {
		// A small send buffer: the response leaves in many writes.
		small := 4096
		C.setsockopt(client_fd, C.SOL_SOCKET, C.SO_SNDBUF, &small, 4)
		core.append_str(mut out, ta_close_head)
		old := out.len
		unsafe {
			out.grow_len(ta_close_len)
			vmemset(&out[old], `c`, ta_close_len)
		}
		return .close
	}
	if ta_prefix(req, 'POST /up ') {
		// The head of a streamed upload (or a small buffered one): answered
		// once the body is drained.
		core.append_str(mut out, ta_up)
		return .done
	}
	if ta_prefix(req, 'GET /sub ') {
		if !core.queue_takeover(ta_lines, unsafe { nil }) {
			core.append_str(mut out, 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n')
			return .close
		}
		h := event_loop.subscribe(ta_wake, unsafe { nil })
		mut s := unsafe { ta }
		s.mu.lock()
		s.handle = h
		s.mu.unlock()
		core.append_str(mut out, ta_101)
		core.append_str(mut out, if h.is_nil() { 'nosub\n' } else { 'sub\n' })
		return .done
	}
	core.append_str(mut out, ta_ok)
	return .done
}

fn ta_park_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd) // the request owns it
	mut s := unsafe { ta }
	stdatomic.add_i64(&s.resumes, 1)
	core.append_str(mut out, ta_parked)
	return .done
}

fn ta_wait_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [1]u8{}
	C.read(ready_fd, &tmp[0], 1)
	C.close(ready_fd) // the request owns the read end
	core.append_str(mut out, ta_waited)
	return .done
}

// ta_file opens GET /file's sparse file once (the fd stays open for the test
// binary's life).
fn ta_file() ! {
	mut s := unsafe { ta }
	if stdatomic.load_i64(&s.file_fd) >= 0 {
		return
	}
	path := os.join_path(os.temp_dir(), 'vanilla_tls_async_${os.getpid()}.bin')
	os.write_file(path, '')!
	os.truncate(path, u64(ta_file_len))!
	f := os.open(path)!
	os.rm(path) or {}
	stdatomic.store_i64(&s.file_fd, i64(f.fd))
}

// ta_slow_dial is ta_dial with the client's receive buffer pinned small, so a
// client that is not reading leaves the worker parked mid-file.
fn ta_slow_dial(port int) !&openssl.SSLConn {
	mut c := ta_dial(port)!
	small := 32 * 1024
	C.setsockopt(c.handle, C.SOL_SOCKET, C.SO_RCVBUF, &small, 4)
	return c
}

// ta_close_wait closes the last GET /wait pipe's write end.
fn ta_close_wait() {
	mut s := unsafe { ta }
	w := stdatomic.load_i64(&s.wait_w)
	if w >= 0 {
		stdatomic.store_i64(&s.wait_w, -1)
		C.close(int(w))
	}
}

// ta_active is the server's count of open connections.
fn ta_active(mut h vtest.Harness) i64 {
	srv := h.server_ref()
	return stdatomic.load_i64(&srv.active_conns.n)
}

fn ta_hang_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if event_loop.timed_out() {
		mut s := unsafe { ta }
		stdatomic.add_i64(&s.timeouts, 1)
		core.append_str(mut out, ta_504)
		return .done
	}
	core.append_str(mut out, ta_ok) // never: nobody writes the pipe
	return .done
}

// ta_lines is the taken-over protocol: `ping` -> `pong`, `close` closes,
// anything else is echoed.
fn ta_lines(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut consumed := 0
	for {
		mut end := consumed
		for end < buf.len && buf[end] != `\n` {
			end++
		}
		if end == buf.len {
			break
		}
		line := unsafe { (&buf[consumed]).vbytes(end - consumed) }
		consumed = end + 1
		if line.len == 4 && ta_prefix(line, 'ping') {
			core.append_str(mut out, 'pong\n')
		} else if line.len == 5 && ta_prefix(line, 'close') {
			core.append_str(mut out, 'bye\n')
			return consumed, core.Step.close
		} else {
			core.append_str(mut out, 'echo:')
			unsafe { out.push_many(line.data, line.len) }
			out << `\n`
		}
	}
	return consumed, core.Step.done
}

// ta_wake is the subscription's wake fn: a post's data goes out as a line.
fn ta_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	match event_loop.reason() {
		.posted {
			core.append_str(mut out, 'push:')
			data := event_loop.post_data()
			unsafe { out.push_many(data.data, data.len) }
			out << `\n`
		}
		.closed {
			mut s := unsafe { ta }
			stdatomic.add_i64(&s.closed, 1)
		}
		else {}
	}
	return .done
}

// ta_tick is on_worker_start's timer: count its expirations (a busy worker
// reads several at once), re-arm (it is periodic).
fn ta_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut expirations := u64(0)
	C.read(ready_fd, &expirations, 8)
	mut w := unsafe { &TaWorker(worker_state) }
	w.ticks += i64(expirations)
	event_loop.watch_fd(ready_fd, .readable, ta_tick, unsafe { nil })
	return .suspend
}

// ta_on_worker_start arms a 10 ms periodic timerfd on the worker's loop.
fn ta_on_worker_start(worker_state voidptr, mut el core.EventLoop) {
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_CLOEXEC | C.TFD_NONBLOCK)
	mut spec := [4]i64{}
	spec[1] = 10_000_000 // it_interval: 10 ms
	spec[3] = 10_000_000 // it_value: first tick in 10 ms
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	el.watch_fd(tfd, .readable, ta_tick, unsafe { nil })
}

// ta_ktls_runs is [false] (userspace Mbed TLS only), or [false, true] when the
// kernel can take record crypto (the `tls` module is loaded).
fn ta_ktls_runs() []bool {
	return if os.exists('/proc/net/tls_stat') { [false, true] } else { [false] }
}

// ta_start serves ta_handler over HTTPS on `workers` epoll workers.
fn ta_start(ktls bool, workers int, limits server.Limits) !&vtest.Harness {
	// The openssl client writes without MSG_NOSIGNAL: a write to a connection
	// the server already closed must fail that call, not end the test binary.
	os.signal_ignore(.pipe)
	cfg := tls.new_self_signed()!
	if !ktls {
		cfg.set_ktls(false)
	}
	mut s := unsafe { ta }
	stdatomic.store_i64(&s.resumes, 0)
	stdatomic.store_i64(&s.timeouts, 0)
	stdatomic.store_i64(&s.closed, 0)
	return vtest.start(server.ServerConfig{
		io_multiplexing:    .epoll
		workers:            workers
		tls_config:         cfg
		handler:            ta_handler
		make_state:         ta_state
		on_worker_start:    ta_on_worker_start
		push_mailbox_slots: 64
		limits:             limits
	})
}

fn ta_dial(port int) !&openssl.SSLConn {
	mut c := openssl.new_ssl_conn(validate: false)!
	c.dial('127.0.0.1', port)!
	c.set_read_timeout(ta_backstop)
	return c
}

// ta_read_n reads until `n` bytes arrived (fewer if the connection ends or
// the backstop fires) and returns them.
fn ta_read_n(mut c openssl.SSLConn, n int) string {
	return ta_read_bytes(mut c, n).bytestr()
}

// ta_read_bytes is ta_read_n without the string: for the large bodies.
fn ta_read_bytes(mut c openssl.SSLConn, n int) []u8 {
	mut acc := []u8{cap: n}
	mut buf := []u8{len: 64 * 1024}
	for acc.len < n {
		k := c.read(mut buf) or { break }
		if k <= 0 {
			break
		}
		acc << buf[..k]
	}
	return acc
}

// ta_read_until_close reads until the server closes the connection (or the
// backstop fires) and returns what arrived.
fn ta_read_until_close(mut c openssl.SSLConn) string {
	mut acc := []u8{}
	mut buf := []u8{len: 64 * 1024}
	for {
		k := c.read(mut buf) or { break }
		if k <= 0 {
			break
		}
		acc << buf[..k]
	}
	return acc.bytestr()
}

// A parked request is answered by its continuation, and the two requests
// pipelined behind it in the same write are answered after it, in order. A
// second round on the same connection checks it is back at a request
// boundary. (The old TLS worker closed any connection whose handler suspended.)
fn test_tls_suspend_answers_and_pipelined_requests_follow() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		burst := 'GET /park HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n'
		want := ta_parked + ta_ok + ta_ok
		for round in 0 .. 2 {
			c.write_string(burst)!
			got := ta_read_n(mut c, want.len)
			assert got == want, 'ktls=${ktls} round ${round}: got ${got}'
		}
		s := unsafe { ta }
		resumes := stdatomic.load_i64(&s.resumes)
		c.shutdown() or {}
		h.stop()
		assert resumes == 2, 'ktls=${ktls}: the continuation ran ${resumes} times'
	}
}

// A park whose fd never becomes ready ends at Limits.park_timeout_ms: the
// continuation runs once with timed_out() and its 504 goes out over TLS.
fn test_tls_park_deadline_answers_504() ! {
	for ktls in ta_ktls_runs() {
		mut fds := [2]i32{}
		assert C.pipe(&fds[0]) == 0
		mut s := unsafe { ta }
		stdatomic.store_i64(&s.hang_r, i64(fds[0]))
		stdatomic.store_i64(&s.hang_w, i64(fds[1]))
		mut h := ta_start(ktls, 1, server.Limits{ park_timeout_ms: 150 })!
		mut c := ta_dial(h.port())!
		sw := time.new_stopwatch()
		c.write_string('GET /hang HTTP/1.1\r\nHost: x\r\n\r\n')!
		got := ta_read_n(mut c, ta_504.len)
		elapsed := sw.elapsed().milliseconds()
		// The connection is still usable: the 504 was a response, not a close.
		c.write_string('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!
		next := ta_read_n(mut c, ta_ok.len)
		timeouts := stdatomic.load_i64(&s.timeouts)
		c.shutdown() or {}
		h.stop()
		C.close(fds[0])
		C.close(fds[1])
		assert got == ta_504, 'ktls=${ktls}: got ${got}'
		assert elapsed >= 140 && elapsed < 2000, 'ktls=${ktls}: the 504 came after ${elapsed}ms (deadline 150ms)'
		assert next == ta_ok, 'ktls=${ktls}: after the 504 got ${next}'
		assert timeouts == 1, 'ktls=${ktls}: timed out ${timeouts} times'
	}
}

// A client that leaves cleanly while its request is parked (close_notify,
// then FIN) is noticed at once: the connection and the watch's fd are
// released. A raw peek, as on plain HTTP, reads the close_notify as data, and
// the request would wait for its watch, here forever.
fn test_tls_parked_client_close_is_noticed() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('GET /wait HTTP/1.1\r\nHost: x\r\n\r\n')!
		time.sleep(50 * time.millisecond) // parked
		before := ta_active(mut h)
		c.shutdown() or {} // close_notify, then FIN
		mut after := before
		for _ in 0 .. 200 {
			after = ta_active(mut h)
			if after == 0 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		h.stop()
		ta_close_wait()
		assert before == 1, 'ktls=${ktls}: ${before} connections open while parked'
		assert after == 0, 'ktls=${ktls}: the parked connection outlived its client'
	}
}

// A client that pipelines a request behind a parked one, in a later write,
// then half-closes (a bare FIN) gets both answers, in order, then the close:
// what it sent before its FIN is kept for when the park ends, as the plain
// path keeps bytes still in the socket.
fn test_tls_parked_then_pipelined_then_fin() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('GET /wait HTTP/1.1\r\nHost: x\r\n\r\n')!
		time.sleep(50 * time.millisecond) // parked
		c.write_string('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!
		C.shutdown(c.handle, C.SHUT_WR)
		time.sleep(50 * time.millisecond) // read while parked
		open := ta_active(mut h)
		mut s := unsafe { ta }
		one := u8(1)
		C.write(int(stdatomic.load_i64(&s.wait_w)), &one, 1) // the park ends
		got := ta_read_until_close(mut c)
		h.stop()
		ta_close_wait()
		assert open == 1, 'ktls=${ktls}: the connection closed while answers were owed'
		assert got == ta_waited + ta_ok, 'ktls=${ktls}: got ${got}'
	}
}

// An Expect: 100-continue head pipelined behind a file the worker could not
// send at once (in the same write, or while the worker is mid-file) gets its
// 100 once the file is out, and the upload then completes. The 100 must not
// land inside the file's body, so the connection is held behind the file;
// the 100 used to be lost then: it was queued only after a read that brought
// the head, and on resume the head was already buffered.
fn test_tls_expect_100_behind_held_file() ! {
	ta_file()!
	for ktls in ta_ktls_runs() {
		for same_write in [true, false] {
			mut h := ta_start(ktls, 1, server.Limits{})!
			mut c := ta_slow_dial(h.port())!
			mut got := []u8{}
			if same_write {
				c.write_string('GET /file HTTP/1.1\r\nHost: x\r\n\r\n' + ta_expect_head)!
			} else {
				c.write_string('GET /file HTTP/1.1\r\nHost: x\r\n\r\n')!
				got << ta_read_bytes(mut c, 1024) // the worker is in the file now
				c.write_string(ta_expect_head)!
			}
			time.sleep(ta_park_wait) // not reading: the worker parks mid-file
			file_total := ta_file_head.len + ta_file_len
			got << ta_read_bytes(mut c, file_total - got.len)
			interim := ta_read_n(mut c, ta_100.len)
			c.write_string('hello')!
			answer := ta_read_n(mut c, ta_up.len)
			c.shutdown() or {}
			h.stop()
			assert got.len == file_total, 'ktls=${ktls} same_write=${same_write}: ${got.len} of ${file_total} bytes of the file'
			assert got[ta_file_head.len..].all(it == 0), 'ktls=${ktls} same_write=${same_write}: foreign bytes inside the file body'
			assert interim == ta_100, 'ktls=${ktls} same_write=${same_write}: no 100 Continue after the file, got ${interim}'
			assert answer == ta_up, 'ktls=${ktls} same_write=${same_write}: got ${answer}'
		}
	}
}

// A request held behind a file runs on no read deadline: the file runs on
// write_timeout_ms, and a download slower than read_timeout_ms must not reap
// the request waiting behind it. Here that request arrives in two writes, the
// first of which armed its read deadline before the second completed it.
fn test_tls_held_request_has_no_read_deadline() ! {
	ta_file()!
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{
			read_timeout_ms: 300
		})!
		mut c := ta_slow_dial(h.port())!
		c.write_string('GET /file HTTP/1.1\r\nHost: x\r\n\r\n')!
		mut got := ta_read_bytes(mut c, 1024) // the worker is in the file now
		c.write_string('GET / HTTP/1.1\r\nHo')!
		time.sleep(50 * time.millisecond)
		c.write_string('st: x\r\n\r\n')!
		time.sleep(700 * time.millisecond) // a slow download: past read_timeout_ms
		total := ta_file_head.len + ta_file_len + ta_ok.len
		got << ta_read_bytes(mut c, total - got.len)
		c.shutdown() or {}
		h.stop()
		assert got.len == total, 'ktls=${ktls}: ${got.len} of ${total} bytes: the held request was reaped'
		assert got[got.len - ta_ok.len..] == ta_ok.bytes(), 'ktls=${ktls}: the held request was not answered after the file'
	}
}

// An Expect: 100-continue head sent while the request before it is parked
// gets its 100 once the parked one is answered (the head is read while
// parked, so no later read brings it).
fn test_tls_expect_100_after_park() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('GET /wait HTTP/1.1\r\nHost: x\r\n\r\n')!
		time.sleep(50 * time.millisecond) // parked
		c.write_string(ta_expect_head)!
		time.sleep(50 * time.millisecond) // read while parked
		mut s := unsafe { ta }
		one := u8(1)
		C.write(int(stdatomic.load_i64(&s.wait_w)), &one, 1) // the park ends
		got := ta_read_n(mut c, ta_waited.len + ta_100.len)
		c.write_string('hello')!
		answer := ta_read_n(mut c, ta_up.len)
		c.shutdown() or {}
		h.stop()
		ta_close_wait()
		assert got == ta_waited + ta_100, 'ktls=${ktls}: got ${got}'
		assert answer == ta_up, 'ktls=${ktls}: got ${answer}'
	}
}

// on_worker_start arms a clientless watch on a TLS server's worker (it was
// refused with TLS): its 10 ms timer ticks while the worker serves HTTPS.
fn test_tls_on_worker_start_timer_ticks() ! {
	mut h := ta_start(false, 1, server.Limits{})!
	time.sleep(150 * time.millisecond)
	mut c := ta_dial(h.port())!
	c.write_string('GET /ticks HTTP/1.1\r\nHost: x\r\n\r\n')!
	got := ta_read_until_close(mut c)
	h.stop()
	assert got.starts_with(ta_count_head), got
	body := got.all_after('\r\n\r\n')
	assert body.int() >= 10, 'the worker timer expired ${body} times in 150ms (every 10ms expected)'
}

// A connection taken over by a line protocol over TLS subscribes; a post from
// the test thread reaches it through the worker's mailbox, between the lines
// it reads; its close delivers .closed once. (The old TLS worker had no takeover,
// no mailbox and no subscriptions.)
fn test_tls_takeover_and_push() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 2, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('GET /sub HTTP/1.1\r\nHost: x\r\n\r\n')!
		greet := ta_read_n(mut c, ta_101.len + 'sub\n'.len)
		assert greet == ta_101 + 'sub\n', 'ktls=${ktls}: got ${greet}'
		c.write_string('ping\nhello\n')!
		assert ta_read_n(mut c, 'pong\necho:hello\n'.len) == 'pong\necho:hello\n'
		mut s := unsafe { ta }
		s.mu.lock()
		hd := s.handle
		s.mu.unlock()
		res := hd.post_bytes(1, 'news'.bytes())
		assert res == .ok, 'ktls=${ktls}: post_bytes said ${res}'
		assert ta_read_n(mut c, 'push:news\n'.len) == 'push:news\n'
		c.write_string('close\n')!
		rest := ta_read_until_close(mut c)
		assert rest == 'bye\n', 'ktls=${ktls}: got ${rest}'
		// .closed runs at the end of the worker's loop iteration.
		for _ in 0 .. 100 {
			if stdatomic.load_i64(&s.closed) > 0 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		closed := stdatomic.load_i64(&s.closed)
		h.stop()
		assert closed == 1, 'ktls=${ktls}: .closed ran ${closed} times'
	}
}

// A .close whose response is far larger than one write of the socket (4 KiB
// send buffer, a reader that waits before it reads) sends all of it, then
// closes. The old TLS worker made one best-effort write and dropped the rest
// (vanilla#275).
fn test_tls_close_sends_everything() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('GET /close HTTP/1.1\r\nHost: x\r\n\r\n')!
		time.sleep(200 * time.millisecond) // let the send buffer fill
		got := ta_read_until_close(mut c)
		h.stop()
		assert got.len == ta_close_head.len + ta_close_len, 'ktls=${ktls}: ${got.len} of ${ta_close_head.len +
			ta_close_len} bytes before the close'
		assert got.starts_with(ta_close_head)
		assert got[got.len - 1] == `c`
	}
}

// A body past the streaming threshold is drained, not buffered, and the
// answer comes after it; the connection then serves the next request. With
// Expect: 100-continue the 100 comes first, before any of the body is sent.
fn test_tls_large_upload_and_expect_100() ! {
	for ktls in ta_ktls_runs() {
		mut h := ta_start(ktls, 1, server.Limits{})!
		mut c := ta_dial(h.port())!
		c.write_string('POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: ${ta_upload_len}\r\n\r\n')!
		chunk := []u8{len: 64 * 1024, init: `u`}
		mut sent := 0
		for sent < ta_upload_len {
			sent += c.write(chunk)!
		}
		assert ta_read_n(mut c, ta_up.len) == ta_up, 'ktls=${ktls}: the streamed upload was not answered'
		c.write_string('POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n')!
		interim := ta_read_n(mut c, ta_100.len)
		assert interim == ta_100, 'ktls=${ktls}: got ${interim}'
		c.write_string('hello')!
		assert ta_read_n(mut c, ta_up.len) == ta_up
		c.write_string('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!
		assert ta_read_n(mut c, ta_ok.len) == ta_ok
		c.shutdown() or {}
		h.stop()
	}
}
