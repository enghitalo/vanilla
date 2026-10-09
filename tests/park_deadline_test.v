// vtest build: linux
// Park deadlines (vanilla#200) on the epoll plain worker. A request parked on
// a watch whose fd never becomes ready (a hung database or upstream: here the
// read end of a pipe nobody writes) used to wait forever, with every Limits
// timeout set, because a parked request has no read, write or idle deadline.
// Now Limits.park_timeout_ms and watch_fd_deadline bound it: the continuation
// runs once with event_loop.timed_out() and answers 504.
//
// The checks:
//   * the issue's repro with park_timeout_ms, and with a per-watch deadline
//     and default Limits (no other timeout, so no sweep runs): 504 within the
//     deadline plus slack, the continuation timed out exactly once;
//   * park_timeout_ms 0 keeps today's behaviour: no answer, connection open;
//   * a negative per-watch deadline exempts a park from park_timeout_ms;
//   * a request-owned fd that becomes ready after the deadline wakes nothing:
//     the continuation does not run again and the worker does not spin;
//   * a caller-owned (persistent) fd: the late reply is drained in order by a
//     tombstone run, so the next request on that fd gets its own reply; also
//     with a pipelined queue, where the slot that times out is not the head;
//   * a continuation that re-arms on timeout keeps waiting, with a new deadline;
//   * a taken-over connection parked with a deadline resumes its protocol;
//   * watch_fd_background arms a clientless watch from a handler;
//   * io_uring: the deadline is not enforced and nothing breaks.
// The shutdown drain bounded by a park deadline is in shutdown_drain_test.v.
import server
import core
import sync.stdatomic
import time
import transport
import testkit
import vtest

#include <unistd.h>
#include <sys/socket.h>

fn C.pipe(fds &i32) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.recv(fd int, buf voidptr, len usize, flags int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.clock() i64

const pd_504 = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const pd_ok_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n'

const pd_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

// PdState holds the fds the handlers park on and what the continuations saw.
// The handlers run on the worker thread, the checks on the test thread: every
// field is read and written atomically. -1 = unset.
struct PdState {
mut:
	never_r i64 = -1 // the hung upstream: a pipe's read end
	never_w i64 = -1 // its write end, written only by the late-readiness check
	db0     i64 = -1 // the pooled "DB" connection: the end the server parks on
	db1     i64 = -1 // the "DB" itself: one byte per result
	bg_w    i64 = -1 // the write end of /bg's background pipe
	// counters (pd_reset)
	runs     i64 // continuation runs on readiness, tombstone drains included
	timeouts i64 // continuation runs with event_loop.timed_out()
	drained  i64 // results the /pq continuations consumed off the "DB"
	bg_runs  i64 // runs of /bg's background continuation
}

const pd = &PdState{}

fn pd_load(p &i64) int {
	return int(stdatomic.load_i64(p))
}

fn pd_reset() {
	mut p := unsafe { pd }
	for f in [&p.runs, &p.timeouts, &p.drained, &p.bg_runs] {
		stdatomic.store_i64(f, 0)
	}
}

// pd_open makes the hung upstream (a pipe) and the "DB" (a socketpair).
fn pd_open() {
	mut p := unsafe { pd }
	mut fds := [2]i32{}
	assert C.pipe(&fds[0]) == 0
	stdatomic.store_i64(&p.never_r, i64(fds[0]))
	stdatomic.store_i64(&p.never_w, i64(fds[1]))
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) == 0
	stdatomic.store_i64(&p.db0, i64(sv[0]))
	stdatomic.store_i64(&p.db1, i64(sv[1]))
	pd_reset()
}

// pd_close closes them, once the server that parked on them is stopped.
fn pd_close() {
	mut p := unsafe { pd }
	for f in [&p.never_r, &p.never_w, &p.db0, &p.db1, &p.bg_w] {
		fd := stdatomic.load_i64(f)
		if fd >= 0 {
			stdatomic.store_i64(f, -1)
			C.close(int(fd))
		}
	}
}

fn pd_has_prefix(req []u8, prefix string) bool {
	if req.len < prefix.len {
		return false
	}
	for i in 0 .. prefix.len {
		if req[i] != prefix[i] {
			return false
		}
	}
	return true
}

fn pd_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	p := unsafe { pd }
	never := pd_load(&p.never_r)
	db := pd_load(&p.db0)
	if pd_has_prefix(req, 'GET /never ') {
		// The issue's repro: no deadline of its own, so park_timeout_ms (if any).
		event_loop.watch_fd(never, .readable, pd_never_cont, unsafe { nil })
		return .suspend
	}
	if pd_has_prefix(req, 'GET /never300 ') {
		event_loop.watch_fd_deadline(never, .readable, pd_never_cont, unsafe { nil }, 300)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /exempt ') {
		event_loop.watch_fd_deadline(never, .readable, pd_never_cont, unsafe { nil }, -1)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /pnever ') {
		// The issue's exact repro: a persistent watch with no deadline.
		event_loop.watch_fd_persistent(never, .readable, pd_never_cont, unsafe { nil })
		return .suspend
	}
	if pd_has_prefix(req, 'GET /keep ') {
		// Times out twice: the first timeout re-arms (keep waiting) once.
		event_loop.watch_fd_deadline(never, .readable, pd_never_cont, voidptr(usize(1)),
			150)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /pq200 ') {
		event_loop.watch_fd_persistent_deadline(db, .readable, pd_pq_cont, voidptr(usize(200)),
			200)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /pqbg200 ') {
		// /pq200 whose readiness run (here: the tombstone's) also arms a
		// background watch (pd_bg_flag).
		event_loop.watch_fd_persistent_deadline(db, .readable, pd_pq_cont, voidptr(usize(200) | pd_bg_flag),
			200)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /pq5000 ') {
		event_loop.watch_fd_persistent_deadline(db, .readable, pd_pq_cont, voidptr(usize(5000)),
			5000)
		return .suspend
	}
	if pd_has_prefix(req, 'GET /lines ') {
		if !core.queue_takeover(pd_line_conn, unsafe { nil }) {
			core.append_str(mut out, 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n')
			return .close
		}
		core.append_str(mut out, 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n')
		return .done
	}
	if pd_has_prefix(req, 'GET /bg ') {
		mut fds := [2]i32{}
		C.pipe(&fds[0])
		mut pm := unsafe { pd }
		stdatomic.store_i64(&pm.bg_w, i64(fds[1]))
		armed := event_loop.watch_fd_background(int(fds[0]), .readable, pd_bg_cont, unsafe { nil })
		if !armed {
			C.close(int(fds[0])) // still the caller's (see watch_fd_background)
		}
		core.append_str(mut out, pd_ok_head)
		out << u8(if armed { `1` } else { `0` })
		return .done
	}
	core.append_str(mut out, pd_ok)
	return .done
}

// pd_never_cont answers a park on the hung upstream. On timeout: 504, or,
// while watch_payload (re-arms left) is > 0, keep waiting with a new deadline.
// On readiness (never, unless a check writes the pipe): 200 with the byte.
fn pd_never_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { pd }
	if event_loop.timed_out() {
		stdatomic.add_i64(&p.timeouts, 1)
		left := int(usize(watch_payload))
		if left > 0 {
			event_loop.watch_fd_deadline(ready_fd, .readable, pd_never_cont, voidptr(usize(left - 1)),
				150)
			return .suspend
		}
		core.append_str(mut out, pd_504)
		return .done
	}
	stdatomic.add_i64(&p.runs, 1)
	mut b := [1]u8{}
	C.read(ready_fd, &b[0], 1)
	core.append_str(mut out, pd_ok_head)
	out << b[0]
	return .done
}

// pd_bg_flag in a /pq watch_payload: its readiness run arms a background
// watch on a fresh pipe, as pg_async's cancel() does from a continuation.
const pd_bg_flag = usize(1) << 20

// pd_pq_cont is a pooled-DB continuation (pg_async's shape): one byte is one
// result. watch_payload is the deadline to re-arm with (and pd_bg_flag). On
// timeout it answers 504 and leaves the result still due alone: the
// tombstone run consumes it.
fn pd_pq_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { pd }
	if event_loop.timed_out() {
		stdatomic.add_i64(&p.timeouts, 1)
		core.append_str(mut out, pd_504)
		return .done
	}
	stdatomic.add_i64(&p.runs, 1)
	if usize(watch_payload) & pd_bg_flag != 0 {
		mut fds := [2]i32{}
		C.pipe(&fds[0])
		stdatomic.store_i64(&p.bg_w, i64(fds[1]))
		if !event_loop.watch_fd_background(int(fds[0]), .readable, pd_bg_cont, unsafe { nil }) {
			C.close(int(fds[0]))
		}
	}
	mut b := [1]u8{}
	if C.read(ready_fd, &b[0], 1) != 1 {
		event_loop.watch_fd_persistent_deadline(ready_fd, .readable, pd_pq_cont, watch_payload,
			int(usize(watch_payload) & (pd_bg_flag - 1)))
		return .suspend
	}
	stdatomic.add_i64(&p.drained, 1)
	core.append_str(mut out, pd_ok_head)
	out << b[0]
	return .done
}

// pd_line_conn is a line protocol over takeover: `wait` parks on the hung
// upstream with a 200 ms deadline, anything else is echoed.
fn pd_line_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut end := 0
	for end < buf.len && buf[end] != `\n` {
		end++
	}
	if end == buf.len {
		return 0, .done // partial line
	}
	if end == 4 && buf[0] == `w` && buf[1] == `a` && buf[2] == `i` && buf[3] == `t` {
		p := unsafe { pd }
		event_loop.watch_fd_deadline(pd_load(&p.never_r), .readable, pd_line_cont, unsafe { nil },
			200)
		return end + 1, .suspend
	}
	core.append_str(mut out, 'echo:')
	unsafe { out.push_many(&buf[0], end + 1) }
	return end + 1, .done
}

fn pd_line_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { pd }
	if event_loop.timed_out() {
		stdatomic.add_i64(&p.timeouts, 1)
		core.append_str(mut out, 'timeout\n')
	} else {
		stdatomic.add_i64(&p.runs, 1)
		core.append_str(mut out, 'ready\n')
	}
	return .done
}

// pd_bg_cont is /bg's clientless continuation: count, then .done (the runtime
// closes the pipe's read end).
fn pd_bg_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut p := unsafe { pd }
	stdatomic.add_i64(&p.bg_runs, 1)
	return .done
}

fn pd_config(backend server.IOBackend, limits server.Limits) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing: backend
		handler:         pd_handler
		workers:         1 // every connection on one worker: /pq clients share its queue
		limits:          limits
	}
}

fn pd_send(port int, req string) !int {
	fd := transport.dial_tcp('127.0.0.1', port)!
	if !testkit.fd_write_all(fd, req.bytes(), 3000) {
		transport.close_fd(fd)
		return error('could not write the request')
	}
	return fd
}

// pd_until waits, for at most 3 s, until *counter reaches want; the last value.
fn pd_until(counter &i64, want int) int {
	for _ in 0 .. 3000 {
		if pd_load(counter) >= want {
			break
		}
		time.sleep(time.millisecond)
	}
	return pd_load(counter)
}

// pd_open_conn reports whether the server still holds fd open: nothing to
// read, no EOF.
fn pd_open_conn(fd int) bool {
	mut b := [1]u8{}
	n := C.recv(fd, &b[0], 1, C.MSG_DONTWAIT | C.MSG_PEEK)
	return n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK)
}

fn pd_write(p &i64, s string) {
	fd := pd_load(p)
	C.write(fd, s.str, usize(s.len))
}

// --- the issue's repro ----------------------------------------------------------

// The issue's Limits, every timeout 300 ms, plus park_timeout_ms 300: the
// parked request gets the continuation's 504 at ~300 ms (the heap fires
// within a millisecond or so; the slack is for loaded CI), once.
fn test_epoll_park_timeout_answers_hung_park() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{
		read_timeout_ms:  300
		write_timeout_ms: 300
		idle_timeout_ms:  300
		park_timeout_ms:  300
	}))!
	defer {
		h.stop()
		pd_close()
	}
	sw := time.new_stopwatch()
	fd := pd_send(h.port(), 'GET /never HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	el := sw.elapsed().milliseconds()
	p := unsafe { pd }
	assert got.starts_with('HTTP/1.1 504 '), 'parked request: no 504 after ${el} ms: ${got}'
	assert el >= 280, 'answered after ${el} ms, before its 300 ms deadline'
	assert el < 1500, 'answered after ${el} ms: the 300 ms deadline fired late'
	assert pd_load(&p.timeouts) == 1
	assert pd_load(&p.runs) == 0
}

// A per-watch deadline needs no Limits at all: the default config runs no
// sweep and no batch clock, and the park still times out.
fn test_epoll_watch_deadline_fires_with_default_limits() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	sw := time.new_stopwatch()
	fd := pd_send(h.port(), 'GET /never300 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	el := sw.elapsed().milliseconds()
	p := unsafe { pd }
	assert got.starts_with('HTTP/1.1 504 '), 'no 504 after ${el} ms: ${got}'
	assert el >= 280 && el < 1500, 'a 300 ms watch deadline answered after ${el} ms'
	assert pd_load(&p.timeouts) == 1
	// The connection is still served: the timeout answered one request, it did
	// not close anything.
	assert testkit.fd_write_all(fd, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 1000)
	assert testkit.fd_read_until(fd, '\r\n\r\nok', 1000).ends_with('ok')
}

// park_timeout_ms 0, every other timeout set (the issue's measurement): the
// park still has no deadline. No answer, the connection open.
fn test_epoll_park_timeout_zero_keeps_parks_unbounded() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{
		read_timeout_ms:  300
		write_timeout_ms: 300
		idle_timeout_ms:  300
	}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /pnever HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 900)
	p := unsafe { pd }
	assert got == '', 'park_timeout_ms 0 answered a hung park: ${got}'
	assert pd_open_conn(fd), 'park_timeout_ms 0 closed a hung park'
	assert pd_load(&p.timeouts) == 0
}

// A negative per-watch deadline exempts the park from park_timeout_ms.
fn test_epoll_negative_watch_deadline_exempts_park() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{
		park_timeout_ms: 200
	}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /exempt HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 700)
	p := unsafe { pd }
	assert got == '', 'an exempt park was answered: ${got}'
	assert pd_load(&p.timeouts) == 0
	// It still resumes on readiness.
	pd_write(&p.never_w, 'r')
	got2 := testkit.fd_read_until(fd, '\r\n\r\nr', 2000)
	assert got2.ends_with('\r\n\r\nr'), 'the exempt park did not resume: ${got2}'
	assert pd_load(&p.runs) == 1
}

// --- after the deadline ---------------------------------------------------------

// A request-owned fd that becomes ready after its park timed out: the
// continuation does not run again (it ran once, timed out), the late
// readiness does not spin the worker, and the connection keeps serving.
fn test_epoll_late_readiness_wakes_nothing() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /never300 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	assert got.starts_with('HTTP/1.1 504 ')
	p := unsafe { pd }
	pd_write(&p.never_w, 'L') // the late "reply": the pipe stays readable
	cpu0 := C.clock()
	time.sleep(300 * time.millisecond)
	cpu_ms := (C.clock() - cpu0) / 1000
	assert pd_load(&p.runs) == 0, 'the continuation ran again on the late readiness'
	assert pd_load(&p.timeouts) == 1
	assert cpu_ms < 150, 'the worker spun on the late readiness: ${cpu_ms} ms of CPU in 300 ms'
	assert testkit.fd_read_until(fd, '\r\n\r\n', 200) == '', 'a second response for one request'
	assert testkit.fd_write_all(fd, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 1000)
	assert testkit.fd_read_until(fd, '\r\n\r\nok', 1000).ends_with('ok')
	// Nobody consumed the late byte.
	mut b := [1]u8{}
	assert C.read(pd_load(&p.never_r), &b[0], 1) == 1 && b[0] == `L`
}

// A persistent (pooled) fd: the request times out with the reply still due.
// When it arrives, the tombstone run consumes it (not the client: no second
// response), and the next request parked on the same fd gets its own reply.
fn test_epoll_persistent_late_reply_is_drained_in_order() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /pq200 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	assert got.starts_with('HTTP/1.1 504 '), 'no 504: ${got}'
	p := unsafe { pd }
	assert pd_load(&p.timeouts) == 1
	pd_write(&p.db1, 'X') // the late reply
	assert pd_until(&p.drained, 1) == 1, 'the late reply was not drained'
	assert testkit.fd_read_until(fd, '\r\n\r\n', 200) == '', 'the drain answered the client a second time'
	// The same client parks on the same fd again: it must get Y, not X.
	assert testkit.fd_write_all(fd, 'GET /pq5000 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 1000)
	time.sleep(50 * time.millisecond)
	pd_write(&p.db1, 'Y')
	got2 := testkit.fd_read_until(fd, '\r\n\r\nY', 2000)
	assert got2.ends_with('\r\n\r\nY'), 'the next request got the stale reply: ${got2}'
	assert pd_load(&p.drained) == 2
	assert pd_load(&p.timeouts) == 1
}

// A background watch armed from a tombstone run (pg_async cancels from a
// continuation; a tombstone run is one) is a watch of its own: it is not
// taken for the tombstone's re-arm, and its continuation runs.
fn test_epoll_background_watch_from_a_tombstone_run() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /pqbg200 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	assert got.starts_with('HTTP/1.1 504 '), 'no 504: ${got}'
	p := unsafe { pd }
	pd_write(&p.db1, 'X') // the late reply: the tombstone run arms the background watch
	assert pd_until(&p.drained, 1) == 1, 'the late reply was not drained'
	pd_write(&p.bg_w, 'b')
	assert pd_until(&p.bg_runs, 1) == 1, 'the background watch armed by the tombstone run never ran'
}

// A pipelined queue on one persistent fd: A parks first (5 s), B behind it
// with 200 ms. B times out while A heads the queue: B's slot stays as a
// tombstone, so when the "DB" answers A then B, A gets A, B's result is
// consumed and dropped, and a later request C gets C.
fn test_epoll_pipelined_slot_times_out_behind_the_head() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	a := pd_send(h.port(), 'GET /pq5000 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(a)
	}
	time.sleep(50 * time.millisecond) // A parks first: it heads the queue
	b := pd_send(h.port(), 'GET /pq200 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(b)
	}
	got_b := testkit.fd_read_until(b, '\r\n\r\n', 3000)
	assert got_b.starts_with('HTTP/1.1 504 '), 'B did not time out: ${got_b}'
	p := unsafe { pd }
	assert pd_load(&p.timeouts) == 1
	pd_write(&p.db1, 'AB')
	got_a := testkit.fd_read_until(a, '\r\n\r\nA', 2000)
	assert got_a.ends_with('\r\n\r\nA'), 'A did not get its own result: ${got_a}'
	assert pd_until(&p.drained, 2) == 2, 'B result was not drained'
	assert testkit.fd_read_until(b, '\r\n\r\n', 200) == '', 'B was answered twice'
	c := pd_send(h.port(), 'GET /pq5000 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(c)
	}
	time.sleep(50 * time.millisecond)
	pd_write(&p.db1, 'C')
	got_c := testkit.fd_read_until(c, '\r\n\r\nC', 2000)
	assert got_c.ends_with('\r\n\r\nC'), 'C did not get its own result: ${got_c}'
	assert pd_load(&p.timeouts) == 1
}

// A continuation that re-arms on timeout keeps waiting, with a new deadline:
// two timeouts of 150 ms, then the 504.
fn test_epoll_rearm_on_timeout_keeps_waiting() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	sw := time.new_stopwatch()
	fd := pd_send(h.port(), 'GET /keep HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	el := sw.elapsed().milliseconds()
	p := unsafe { pd }
	assert got.starts_with('HTTP/1.1 504 '), 'no 504: ${got}'
	assert pd_load(&p.timeouts) == 2
	assert el >= 280 && el < 1500, 'two 150 ms deadlines answered after ${el} ms'
}

// A taken-over connection parked with a deadline: the timeout continuation's
// bytes go out and the protocol carries on. Takeover is inert under tcc
// (#173): gcc/clang only.
fn test_epoll_takeover_park_deadline() ! {
	$if tinyc {
		eprintln('[test] takeover is inert under tcc; skipping')
		return
	}
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /lines HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	assert testkit.fd_read_until(fd, '\r\n\r\n', 2000).starts_with('HTTP/1.1 101 ')
	assert testkit.fd_write_all(fd, 'wait\n'.bytes(), 1000)
	assert testkit.fd_read_until(fd, 'timeout\n', 3000).ends_with('timeout\n')
	assert testkit.fd_write_all(fd, 'hi\n'.bytes(), 1000)
	assert testkit.fd_read_until(fd, 'echo:hi\n', 2000).ends_with('echo:hi\n')
	p := unsafe { pd }
	assert pd_load(&p.timeouts) == 1
}

// watch_fd_background: a handler arms a clientless watch and answers at once;
// the background continuation runs when its fd is ready.
fn test_epoll_background_watch_from_a_handler() ! {
	pd_open()
	mut h := vtest.start(pd_config(.epoll, server.Limits{}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /bg HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n1', 2000)
	assert got.ends_with('\r\n\r\n1'), 'the background watch was not armed: ${got}'
	p := unsafe { pd }
	pd_write(&p.bg_w, 'b')
	assert pd_until(&p.bg_runs, 1) == 1
	assert testkit.fd_write_all(fd, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), 1000)
	assert testkit.fd_read_until(fd, '\r\n\r\nok', 1000).ends_with('ok')
}

// --- io_uring -------------------------------------------------------------------
// Deadlines are not enforced there: a deadline park is a plain park (it
// resumes on readiness), and watch_fd_background arms nothing. Self-skipping
// where io_uring_setup is blocked or VANILLA_NO_IOURING is set.

fn test_iouring_deadline_is_a_plain_watch() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	pd_open()
	mut h := vtest.start(pd_config(.io_uring, server.Limits{
		park_timeout_ms: 100
	}))!
	defer {
		h.stop()
		pd_close()
	}
	fd := pd_send(h.port(), 'GET /never300 HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	assert testkit.fd_read_until(fd, '\r\n\r\n', 600) == ''
	p := unsafe { pd }
	pd_write(&p.never_w, 'u')
	got := testkit.fd_read_until(fd, '\r\n\r\nu', 2000)
	assert got.ends_with('\r\n\r\nu'), 'io_uring: the park did not resume: ${got}'
	assert pd_load(&p.timeouts) == 0
	fd2 := pd_send(h.port(), 'GET /bg HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd2)
	}
	got2 := testkit.fd_read_until(fd2, '\r\n\r\n0', 2000)
	assert got2.ends_with('\r\n\r\n0'), 'io_uring armed a background watch: ${got2}'
}
