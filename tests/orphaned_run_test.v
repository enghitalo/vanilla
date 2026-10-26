// vtest build: linux
// A continuation can tell that it runs as a tombstone (vanilla#349). When a
// client leaves while its request is parked on a caller-owned fd
// (watch_fd_persistent*), or the park times out first, the epoll runtime
// keeps the watch as a tombstone: when the reply arrives, the continuation
// runs once more, against a discarded response buffer, to consume it in
// order. That run used to get the default wake reason, .ready: it looked
// exactly like a live run, so a multi-step continuation (a transaction's
// next statement, its COMMIT) could not stop early. It now runs with
// event_loop.orphaned() true (reason .orphaned).
//
// The checks, on one worker (every connection and the pooled "DB" share its
// loop), over a unix socket (a close there reaches the server inside the
// close(2) call, so a later round trip orders it):
//   * the issue's repro: the run of a client that stays sees .ready, the run
//     of a client that left sees .orphaned;
//   * a timed-out watch_fd_persistent_deadline park: the timeout run sees
//     .timeout, the run that drains its late reply sees .orphaned; also when
//     the timeout run moved the request to another fd, where it lives on and
//     its run is a live one;
//   * a live run behind an orphaned one, in the same pass over a pipelined
//     queue, sees .ready;
//   * an orphaned run that steps to another persistent fd (#231, #257), then
//     re-arms that one: each later run is orphaned too;
//   * a park the handler rejects (.close after the watch): the runtime keeps
//     a tombstone, whose run is orphaned; on epoll and on io_uring, where a
//     client that leaves while parked is not noticed (that run is a live one)
//     and this is how a tombstone comes about.
import os
import server
import core
import sync.stdatomic
import time
import transport
import testkit
import vtest

#include <sys/socket.h>
#include <unistd.h>
#include "@VMODROOT/core/libc_shim.h"

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.vanilla_read(fd int, buf voidptr, count u64) int
fn C.vanilla_write(fd int, buf voidptr, count u64) int
fn C.close(fd int) int

const or_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'

const or_ok_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n'

const or_504 = 'HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

const or_get = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'

// or_step in a watch_payload: once its reply is read, the run steps to the
// second pooled connection (up0) instead of answering.
const or_step = u64(1)

// or_move in a watch_payload: on timeout, the run moves the request to the
// second pooled connection (it waits there) instead of answering 504.
const or_move = u64(2)

// OrState holds the pooled fds the requests park on and what each
// continuation run saw. The handlers run on the worker thread, the checks on
// the test thread: every field is read and written atomically. -1 = unset.
struct OrState {
mut:
	db0   i64 = -1 // the pooled "DB" connection: the end requests park on
	db1   i64 = -1 // the "DB" itself: one byte per reply
	up0   i64 = -1 // a second pooled connection: the end a step parks on
	up1   i64 = -1 // its peer
	parks i64 // requests the handler parked
	runs  i64 // continuation runs, whatever woke them
	// What run k (1-based) saw: its reason, as int(core.WakeReason) + 1 (0 =
	// no such run yet), and whether timed_out() was true.
	reason [8]i64
	timed  [8]i64
}

const ors = &OrState{}

fn or_load(p &i64) i64 {
	return stdatomic.load_i64(p)
}

// or_open makes the two pooled connections (socketpairs) and clears the
// record.
fn or_open() {
	mut s := unsafe { ors }
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) == 0
	stdatomic.store_i64(&s.db0, i64(sv[0]))
	stdatomic.store_i64(&s.db1, i64(sv[1]))
	mut up := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &up[0]) == 0
	stdatomic.store_i64(&s.up0, i64(up[0]))
	stdatomic.store_i64(&s.up1, i64(up[1]))
	stdatomic.store_i64(&s.parks, 0)
	stdatomic.store_i64(&s.runs, 0)
	for i in 0 .. s.reason.len {
		stdatomic.store_i64(&s.reason[i], 0)
		stdatomic.store_i64(&s.timed[i], 0)
	}
}

// or_close closes them, once the server that parked on them is stopped.
fn or_close() {
	mut s := unsafe { ors }
	for p in [&s.db0, &s.db1, &s.up0, &s.up1] {
		fd := stdatomic.load_i64(p)
		if fd >= 0 {
			stdatomic.store_i64(p, -1)
			C.close(int(fd))
		}
	}
}

// or_record notes what the running continuation saw, as the next run. Only
// the one worker writes, and `runs` goes last: a check that sees run k
// counted sees what run k saw.
fn or_record(reason core.WakeReason, timed bool) {
	mut s := unsafe { ors }
	k := int(or_load(&s.runs)) + 1
	if k <= s.reason.len {
		stdatomic.store_i64(&s.timed[k - 1], if timed { 1 } else { 0 })
		stdatomic.store_i64(&s.reason[k - 1], i64(int(reason)) + 1)
	}
	stdatomic.store_i64(&s.runs, k)
}

// or_saw is run k's reason by name, for the asserts: 'ready', 'orphaned', ...
fn or_saw(k int) string {
	v := or_load(unsafe { &ors.reason[k - 1] })
	if v == 0 {
		return 'no run ${k}'
	}
	reason := unsafe { core.WakeReason(int(v - 1)) }
	return reason.str()
}

fn or_timed(k int) bool {
	return or_load(unsafe { &ors.timed[k - 1] }) == 1
}

fn or_has_prefix(req []u8, prefix string) bool {
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

fn or_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut s := unsafe { ors }
	db := int(or_load(&s.db0))
	if or_has_prefix(req, 'GET /park ') {
		stdatomic.add_i64(&s.parks, 1)
		event_loop.watch_fd_persistent(db, .readable, or_reply, unsafe { nil })
		return .suspend
	}
	if or_has_prefix(req, 'GET /deadline ') {
		stdatomic.add_i64(&s.parks, 1)
		event_loop.watch_fd_persistent_deadline(db, .readable, or_reply, unsafe { nil },
			150)
		return .suspend
	}
	if or_has_prefix(req, 'GET /move ') {
		stdatomic.add_i64(&s.parks, 1)
		event_loop.watch_fd_persistent_deadline(db, .readable, or_reply, voidptr(or_move),
			150)
		return .suspend
	}
	if or_has_prefix(req, 'GET /step ') {
		stdatomic.add_i64(&s.parks, 1)
		event_loop.watch_fd_persistent(db, .readable, or_reply, voidptr(or_step))
		return .suspend
	}
	if or_has_prefix(req, 'GET /reject ') {
		// Parks, then rejects its own park (.close after the watch, which the
		// contract forbids): the runtime closes the connection and keeps the
		// watch as a tombstone, whose run consumes the reply still due.
		stdatomic.add_i64(&s.parks, 1)
		event_loop.watch_fd_persistent(db, .readable, or_reply, unsafe { nil })
		return .close
	}
	core.append_str(mut out, or_ok)
	return .done
}

// or_reply is the pooled "DB" continuation: one byte is one reply. It notes
// what its run saw, consumes the reply and answers 200 with the byte (into a
// discarded buffer when the run is orphaned). On timeout it answers 504, or
// with or_move waits on the second pooled connection instead, and leaves the
// reply alone: the tombstone's run consumes it. With or_step it steps to the
// second pooled connection once its reply is read.
fn or_reply(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	or_record(event_loop.reason(), event_loop.timed_out())
	if event_loop.timed_out() {
		if u64(watch_payload) == or_move {
			s := unsafe { ors }
			event_loop.watch_fd_persistent(int(or_load(&s.up0)), .readable, or_second,
				voidptr(u64(1)))
			return .suspend
		}
		core.append_str(mut out, or_504)
		return .done
	}
	mut b := [1]u8{}
	if C.vanilla_read(ready_fd, &b[0], 1) != 1 {
		core.append_str(mut out, 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
		return .done
	}
	if u64(watch_payload) == or_step {
		s := unsafe { ors }
		event_loop.watch_fd_persistent(int(or_load(&s.up0)), .readable, or_second, unsafe { nil })
		return .suspend
	}
	core.append_str(mut out, or_ok_head)
	out << b[0]
	return .done
}

// or_second is the continuation on the second pooled connection. With a nil
// payload (a step) its first reply re-arms that fd (a two-step exchange
// there), and its second one ends the request; with any other, the first
// reply does.
fn or_second(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	or_record(event_loop.reason(), event_loop.timed_out())
	mut b := [1]u8{}
	C.vanilla_read(ready_fd, &b[0], 1)
	if watch_payload == unsafe { nil } {
		event_loop.watch_fd_persistent(ready_fd, .readable, or_second, voidptr(u64(1)))
		return .suspend
	}
	core.append_str(mut out, or_ok_head)
	out << b[0]
	return .done
}

fn or_uds(tag string) string {
	return os.join_path(os.temp_dir(), 'vanilla_or_${tag}_${os.getpid()}.sock')
}

fn or_config(backend server.IOBackend, path string) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing:  backend
		handler:          or_handler
		workers:          1
		unix_socket_path: path
	}
}

fn or_send(path string, req string) !int {
	fd := transport.dial_unix(path)!
	if !testkit.fd_write_all(fd, req.bytes(), 3000) {
		transport.close_fd(fd)
		return error('could not write the request')
	}
	return fd
}

// or_round_trip asks fd's connection for `GET /` and waits for its answer.
// Every event that reached the worker before the request, such as a client
// closing, has been handled when it returns.
fn or_round_trip(fd int) bool {
	if !testkit.fd_write_all(fd, or_get.bytes(), 3000) {
		return false
	}
	return testkit.fd_read_until(fd, '\r\n\r\nok', 3000).ends_with('\r\n\r\nok')
}

// or_until waits, for at most 3 s, until *counter reaches want; the last value.
fn or_until(counter &i64, want i64) i64 {
	for _ in 0 .. 3000 {
		if or_load(counter) >= want {
			break
		}
		time.sleep(time.millisecond)
	}
	return or_load(counter)
}

fn or_write(p &i64, s string) {
	C.vanilla_write(int(or_load(p)), s.str, u64(s.len))
}

// --- the issue's repro ----------------------------------------------------------

// A request parked on a pooled fd whose client stays: its run is a live one,
// .ready. The same request from a client that leaves first: the watch is a
// tombstone, and its run is orphaned. The two used to look the same.
fn test_epoll_run_of_a_client_that_left_is_orphaned() ! {
	path := or_uds('repro')
	or_open()
	mut h := vtest.start(or_config(.epoll, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	barrier := or_send(path, or_get)!
	defer {
		transport.close_fd(barrier)
	}
	assert testkit.fd_read_until(barrier, '\r\n\r\nok', 3000).ends_with('ok'), 'the barrier was not served'
	// A client that stays.
	live := or_send(path, 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(live)
	}
	assert or_until(&s.parks, 1) == 1, 'the first request did not park'
	or_write(&s.db1, 'L')
	got := testkit.fd_read_until(live, '\r\n\r\nL', 3000)
	assert got.ends_with('\r\n\r\nL'), 'the live run did not answer: ${got}'
	assert or_saw(1) == 'ready', 'the live run saw ${or_saw(1)}'
	assert !or_timed(1)
	// A client that leaves: once the worker has seen it go, the reply arrives.
	gone := or_send(path, 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert or_until(&s.parks, 2) == 2, 'the second request did not park'
	transport.close_fd(gone)
	assert or_round_trip(barrier), 'the barrier was not served after the hangup'
	or_write(&s.db1, 'G')
	assert or_until(&s.runs, 2) == 2, "the tombstone's run did not run"
	assert or_saw(2) == 'orphaned', "the run of a client that left saw ${or_saw(2)}: it can't tell it is a tombstone"
	assert !or_timed(2)
	// The worker still serves; once it has, the orphaned run has returned,
	// and it consumed the reply rather than leave it for the next request.
	assert or_round_trip(barrier), 'the barrier was not served after the orphaned run'
	mut b := [1]u8{}
	assert C.vanilla_read(int(or_load(&s.db0)), &b[0], 1) < 0, 'the reply was left on the pooled fd'
	assert or_load(&s.runs) == 2
}

// --- after a deadline -----------------------------------------------------------

// A watch_fd_persistent_deadline park times out: the run on the deadline
// sees .timeout and answers 504. The reply still due arrives later, and the
// run that drains it is orphaned: the request was already answered, and its
// client, still connected, gets nothing more.
fn test_epoll_drain_after_a_timed_out_park_is_orphaned() ! {
	path := or_uds('deadline')
	or_open()
	mut h := vtest.start(or_config(.epoll, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	fd := or_send(path, 'GET /deadline HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000)
	assert got.starts_with('HTTP/1.1 504 '), 'the park did not time out: ${got}'
	assert or_load(&s.runs) == 1
	assert or_saw(1) == 'timeout', 'the deadline run saw ${or_saw(1)}'
	assert or_timed(1)
	or_write(&s.db1, 'D') // the late reply
	assert or_until(&s.runs, 2) == 2, 'the late reply was not drained'
	assert or_saw(2) == 'orphaned', 'the run that drains the late reply saw ${or_saw(2)}'
	assert !or_timed(2)
	assert testkit.fd_read_until(fd, '\r\n\r\n', 200) == '', 'the drain answered the client a second time'
	assert or_round_trip(fd), 'the client was not served after the drain'
	mut b := [1]u8{}
	assert C.vanilla_read(int(or_load(&s.db0)), &b[0], 1) < 0, 'the late reply was left on the pooled fd'
}

// A timeout run that moves the request to another fd (it waits on the second
// pooled connection instead of answering): the reply still due on the first
// one goes to a tombstone, whose run is orphaned although the request lives
// on there. The run on the second connection is a live one, and the client
// gets its answer, and only that one.
fn test_epoll_drain_after_a_timeout_run_moved_on_is_orphaned() ! {
	path := or_uds('move')
	or_open()
	mut h := vtest.start(or_config(.epoll, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	fd := or_send(path, 'GET /move HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(fd)
	}
	assert or_until(&s.runs, 1) == 1, 'the park did not time out'
	assert or_saw(1) == 'timeout', 'the deadline run saw ${or_saw(1)}'
	or_write(&s.db1, 'D') // the late reply, on the fd the request left
	assert or_until(&s.runs, 2) == 2, 'the late reply was not drained'
	assert or_saw(2) == 'orphaned', 'the drain of the fd the request left saw ${or_saw(2)}'
	or_write(&s.up1, 'U') // the reply the request waits for now
	got := testkit.fd_read_until(fd, '\r\n\r\nU', 3000)
	assert got == or_ok_head + 'U', 'the request did not get its own answer, alone: ${got}'
	assert or_load(&s.runs) == 3
	assert or_saw(3) == 'ready', 'the run on the fd the request moved to saw ${or_saw(3)}'
}

// --- a step away (#231, #257) ---------------------------------------------------

// An orphaned run that steps to another persistent fd (a retry on a fresh
// connection) leaves a tombstone there; that one's runs are orphaned too,
// also after a re-arm of that fd (a two-step exchange).
fn test_epoll_orphaned_run_that_steps_stays_orphaned() ! {
	path := or_uds('step')
	or_open()
	mut h := vtest.start(or_config(.epoll, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	barrier := or_send(path, or_get)!
	defer {
		transport.close_fd(barrier)
	}
	assert testkit.fd_read_until(barrier, '\r\n\r\nok', 3000).ends_with('ok'), 'the barrier was not served'
	gone := or_send(path, 'GET /step HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert or_until(&s.parks, 1) == 1, 'the request did not park'
	transport.close_fd(gone)
	assert or_round_trip(barrier), 'the barrier was not served after the hangup'
	or_write(&s.db1, 'S') // the tombstone's run reads it and steps to up0
	assert or_until(&s.runs, 1) == 1, "the tombstone's run did not run"
	or_write(&s.up1, '1') // the step's first run: it re-arms up0
	assert or_until(&s.runs, 2) == 2, "the step's continuation did not run"
	or_write(&s.up1, '2') // its second run ends the request
	assert or_until(&s.runs, 3) == 3, "the step's re-arm did not run"
	for k in 1 .. 4 {
		assert or_saw(k) == 'orphaned', 'run ${k} of a request whose client left saw ${or_saw(k)}'
		assert !or_timed(k)
	}
	assert or_round_trip(barrier), 'the barrier was not served after the step'
}

// --- a pipelined queue -----------------------------------------------------------

// A parks on the pooled fd first, B behind it, then A leaves. One readiness
// edge brings both replies: A's tombstone runs orphaned, and B's run, after
// it in the same pass over the queue, is a live one that gets B's reply.
fn test_epoll_live_run_behind_an_orphaned_one_is_ready() ! {
	path := or_uds('queue')
	or_open()
	mut h := vtest.start(or_config(.epoll, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	barrier := or_send(path, or_get)!
	defer {
		transport.close_fd(barrier)
	}
	assert testkit.fd_read_until(barrier, '\r\n\r\nok', 3000).ends_with('ok'), 'the barrier was not served'
	a := or_send(path, 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert or_until(&s.parks, 1) == 1, 'A did not park'
	b := or_send(path, 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		transport.close_fd(b)
	}
	assert or_until(&s.parks, 2) == 2, 'B did not park'
	transport.close_fd(a)
	assert or_round_trip(barrier), 'the barrier was not served after the hangup'
	or_write(&s.db1, 'AB') // both replies, in order
	got := testkit.fd_read_until(b, '\r\n\r\nB', 3000)
	assert got == or_ok_head + 'B', 'B did not get its own reply: ${got}'
	assert or_load(&s.runs) == 2
	assert or_saw(1) == 'orphaned', "A's tombstone saw ${or_saw(1)}"
	assert or_saw(2) == 'ready', "B's run, behind A's tombstone, saw ${or_saw(2)}"
}

// --- a rejected park, epoll and io_uring -----------------------------------------

// check_rejected_park: the handler parks on a pooled fd and returns .close.
// The connection is closed unanswered, and the watch stays as a tombstone
// whose run, when the reply arrives, is orphaned.
fn check_rejected_park(backend server.IOBackend) ! {
	path := or_uds('reject_${backend}')
	or_open()
	mut h := vtest.start(or_config(backend, path))!
	defer {
		h.stop()
		or_close()
	}
	s := unsafe { ors }
	fd := or_send(path, 'GET /reject HTTP/1.1\r\nHost: x\r\n\r\n')!
	got := testkit.fd_read_until(fd, '\r\n\r\n', 3000) // until the server closes it
	transport.close_fd(fd)
	assert got == '', '${backend}: the rejected park was answered: ${got}'
	assert or_load(&s.parks) == 1, '${backend}: the request did not park'
	or_write(&s.db1, 'R')
	assert or_until(&s.runs, 1) == 1, "${backend}: the rejected park's tombstone did not run"
	assert or_saw(1) == 'orphaned', "${backend}: the rejected park's tombstone saw ${or_saw(1)}"
	assert !or_timed(1)
}

fn test_epoll_run_of_a_rejected_park_is_orphaned() ! {
	check_rejected_park(.epoll)!
}

// Self-skipping where io_uring_setup is blocked or VANILLA_NO_IOURING is set.
fn test_iouring_run_of_a_rejected_park_is_orphaned() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_rejected_park(.io_uring)!
}
