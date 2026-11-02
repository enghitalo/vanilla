// vtest build: linux
// A watch slot that stays active after the app closed its fd must never get
// a later file's events (vanilla#342). The epoll worker sends an event on a
// number with an active watch slot to that watch before anything else, and a
// slot can outlive its fd: a caller-owned watch whose park timed out becomes
// a tombstone once its continuation returns (retire_watch), and the requests
// queued on a pipelined fd keep their slots whoever closes it. The kernel
// then gives the number to the next file: a client the accept thread
// registers in this worker's epoll, or an fd a later request watches. Its
// events ran the old watch's continuation, with the new file as ready_fd: the
// client's request was never read (its edge-triggered EPOLLIN was spent
// there), and the new watch waited behind a continuation that consumed its
// readiness.
//
// Each case forces its interleaving, as late_detach_test.v does, with
// `workers: 1` so that every client lands on the worker that holds the slot:
//   * the issue's repro: a timed-out continuation close()s its caller-owned
//     fd and answers 504, and before it returns, the accept thread registers
//     a new client under the freed number (births off and on);
//   * a pipelined queue: the head closes the shared fd, and the tombstone
//     queued behind it waits on, until a client gets the number;
//   * a request parked on an fd that another request's handler closes;
//   * a later request watches a new fd that got the number;
//   * the guard (Reactor.waits_on): a queue's head closes the shared fd, opens
//     a new one that gets the number (a re-dial) and watches it, all in its
//     own run, then answers. That watch is the run's re-arm of the slot it
//     runs from, which must stay in place: drain_pipelined pops it after the
//     run. Retired there, the pop found an empty queue and the worker
//     panicked, and the request queued behind was closed.
// Every client must be served, the closed fd's continuations must never run
// again, and a request still parked on the closed fd is closed: nothing can
// resume it (except in the guard's case, where its slot stays as it was).
module main

import os
import core
import server
import sync.stdatomic
import time
import vtest

#include <fcntl.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include "@VMODROOT/core/libc_shim.h"

fn C.eventfd(initval u32, flags int) int
fn C.vanilla_read(fd int, buf voidptr, count u64) int
fn C.vanilla_write(fd int, buf voidptr, count u64) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.socket(domain int, typ int, protocol int) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.vanilla_send(fd int, buf voidptr, n u64, flags int) int
fn C.vanilla_recv(fd int, buf voidptr, n u64, flags int) int
fn C.setsockopt(fd int, level int, opt int, val voidptr, len u32) int
fn C.shutdown(fd int, how int) int

const ok_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
const closed_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nclosed'
const again_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nagain'
const late_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nlate'
const kept_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nkept'
const timeout_resp = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// victims is how many clients a case can connect before one gets the freed
// number: more than the numbers the cases before it leave free.
const victims = 12

// Ss is the choreography between a test and the server's handlers and
// continuations. One case runs at a time.
struct Ss {
mut:
	hold      i64 // 1: the code that closes the fd waits until a client got its number
	freed     i64 = -1 // the number the app closed
	loop_fd   i64 = -1 // the worker's epoll fd
	go        i64 // the number is free: connect now
	reused    i64 // another file got the freed number: a client the accept thread registered, or /again's fd
	shared_fd i64 = -1 // /pipe, /park: the persistent fd the requests park on
	parks     i64 // requests parked on it
	behind    i64 // runs of the continuation queued behind /pipe's head, on the head's edge
	again_fd  i64 = -1 // /again: the new fd that got the freed number
	old_runs  i64 // runs of a closed fd's continuation after the close
	old_fd    i64 = -1 // the ready_fd of the last such run
}

const ss = &Ss{}

fn ss_reset(hold bool) {
	mut p := unsafe { ss }
	stdatomic.store_i64(&p.hold, if hold { 1 } else { 0 })
	for f in [&p.go, &p.reused, &p.parks, &p.behind, &p.old_runs] {
		stdatomic.store_i64(f, 0)
	}
	for f in [&p.freed, &p.loop_fd, &p.shared_fd, &p.again_fd, &p.old_fd] {
		stdatomic.store_i64(f, -1)
	}
}

fn freed() int {
	return int(stdatomic.load_i64(&ss.freed))
}

fn loop_fd() int {
	return int(stdatomic.load_i64(&ss.loop_fd))
}

fn reused() bool {
	return stdatomic.load_i64(&ss.reused) == 1
}

fn old_runs() int {
	return int(stdatomic.load_i64(&ss.old_runs))
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

// taken reports whether the accept thread gave number n to a client and
// registered it in epoll instance ep. The fcntl comes first: reading /proc
// opens a file, which would take n while it is free.
fn taken(n int, ep int) bool {
	return C.fcntl(n, C.F_GETFD, 0) >= 0 && in_epoll(ep, n)
}

// closed_fd runs where the app closes fd n: it lets the test connect clients
// and, with ss.hold set, returns only once the accept thread has registered
// one of them under n in this worker's epoll.
fn closed_fd(n int, ep int) {
	mut p := unsafe { ss }
	stdatomic.store_i64(&p.freed, n)
	stdatomic.store_i64(&p.loop_fd, ep)
	stdatomic.store_i64(&p.go, 1)
	if stdatomic.load_i64(&p.hold) == 0 {
		return
	}
	// The monotonic clock: time.now()'s first call opens /etc/localtime, an
	// fd that could take the freed number.
	deadline := time.sys_mono_now() + 5_000_000_000
	for time.sys_mono_now() < deadline {
		if taken(n, ep) {
			stdatomic.store_i64(&p.reused, 1)
			return
		}
	}
}

// old_run records a run of a closed fd's continuation: only a later file's
// readiness can wake it.
fn old_run(ready_fd int) {
	mut p := unsafe { ss }
	stdatomic.add_i64(&p.old_runs, 1)
	stdatomic.store_i64(&p.old_fd, ready_fd)
}

fn drain(fd int) int {
	mut tmp := [8]u8{}
	return C.vanilla_read(fd, &tmp[0], 8)
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.len > 9 && req[5] == `p` && req[6] == `o` { // GET /pooled
		// A pooled connection that never answers (an eventfd nobody writes),
		// parked on with a deadline.
		pooled := C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		event_loop.watch_fd_persistent_deadline(pooled, .readable, on_pooled, unsafe { nil },
			20)
		return .suspend
	}
	if req.len > 9 && (req[5] == `p` || req[5] == `r`) { // GET /pipe, /park, /reopen: park on the shared fd
		mut p := unsafe { ss }
		mut shared := int(stdatomic.load_i64(&ss.shared_fd))
		if shared < 0 {
			shared = C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
			stdatomic.store_i64(&p.shared_fd, shared)
		}
		parks := stdatomic.load_i64(&ss.parks)
		cont := if req[5] == `r` && parks == 0 {
			core.WakeFn(head_reopen)
		} else if req[5] == `r` {
			core.WakeFn(kept)
		} else if req[6] == `i` && parks == 0 {
			core.WakeFn(head_close)
		} else if req[6] == `i` {
			core.WakeFn(behind)
		} else {
			core.WakeFn(parked)
		}
		event_loop.watch_fd_persistent(shared, .readable, cont, unsafe { nil })
		stdatomic.store_i64(&p.parks, parks + 1)
		return .suspend
	}
	if req.len > 9 && req[5] == `k` { // GET /kill: close the shared fd under its parked request
		C.close(int(stdatomic.load_i64(&ss.shared_fd)))
		closed_fd(int(stdatomic.load_i64(&ss.shared_fd)), event_loop.loop_fd)
		core.append_str(mut out, closed_resp)
		return .done
	}
	if req.len > 9 && req[5] == `a` { // GET /again: watch a new fd under the freed number
		fd := fd_numbered(freed())
		if fd < 0 {
			core.append_str(mut out, ok_resp) // the number is taken: the test reports it
			return .done
		}
		event_loop.watch_fd(fd, .readable, on_again, unsafe { nil })
		mut p := unsafe { ss }
		stdatomic.store_i64(&p.reused, 1)
		stdatomic.store_i64(&p.again_fd, fd)
		return .suspend
	}
	core.append_str(mut out, ok_resp)
	return .done
}

// fd_numbered makes an eventfd numbered n, which must be free: the kernel
// gives the lowest free number, so it holds the lower ones it gets on the
// way, then closes them. -1 when n is not reached.
fn fd_numbered(n int) int {
	mut extra := []int{}
	mut got := -1
	for _ in 0 .. 64 {
		fd := C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		if fd == n {
			got = fd
			break
		}
		if fd < 0 || fd > n {
			if fd >= 0 {
				C.close(fd)
			}
			break
		}
		extra << fd
	}
	for fd in extra {
		C.close(fd)
	}
	return got
}

// on_pooled gives up on its pooled connection when its park times out: it
// close()s it, where EventLoop.timed_out's doc says shutdown(2), and answers
// 504. The watch then becomes a tombstone (retire_watch) and its slot stays
// active.
fn on_pooled(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if event_loop.timed_out() {
		C.close(ready_fd)
		closed_fd(ready_fd, event_loop.loop_fd)
		core.append_str(mut out, timeout_resp)
		return .done
	}
	// The tombstone's run: its fd is closed, so this is another file's
	// readiness, consumed as a pooled connection's reply would be.
	old_run(ready_fd)
	drain(ready_fd)
	return .done
}

// head_close is the head of the queue on the shared fd: it consumes its
// reply, closes the connection and answers.
fn head_close(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	C.close(ready_fd)
	closed_fd(ready_fd, event_loop.loop_fd)
	core.append_str(mut out, closed_resp)
	return .done
}

// behind is queued behind head_close; its client left, so it runs as a
// tombstone. On the head's edge, its reply is not there: it waits on. Any
// later run is on another file.
fn behind(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { ss }
	if stdatomic.load_i64(&ss.behind) > 0 {
		old_run(ready_fd)
		drain(ready_fd)
		return .done
	}
	stdatomic.store_i64(&p.behind, 1)
	event_loop.watch_fd_persistent(ready_fd, .readable, behind, unsafe { nil })
	return .suspend
}

// head_reopen is the head of the queue on the shared fd: it consumes its
// reply, closes the connection and opens a new one, which gets the same
// number (as a pool's re-dial would), and watches it. Then it answers after
// all: a .done after its watch, which drain_pipelined takes as a rejected
// park and pops (the watch's continuation, parked, must never run).
fn head_reopen(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	C.close(ready_fd)
	fd := fd_numbered(ready_fd)
	if fd >= 0 {
		mut p := unsafe { ss }
		stdatomic.store_i64(&p.freed, fd)
		stdatomic.store_i64(&p.reused, 1)
		event_loop.watch_fd_persistent(fd, .readable, parked, unsafe { nil })
	}
	core.append_str(mut out, closed_resp)
	return .done
}

// kept is queued behind head_reopen, on the same number: it waits until the
// fd under that number is ready, then answers.
fn kept(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if drain(ready_fd) != 8 {
		event_loop.watch_fd_persistent(ready_fd, .readable, kept, unsafe { nil })
		return .suspend
	}
	core.append_str(mut out, kept_resp)
	return .done
}

// parked is a live request's continuation on the shared fd that /kill
// closes: any run of it comes after the close.
fn parked(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	old_run(ready_fd)
	drain(ready_fd)
	core.append_str(mut out, late_resp)
	return .done
}

// on_again waits for its own fd's readiness, re-arming while there is none.
fn on_again(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if drain(ready_fd) != 8 {
		event_loop.watch_fd(ready_fd, .readable, on_again, unsafe { nil })
		return .suspend
	}
	C.close(ready_fd)
	core.append_str(mut out, again_resp)
	return .done
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
	C.vanilla_send(fd, s.str, u64(s.len), 0)
}

// read_until reads until `want` bytes arrived, the peer closes, or 3 s pass.
fn read_until(fd int, want int) string {
	mut buf := []u8{len: 4096}
	mut got := 0
	// A socket call with SO_RCVTIMEO is not restarted after a signal (the GC's
	// stop-the-world ones): retry on EINTR, up to the overall 3 s.
	deadline := time.sys_mono_now() + 3_000_000_000
	for got < want && time.sys_mono_now() < deadline {
		n := C.vanilla_recv(fd, unsafe { &buf[got] }, u64(buf.len - got), 0)
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

// wait_eof reports whether the peer closed fd within 3 s, with nothing sent
// before.
fn wait_eof(fd int) bool {
	mut b := [1]u8{}
	deadline := time.sys_mono_now() + 3_000_000_000
	for time.sys_mono_now() < deadline {
		n := C.vanilla_recv(fd, &b[0], 1, 0)
		if n == 0 {
			return true
		}
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		return false
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

// connect_until_reused connects the clients in socks one at a time, each
// sending GET /, until the freed number went to one of them: as the code
// that closed it saw (ss.hold), or as this thread sees. Returns the clients
// it connected.
fn connect_until_reused(port int, socks []int) []int {
	mut p := unsafe { ss }
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
			if stdatomic.load_i64(&ss.hold) == 0 && taken(freed(), loop_fd()) {
				stdatomic.store_i64(&p.reused, 1)
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

fn report(name string) {
	eprintln("[${name}] freed fd=${freed()} went to another file: ${reused()}; runs of the closed fd's continuation: ${old_runs()} (last ready_fd=${stdatomic.load_i64(&ss.old_fd)})")
}

fn start(cfg server.ServerConfig) &vtest.Harness {
	return vtest.start(server.ServerConfig{
		...cfg
		io_multiplexing: .epoll
		workers:         1
		handler:         handle
	}) or { panic(err) }
}

// The issue's repro: the timed-out continuation closes its caller-owned fd
// and, before it returns, the accept thread registers a client under the
// number. The tombstone then stays on the client's number.
fn timed_out_close_case(name string, limits server.Limits) {
	ss_reset(true)
	mut h := start(server.ServerConfig{
		limits: limits
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
	send_str(c1, 'GET /pooled HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.go, 1), 'the park did not time out'
	clients := connect_until_reused(h.port(), socks)
	r1 := read_until(c1, timeout_resp.len)
	served := all_served(name, clients)
	report(name)
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert r1 == timeout_resp
	assert served, 'a client was never served: the tombstone ran on its socket (ready_fd=${stdatomic.load_i64(&ss.old_fd)})'
	assert old_runs() == 0, 'the tombstone of a closed fd ran on another file'
}

fn test_epoll_timed_out_continuation_closing_its_persistent_fd() {
	timed_out_close_case('timed out, fd closed', server.Limits{})
}

// The same with accept-time births on (a read timeout): the client is born
// from the birth queue before its first event reaches the slot.
fn test_epoll_timed_out_continuation_closing_its_persistent_fd_births_on() {
	timed_out_close_case('timed out, fd closed, births on', server.Limits{
		read_timeout_ms: 5000
	})
}

// A pipelined queue: the head closes the shared fd and answers; the
// tombstone behind it (its client left) re-arms on the same edge and waits.
// The slot stays active, and a client gets the number afterwards.
fn test_epoll_queue_whose_head_closes_the_fd() {
	ss_reset(false)
	mut h := start(server.ServerConfig{})
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
	assert wait_for(&ss.parks, 1), 'the first request did not park'
	tcp_connect(cb, h.port())
	send_str(cb, 'GET /pipe HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.parks, 2), 'the second request did not park'
	// Half-close: the server sees the second client leave and closes its
	// side, which tombstones its slot; cb keeps its number.
	C.shutdown(cb, C.SHUT_WR)
	assert wait_eof(cb), 'the server did not close the connection of a client that left'
	one := u64(1)
	C.vanilla_write(int(stdatomic.load_i64(&ss.shared_fd)), &one, 8) // the head's reply
	ra := read_until(ca, closed_resp.len)
	assert ra == closed_resp
	assert wait_for(&ss.behind, 1), 'the tombstone behind the head did not run'
	clients := connect_until_reused(h.port(), socks)
	served := all_served('queue, head closed the fd', clients)
	report('queue, head closed the fd')
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert served, 'a client was never served: the tombstone ran on its socket (ready_fd=${stdatomic.load_i64(&ss.old_fd)})'
	assert old_runs() == 0, 'the tombstone of a closed fd ran on another file'
}

// A request parked on a pooled fd that another request's handler closes
// (and holds until a client gets the number): nothing can resume the parked
// request any more, so its connection is closed, and the client is served.
fn test_epoll_request_parked_on_an_fd_closed_under_it() {
	ss_reset(true)
	mut h := start(server.ServerConfig{})
	defer {
		h.stop()
	}
	ca := tcp_socket()
	ck := tcp_socket()
	socks := tcp_sockets(victims)
	defer {
		C.close(ca)
		C.close(ck)
		close_all(socks)
	}
	tcp_connect(ca, h.port())
	send_str(ca, 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.parks, 1), 'the request did not park'
	tcp_connect(ck, h.port())
	send_str(ck, 'GET /kill HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.go, 1), 'the handler did not close the shared fd'
	clients := connect_until_reused(h.port(), socks)
	rk := read_until(ck, closed_resp.len)
	served := all_served('parked request, fd closed', clients)
	eof := wait_eof(ca)
	report('parked request, fd closed')
	assert reused(), 'interleaving not reached: no client got the freed number'
	assert rk == closed_resp
	assert served, 'a client was never served: the parked request ran on its socket (ready_fd=${stdatomic.load_i64(&ss.old_fd)})'
	assert old_runs() == 0, 'the continuation of a closed fd ran on another file'
	assert eof, 'the request parked on the closed fd was neither answered by it nor closed'
}

// A later request watches a new fd that got the closed fd's number while
// its tombstone still holds the slot: the new watch must get its own
// readiness, not wait behind the tombstone, which would consume it.
fn test_epoll_new_watch_on_the_number_of_a_closed_fd() {
	ss_reset(false)
	mut h := start(server.ServerConfig{})
	defer {
		h.stop()
	}
	c1 := tcp_socket()
	c2 := tcp_socket()
	defer {
		C.close(c1)
		C.close(c2)
	}
	// Both connected before the number is freed, so neither takes it.
	tcp_connect(c1, h.port())
	tcp_connect(c2, h.port())
	send_str(c1, 'GET /pooled HTTP/1.1\r\nHost: x\r\n\r\n')
	assert read_until(c1, timeout_resp.len) == timeout_resp
	send_str(c2, 'GET /again HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.again_fd, 0), 'interleaving not reached: no new fd got the freed number ${freed()}'
	one := u64(1)
	C.vanilla_write(int(stdatomic.load_i64(&ss.again_fd)), &one, 8) // the new fd is ready
	r2 := read_until(c2, again_resp.len)
	report('new watch on the number')
	assert r2 == again_resp, 'the new watch was never woken: the tombstone consumed its readiness (${r2.len} bytes)'
	assert old_runs() == 0, 'the tombstone of a closed fd ran on another file'
}

// The guard (Reactor.waits_on). A queue's head closes the shared fd, opens a
// new one that gets the number and watches it, all in its own run (the MOD
// fails, as for any new file under a closed fd's number), then answers. That
// run keeps its slot in place and drain_pipelined pops the head after it, so
// the watch must update the slot, not retire it. Retired, the pop found an
// empty queue (array.delete panicked, which ends the process) and the request
// queued behind was closed. Kept, that request waits on the new fd, answers
// once it is ready, and the server stays up.
fn test_epoll_head_reopening_its_fd_under_the_same_number() {
	ss_reset(false)
	mut h := start(server.ServerConfig{})
	defer {
		h.stop()
	}
	ca := tcp_socket()
	cb := tcp_socket()
	cc := tcp_socket()
	defer {
		C.close(ca)
		C.close(cb)
		C.close(cc)
	}
	tcp_connect(ca, h.port())
	send_str(ca, 'GET /reopen HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.parks, 1), 'the first request did not park'
	tcp_connect(cb, h.port())
	send_str(cb, 'GET /reopen HTTP/1.1\r\nHost: x\r\n\r\n')
	assert wait_for(&ss.parks, 2), 'the second request did not park'
	one := u64(1)
	C.vanilla_write(int(stdatomic.load_i64(&ss.shared_fd)), &one, 8) // the head's reply
	ra := read_until(ca, closed_resp.len)
	report('head reopens its fd')
	assert reused(), 'interleaving not reached: the head did not get the number back'
	assert ra == closed_resp
	C.vanilla_write(freed(), &one, 8) // the new fd under that number is ready
	rb := read_until(cb, kept_resp.len)
	tcp_connect(cc, h.port())
	send_str(cc, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n')
	rc := read_until(cc, ok_resp.len)
	assert rb == kept_resp, 'the request queued behind the head was dropped (${rb.len} bytes)'
	assert rc == ok_resp
	assert old_runs() == 0, "the head's rejected watch ran"
	C.close(freed())
}
