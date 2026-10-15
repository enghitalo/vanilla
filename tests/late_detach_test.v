// vtest build: linux
// A watch fd that a continuation closes, then steps away from (or times out
// on), must not take a new client out of the worker's epoll set
// (vanilla#337). The epoll runtime takes a watch fd it stops waiting on out of
// the set by number, and it used to do so only after the continuation had
// returned. A continuation that closed that fd itself freed the number in
// between: the accept thread could hand it to a new client and register that
// client in this worker's epoll, and the late EPOLL_CTL_DEL then took the NEW
// client out of the set. Its request was never read, and it hung.
//
// Every case forces that interleaving, so it runs the same way each time. The
// continuation closes the fd it woke on, lets the test connect clients
// (sockets made before the number was freed, so none of them can take it),
// and returns only once the accept thread has given the freed number to one
// of them and registered it in this worker's epoll (fcntl(F_GETFD), then
// /proc/self/fdinfo of the epoll fd). The test connects one client at a time
// until that happens: a lower number freed earlier (a previous case's sockets)
// goes to the first ones. `workers: 1`, so every client lands on this worker.
// Every client must then be served, and the freed number must still be in the
// epoll set after the continuation.
//
// One case per place that detached a watch fd after its continuation:
//   * resume_step: a client continuation steps to another fd (and a control
//     that closes the fd one step later, PR #333's workaround);
//   * on_park_timeout: the timed-out continuation closes its fd and answers
//     504, as EventLoop.timed_out's doc says;
//   * on_watch_ready, clientless: a background continuation steps to another
//     fd (WorkerStartFn: "you still own and must close it");
//   * drain_pipelined: the last client queued on a persistent fd steps away;
//   * run_tombstone: the tombstone of a client that left steps away;
//   * pg_async: a continuation woken on a lost pooled connection calls
//     acquire(), which re-dials it (redial_start closes the socket; the
//     choreography runs in password_fn, before the new socket is made), and
//     steps to the other connection. Needs python3 (tests/testdata/fake_pg.py),
//     skipped without it.
// late_detach_stress_test.v is the same bug under load, with no forced
// interleaving.
module main

import os
import core
import server
import pg_async
import sync.stdatomic
import time
import vtest

#include <fcntl.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/timerfd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.eventfd(initval u32, flags int) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.socket(domain int, typ int, protocol int) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.send(fd int, buf voidptr, n usize, flags int) int
fn C.recv(fd int, buf voidptr, n usize, flags int) int
fn C.setsockopt(fd int, level int, opt int, val voidptr, len u32) int
fn C.shutdown(fd int, how int) int
fn C.bind(fd int, addr voidptr, len u32) int
fn C.sendto(fd int, buf voidptr, n usize, flags int, addr voidptr, len u32) int
fn C.clock() i64 // this process's CPU time, in CLOCKS_PER_SEC (1e6 on POSIX) units

const ok_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
const stepped_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\nstepped'
const timeout_resp = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const error_resp = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// victims is how many clients a case can connect while its continuation
// holds: more than the numbers the cases before it leave free.
const victims = 12

// Rp is the choreography between a test and the continuation that closes
// its fd. One case runs at a time.
struct Rp {
mut:
	close_first i64 // 1: the continuation closes the fd it woke on; 0: one step later (the control)
	freed       i64 = -1 // the number the continuation closed (or would have)
	loop_fd     i64 = -1 // the worker's epoll fd
	go          i64 // continuation → test: connect now
	c2_sent     i64 // test → continuation (control): a client connected and sent its request
	reused      i64 // the continuation saw the freed number registered for a client before it returned
	keep        i64 = -1 // control: the fd to close at the next step
	shared_fd   i64 = -1 // /pipe, /tomb: the persistent fd their requests park on; /udp: the app socket; the background watch's trigger
	parks       i64 // /pipe and /tomb: requests parked on it
	redial      i64 // pg case: 1 until the re-dial's password_fn call
}

const rp = &Rp{}

fn rp_reset(close_first bool) {
	mut p := unsafe { rp }
	stdatomic.store_i64(&p.close_first, if close_first { 1 } else { 0 })
	stdatomic.store_i64(&p.freed, -1)
	stdatomic.store_i64(&p.loop_fd, -1)
	stdatomic.store_i64(&p.go, 0)
	stdatomic.store_i64(&p.c2_sent, 0)
	stdatomic.store_i64(&p.reused, 0)
	stdatomic.store_i64(&p.keep, -1)
	stdatomic.store_i64(&p.shared_fd, -1)
	stdatomic.store_i64(&p.parks, 0)
	stdatomic.store_i64(&p.redial, 0)
}

fn freed() int {
	return int(stdatomic.load_i64(&rp.freed))
}

fn loop_fd() int {
	return int(stdatomic.load_i64(&rp.loop_fd))
}

fn reused() bool {
	return stdatomic.load_i64(&rp.reused) == 1
}

// in_epoll reports whether fd n is registered in epoll instance ep, from
// /proc/self/fdinfo/<ep> ("tfd: %8d events: ..." per registration).
fn in_epoll(ep int, n int) bool {
	s := os.read_file('/proc/self/fdinfo/${ep}') or { return false }
	for line in s.split_into_lines() {
		if line.starts_with('tfd:') {
			f := line.fields()
			if f.len > 1 && f[1].int() == n {
				return true
			}
		}
	}
	return false
}

fn tfd_count(ep int) int {
	s := os.read_file('/proc/self/fdinfo/${ep}') or { return 0 }
	mut c := 0
	for line in s.split_into_lines() {
		if line.starts_with('tfd:') {
			c++
		}
	}
	return c
}

// choreograph runs inside a continuation, after it closed (or kept) fd n: it
// lets the test connect clients and returns once the accept thread has
// registered one with this worker's epoll, under number n when n was freed.
fn choreograph(n int, ep int) {
	mut p := unsafe { rp }
	stdatomic.store_i64(&p.freed, n)
	stdatomic.store_i64(&p.loop_fd, ep)
	close_first := stdatomic.load_i64(&p.close_first) == 1
	// Opening /proc takes the lowest free number: never while n is free.
	before := if close_first { 0 } else { tfd_count(ep) }
	stdatomic.store_i64(&p.go, 1)
	// The waits use the monotonic clock: time.now()'s first call opens
	// /etc/localtime, an fd that could take the freed number.
	deadline := time.sys_mono_now() + 5_000_000_000
	for time.sys_mono_now() < deadline {
		if close_first {
			// accept4 took n back (no fd is made here while n is free) ...
			if C.fcntl(n, C.F_GETFD, 0) >= 0 && in_epoll(ep, n) {
				// ... and the accept thread ADDed it to this worker's epoll.
				stdatomic.store_i64(&p.reused, 1)
				return
			}
		} else if stdatomic.load_i64(&p.c2_sent) == 1 && tfd_count(ep) > before {
			return
		}
	}
}

fn one_shot_timer(ms int) int {
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	mut spec := [4]i64{}
	spec[3] = i64(ms) * 1_000_000
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	return tfd
}

fn drain(fd int) {
	mut tmp := [8]u8{}
	C.read(fd, &tmp[0], 8)
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.len > 9 && req[5] == `s` { // GET /step
		b := C.eventfd(1, C.EFD_NONBLOCK | C.EFD_CLOEXEC) // readable at once: the next step
		a := one_shot_timer(1) // this step
		event_loop.watch_fd(a, .readable, after_a, unsafe { voidptr(isize(b)) })
		return .suspend
	}
	if req.len > 9 && req[5] == `d` { // GET /deadline
		a := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC) // never fires
		event_loop.watch_fd_deadline(a, .readable, on_deadline, unsafe { nil }, 20)
		return .suspend
	}
	if req.len > 9 && (req[5] == `p` || req[5] == `t`) { // GET /pipe, GET /tomb
		// Parks on one persistent fd (a pooled connection, here an eventfd the
		// test writes): two /pipe requests queue on it. The next step's fd,
		// readable at once, is made now, before anything is freed.
		mut p := unsafe { rp }
		next := C.eventfd(1, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		mut shared := int(stdatomic.load_i64(&rp.shared_fd))
		if shared < 0 {
			shared = C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
			stdatomic.store_i64(&p.shared_fd, shared)
		}
		parks := stdatomic.load_i64(&rp.parks)
		cont := if req[5] == `p` && parks == 0 {
			core.WakeFn(pipe_head)
		} else {
			core.WakeFn(close_and_step)
		}
		event_loop.watch_fd_persistent(shared, .readable, cont, unsafe { voidptr(isize(next)) })
		stdatomic.store_i64(&p.parks, parks + 1)
		return .suspend
	}
	if req.len > 9 && req[5] == `u` { // GET /udp: watch the test's UDP socket, keep it, step away
		next := C.eventfd(1, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		event_loop.watch_fd(int(stdatomic.load_i64(&rp.shared_fd)), .readable, keep_and_step,
			unsafe { voidptr(isize(next)) })
		return .suspend
	}
	core.append_str(mut out, ok_resp)
	return .done
}

// after_a: the shape of examples/async_multi_watch's after_a and of PR #333's
// first on_backoff: close the fd it woke on, then watch another fd and
// return .suspend (resume_step).
fn after_a(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	if stdatomic.load_i64(&rp.close_first) == 1 {
		C.close(ready_fd)
	} else {
		mut p := unsafe { rp }
		stdatomic.store_i64(&p.keep, ready_fd)
	}
	choreograph(ready_fd, event_loop.loop_fd)
	event_loop.watch_fd(int(isize(watch_payload)), .readable, after_b, unsafe { nil })
	return .suspend
}

fn after_b(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	C.close(ready_fd)
	keep := int(stdatomic.load_i64(&rp.keep))
	if keep >= 0 {
		C.close(keep)
	}
	core.append_str(mut out, stepped_resp)
	return .done
}

// on_deadline follows core.EventLoop.timed_out's doc: the fd is still the
// continuation's, so it closes it there (on_park_timeout).
fn on_deadline(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if event_loop.timed_out() {
		C.close(ready_fd)
		choreograph(ready_fd, event_loop.loop_fd)
		core.append_str(mut out, timeout_resp)
		return .done
	}
	core.append_str(mut out, ok_resp)
	return .done
}

// pipe_head is the first /pipe request's continuation, at the head of the
// queue: it steps to its own next fd and leaves the persistent fd to the
// second request, whose continuation then runs off the same edge
// (drain_pipelined).
fn pipe_head(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	event_loop.watch_fd(int(isize(watch_payload)), .readable, after_b, unsafe { nil })
	return .suspend
}

// close_and_step closes the persistent fd it woke on, as pg_async's re-dial
// closes a lost connection's socket, then steps to its next fd: the second
// /pipe request (drain_pipelined), or the tombstone of the /tomb request
// whose client left (run_tombstone, which closes that request-owned fd).
fn close_and_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	C.close(ready_fd)
	choreograph(ready_fd, event_loop.loop_fd)
	event_loop.watch_fd(int(isize(watch_payload)), .readable, after_b, unsafe { nil })
	return .suspend
}

// keep_and_step leaves the socket it woke on open and unread (the app keeps
// it), and steps to its next fd.
fn keep_and_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { rp }
	stdatomic.store_i64(&p.loop_fd, event_loop.loop_fd)
	event_loop.watch_fd(int(isize(watch_payload)), .readable, after_b, unsafe { nil })
	return .suspend
}

// bg_start arms a clientless watch on an eventfd that the test writes once it
// is ready (its client sockets exist). Its continuation closes that fd, then
// steps to another fd (core.WorkerStartFn: "if you re-arm a DIFFERENT fd the
// runtime only detaches the old one").
fn bg_start(worker_state voidptr, mut event_loop core.EventLoop) {
	b := C.eventfd(1, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
	a := C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
	mut p := unsafe { rp }
	stdatomic.store_i64(&p.shared_fd, a)
	event_loop.watch_fd(a, .readable, bg_after_a, unsafe { voidptr(isize(b)) })
}

fn bg_after_a(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	C.close(ready_fd)
	choreograph(ready_fd, event_loop.loop_fd)
	event_loop.watch_fd(int(isize(watch_payload)), .readable, bg_after_b, unsafe { nil })
	return .suspend
}

fn bg_after_b(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	return .done // the runtime closes ready_fd
}

fn tcp_socket() int {
	fd := C.socket(C.AF_INET, C.SOCK_STREAM | C.SOCK_CLOEXEC, 0)
	mut t := [2]i64{}
	t[0] = 3 // SO_RCVTIMEO: 3 s, where a response takes milliseconds
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_RCVTIMEO, voidptr(&t[0]), 16)
	return fd
}

fn tcp_sockets(n int) []int {
	mut socks := []int{cap: n}
	for _ in 0 .. n {
		socks << tcp_socket()
	}
	return socks
}

fn close_all(socks []int) {
	for s in socks {
		C.close(s)
	}
}

fn tcp_connect(fd int, port int) {
	mut a := [16]u8{}
	unsafe {
		*(&u16(&a[0])) = u16(C.AF_INET)
	}
	a[2] = u8(port >> 8)
	a[3] = u8(port & 0xff)
	a[4] = 127
	a[7] = 1
	if C.connect(fd, voidptr(&a[0]), 16) != 0 {
		panic('connect failed')
	}
}

fn send_str(fd int, s string) {
	C.send(fd, s.str, usize(s.len), 0)
}

// read_until reads until `want` bytes arrived, the peer closes, or 3 s pass.
fn read_until(fd int, want int) string {
	mut buf := []u8{len: 4096}
	mut got := 0
	// A socket call with SO_RCVTIMEO is not restarted after a signal (the GC's
	// stop-the-world ones): retry on EINTR, up to the overall 3 s.
	deadline := time.sys_mono_now() + 3_000_000_000
	for got < want && time.sys_mono_now() < deadline {
		n := C.recv(fd, unsafe { &buf[got] }, usize(buf.len - got), 0)
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		if n <= 0 {
			break
		}
		got += n
	}
	return buf[..got].bytestr()
}

// wait_eof reports whether the peer closed fd within 3 s.
fn wait_eof(fd int) bool {
	mut b := [1]u8{}
	deadline := time.sys_mono_now() + 3_000_000_000
	for time.sys_mono_now() < deadline {
		n := C.recv(fd, &b[0], 1, 0)
		if n == 0 {
			return true
		}
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		if n < 0 {
			return false
		}
	}
	return false
}

fn wait_for(field &i64, want i64) bool {
	deadline := time.sys_mono_now() + 5_000_000_000
	for time.sys_mono_now() < deadline {
		if stdatomic.load_i64(field) >= want {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

fn wait_go() bool {
	return wait_for(&rp.go, 1)
}

// connect_until_reused connects the clients in socks one at a time, each
// sending GET /, until the continuation reports that the freed number went
// to one of them. Returns the clients it connected.
fn connect_until_reused(port int, socks []int) []int {
	mut used := []int{}
	for s in socks {
		tcp_connect(s, port)
		send_str(s, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n')
		used << s
		deadline := time.sys_mono_now() + 300_000_000
		for time.sys_mono_now() < deadline {
			if reused() {
				return used
			}
			time.sleep(time.millisecond)
		}
	}
	return used
}

// all_served reads every client's answer and reports whether each got one.
fn all_served(name string, clients []int) bool {
	mut ok := true
	for c in clients {
		r := read_until(c, ok_resp.len)
		if r != ok_resp {
			eprintln('[${name}] a client (test-side socket ${c}) got ${r.len} bytes (0 = never served, hung until SO_RCVTIMEO)')
			ok = false
		}
	}
	return ok
}

fn report(name string, still bool) {
	eprintln('[${name}] freed fd=${freed()} went to a client: ${reused()}; still in the worker epoll after the continuation: ${still}')
}

fn start(cfg server.ServerConfig) &vtest.Harness {
	return vtest.start(server.ServerConfig{
		...cfg
		io_multiplexing: .epoll
		workers:         1
	}) or { panic(err) }
}

// run_client_case: C1 sends `path`; while its continuation holds the freed
// number, clients connect and send GET /. Returns C1's answer, whether the
// freed number is still in the worker's epoll afterwards, and whether every
// client was served.
fn run_client_case(name string, path string, want int, close_first bool) (string, bool, bool) {
	rp_reset(close_first)
	mut h := start(server.ServerConfig{
		handler: handle
	})
	defer {
		h.stop()
	}
	c1 := tcp_socket()
	socks := tcp_sockets(victims) // before the continuation frees a number: none can take it
	defer {
		C.close(c1)
		close_all(socks)
	}
	tcp_connect(c1, h.port())
	send_str(c1, 'GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_go(), 'the continuation never ran'
	mut clients := []int{}
	if close_first {
		clients = connect_until_reused(h.port(), socks)
	} else {
		tcp_connect(socks[0], h.port())
		send_str(socks[0], 'GET / HTTP/1.1\r\nHost: x\r\n\r\n')
		clients << socks[0]
		mut p := unsafe { rp }
		stdatomic.store_i64(&p.c2_sent, 1)
	}
	r1 := read_until(c1, want)
	still := in_epoll(loop_fd(), freed())
	report(name, still)
	return r1, still, all_served(name, clients)
}

// Control: the continuation keeps the fd open until the next step (PR #333's
// workaround), so the number is never free.
fn test_epoll_step_away_keeping_the_fd_open() {
	r1, _, served := run_client_case('step, fd kept open', '/step', stepped_resp.len, false)
	assert r1 == stepped_resp
	assert served
}

// resume_step: the continuation closes the fd it woke on, then watches
// another fd and returns .suspend.
fn test_epoll_step_away_after_closing_the_fd() {
	r1, still, served := run_client_case('step, fd closed', '/step', stepped_resp.len,
		true)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert r1 == stepped_resp
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}

// on_park_timeout: the timed-out continuation closes its fd, as
// EventLoop.timed_out's doc says, and returns .done.
fn test_epoll_timed_out_continuation_closing_its_fd() {
	r1, still, served := run_client_case('timeout, fd closed', '/deadline', timeout_resp.len,
		true)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert r1 == timeout_resp
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}

// on_watch_ready, clientless: a background continuation closes its fd, then
// steps to another fd.
fn test_epoll_background_continuation_closing_its_fd() {
	rp_reset(true)
	mut h := start(server.ServerConfig{
		handler:         handle
		on_worker_start: bg_start
	})
	defer {
		h.stop()
	}
	assert wait_for(&rp.shared_fd, 0), 'the background watch was not armed'
	socks := tcp_sockets(victims) // before the continuation frees its number
	defer {
		close_all(socks)
	}
	one := u64(1)
	C.write(int(stdatomic.load_i64(&rp.shared_fd)), &one, 8) // the background watch fires
	assert wait_go(), 'the background continuation never ran'
	clients := connect_until_reused(h.port(), socks)
	time.sleep(100 * time.millisecond) // the continuation returns at once; let the worker loop go round
	still := in_epoll(loop_fd(), freed())
	report('background, fd closed', still)
	served := all_served('background, fd closed', clients)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}

// drain_pipelined: two requests queue on one persistent fd; one readiness
// edge runs both continuations. The head steps to its own fd; the second
// closes the shared fd and steps away too, which empties the queue.
fn test_epoll_last_queued_continuation_closing_its_fd() {
	rp_reset(true)
	mut h := start(server.ServerConfig{
		handler: handle
	})
	defer {
		h.stop()
	}
	ca := tcp_socket()
	cb := tcp_socket()
	socks := tcp_sockets(victims)
	defer {
		C.close(ca)
		C.close(cb)
		close_all(socks)
	}
	tcp_connect(ca, h.port())
	send_str(ca, 'GET /pipe HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&rp.parks, 1), 'the first request did not park'
	tcp_connect(cb, h.port())
	send_str(cb, 'GET /pipe HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&rp.parks, 2), 'the second request did not park'
	one := u64(1)
	C.write(int(stdatomic.load_i64(&rp.shared_fd)), &one, 8) // the shared fd is ready
	assert wait_go(), 'the second continuation never ran'
	clients := connect_until_reused(h.port(), socks)
	ra := read_until(ca, stepped_resp.len)
	rb := read_until(cb, stepped_resp.len)
	still := in_epoll(loop_fd(), freed())
	report('pipelined, fd closed', still)
	served := all_served('pipelined, fd closed', clients)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert ra == stepped_resp
	assert rb == stepped_resp
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}

// run_tombstone: the client of a request parked on a persistent fd leaves,
// so the watch becomes a tombstone; when the fd is ready the tombstone's
// continuation closes it and steps away.
fn test_epoll_tombstone_continuation_closing_its_fd() {
	rp_reset(true)
	mut h := start(server.ServerConfig{
		handler: handle
	})
	defer {
		h.stop()
	}
	ca := tcp_socket()
	socks := tcp_sockets(victims)
	defer {
		C.close(ca)
		close_all(socks)
	}
	tcp_connect(ca, h.port())
	send_str(ca, 'GET /tomb HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&rp.parks, 1), 'the request did not park'
	// Half-close: the server sees the client leave and closes its side, and
	// ca keeps its number, so no lower number is freed.
	C.shutdown(ca, C.SHUT_WR)
	assert wait_eof(ca), 'the server did not close the connection of a client that left'
	one := u64(1)
	C.write(int(stdatomic.load_i64(&rp.shared_fd)), &one, 8) // the tombstone's reply is due
	assert wait_go(), 'the tombstone continuation never ran'
	clients := connect_until_reused(h.port(), socks)
	time.sleep(100 * time.millisecond) // no client answers this run; let the worker loop go round
	still := in_epoll(loop_fd(), freed())
	report('tombstone, fd closed', still)
	served := all_served('tombstone, fd closed', clients)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}

// udp_on_loopback returns a UDP socket bound to 127.0.0.1:port, and a second
// one that has sent it a datagram, so the first is readable until read.
fn udp_on_loopback(port int) (int, int) {
	mut a := [16]u8{}
	unsafe {
		*(&u16(&a[0])) = u16(C.AF_INET)
	}
	a[2] = u8(port >> 8)
	a[3] = u8(port & 0xff)
	a[4] = 127
	a[7] = 1
	fd := C.socket(C.AF_INET, C.SOCK_DGRAM | C.SOCK_CLOEXEC, 0)
	if C.bind(fd, voidptr(&a[0]), 16) != 0 {
		panic('bind failed')
	}
	peer := C.socket(C.AF_INET, C.SOCK_DGRAM | C.SOCK_CLOEXEC, 0)
	C.sendto(peer, c'x', 1, 0, voidptr(&a[0]), 16)
	return fd, peer
}

// The guard must not keep every socket on the listener's address: an app
// socket of another kind there (here a UDP socket on the listener's port),
// kept open by a continuation that steps away from it, is detached as
// before. Left registered and readable, it would report on every wait, with
// no watch and no connection behind it, and the worker would spin.
fn test_epoll_step_away_from_an_app_socket_on_the_listener_port() {
	rp_reset(false)
	mut h := start(server.ServerConfig{
		handler: handle
	})
	defer {
		h.stop()
	}
	udp, peer := udp_on_loopback(h.port())
	mut p := unsafe { rp }
	stdatomic.store_i64(&p.shared_fd, udp)
	c1 := tcp_socket()
	defer {
		C.close(c1)
		C.close(udp)
		C.close(peer)
	}
	tcp_connect(c1, h.port())
	send_str(c1, 'GET /udp HTTP/1.1\r\nHost: x\r\n\r\n')
	assert read_until(c1, stepped_resp.len) == stepped_resp
	still := in_epoll(loop_fd(), udp)
	cpu0 := C.clock()
	time.sleep(300 * time.millisecond)
	cpu_us := C.clock() - cpu0
	eprintln('[udp on the listener port, kept open] still in the worker epoll: ${still}; process CPU in 300 ms: ${cpu_us} us')
	assert !still, 'the app socket was left in the worker epoll'
	assert cpu_us < 100_000, 'the worker spun on a readable app socket left registered: ${cpu_us} us of CPU in 300 ms'
}

// ── pg_async: a re-dial in a continuation that steps away ───────────────────

const redialed_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\nredialed'

struct FakePg {
mut:
	proc &os.Process = unsafe { nil }
	port int
}

// start_fake_pg launches tests/testdata/fake_pg.py on an ephemeral port, or
// returns none (the test then skips) when python3 is not installed.
fn start_fake_pg() ?FakePg {
	python := os.find_abs_path_of_executable('python3') or {
		eprintln('late_detach pg case: python3 not found, skipping')
		return none
	}
	script := os.join_path(os.dir(@FILE), 'testdata', 'fake_pg.py')
	port_file := os.join_path(os.vtmp_dir(), 'vanilla_fake_pg_${os.getpid()}_${time.sys_mono_now()}.port')
	mut p := os.new_process(python)
	p.set_args([script, port_file, '120'])
	p.run()
	for _ in 0 .. 1000 {
		if os.exists(port_file) {
			port := (os.read_file(port_file) or { '' }).trim_space().int()
			os.rm(port_file) or {}
			if port > 0 {
				return FakePg{
					proc: p
					port: port
				}
			}
		}
		if !p.is_alive() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	p.signal_kill()
	p.wait()
	panic('fake_pg.py did not start')
}

fn (mut f FakePg) stop() {
	f.proc.signal_kill()
	f.proc.wait()
	f.proc.close()
}

// redial_password is the pool's password_fn. During the re-dial of the lost
// connection it runs after redial_start closed the old socket and before it
// makes the new one: the choreography runs there.
fn redial_password() !string {
	if stdatomic.load_i64(&rp.redial) == 1 {
		mut p := unsafe { rp }
		stdatomic.store_i64(&p.redial, 0)
		choreograph(freed(), loop_fd())
	}
	return 'secret'
}

fn make_redial_pool() voidptr {
	cfg := pg_async.ConnConfig{
		host:        '127.0.0.1'
		port:        os.getenv('VANILLA_FAKE_PG_PORT').int()
		user:        'u'
		password_fn: redial_password
		database:    'd'
	}
	pool := pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') }
	return voidptr(pool)
}

// pg_handle parks on connection 0 with a query the fake answers by
// terminating the backend (FATAL 57P01, then close).
fn pg_handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !(req.len > 9 && req[5] == `r`) { // GET /redial
		core.append_str(mut out, ok_resp)
		return .done
	}
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.acquire() or {
		core.append_str(mut out, error_resp)
		return .done
	}
	mut conn := pool.conn(idx)
	if !conn.async_submit('select fatal', []?[]u8{}) {
		pool.release(idx)
		core.append_str(mut out, error_resp)
		return .done
	}
	conn.async_flush() or {}
	event_loop.watch_fd_persistent(pool.fd(idx), .readable, on_lost, unsafe { nil })
	return .suspend
}

// on_lost finds the connection lost, hands it back and runs the request on
// another one: acquire() re-dials the lost one first, closing its socket.
fn on_lost(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.idx_of_fd(ready_fd) or { return .close }
	mut conn := pool.conn(idx)
	poll := conn.async_on_readable() or {
		pool.release(idx)
		mut p := unsafe { rp }
		stdatomic.store_i64(&p.freed, ready_fd)
		stdatomic.store_i64(&p.loop_fd, event_loop.loop_fd)
		stdatomic.store_i64(&p.redial, 1)
		next := pool.acquire() or {
			core.append_str(mut out, error_resp)
			return .done
		}
		mut c := pool.conn(next)
		if !c.async_submit('select 7', []?[]u8{}) {
			pool.release(next)
			core.append_str(mut out, error_resp)
			return .done
		}
		c.async_flush() or {}
		event_loop.watch_fd_persistent(pool.fd(next), .readable, on_second, unsafe { nil })
		return .suspend
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, .readable, on_lost, unsafe { nil })
		return .suspend
	}
	pool.release(idx) // a reply instead of the FATAL
	core.append_str(mut out, error_resp)
	return .done
}

fn on_second(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut pool := unsafe { &pg_async.PgPool(worker_state) }
	idx := pool.idx_of_fd(ready_fd) or { return .close }
	mut conn := pool.conn(idx)
	poll := conn.async_on_readable() or {
		pool.release(idx)
		core.append_str(mut out, error_resp)
		return .done
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, .readable, on_second, unsafe { nil })
		return .suspend
	}
	pool.release(idx)
	core.append_str(mut out, redialed_resp)
	return .done
}

fn test_epoll_redial_in_a_continuation_that_steps_away() {
	mut fake := start_fake_pg() or { return }
	defer {
		fake.stop()
	}
	os.setenv('VANILLA_FAKE_PG_PORT', fake.port.str(), true)
	rp_reset(true)
	mut h := start(server.ServerConfig{
		handler:    pg_handle
		make_state: make_redial_pool
	})
	defer {
		h.stop()
	}
	c1 := tcp_socket()
	socks := tcp_sockets(victims)
	defer {
		C.close(c1)
		close_all(socks)
	}
	tcp_connect(c1, h.port())
	send_str(c1, 'GET /redial HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_go(), 'the re-dial never reached password_fn'
	clients := connect_until_reused(h.port(), socks)
	r1 := read_until(c1, redialed_resp.len)
	still := in_epoll(loop_fd(), freed())
	report('pg re-dial, socket closed', still)
	served := all_served('pg re-dial, socket closed', clients)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert r1 == redialed_resp
	assert still, 'a late EPOLL_CTL_DEL took the client on fd ${freed()} out of the worker epoll'
	assert served, 'a client was never served'
}
