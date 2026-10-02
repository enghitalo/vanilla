// vtest build: linux
// Server.shutdown(grace_ms) drains requests PARKED on a watch (.suspend) — a
// DB query, a timer, an upstream call — not only the ones running at that
// instant (issue #187). Before the fix, epoll held the in-flight count only
// while a handler or continuation executed: shutdown(3000) with a request
// parked on an 800 ms timer returned after 0 ms, and in the documented
// `shutdown(); exit(0)` flow that response was lost. Now a parked connection
// holds one count from its park until it resumes or closes.
//
// The checks, per backend (epoll; io_uring where io_uring_setup is allowed):
//   * a handler still running is waited for (io_uring counted only posted
//     sends, so shutdown() did not wait for it either);
//   * shutdown() returns only once the parked response was written;
//   * grace_ms still bounds the wait;
//   * a parked client that left releases its count (epoll at once; io_uring,
//     which only notices a parked client's hangup when it resumes, then);
//   * a continuation that re-parks (a multi-step chain) is waited for to the
//     end and counted once;
//   * clients queued on one shared persistent fd (pg_async pipelining), one of
//     them gone (a tombstone), are all waited for and leave nothing counted.
//
// Lifecycle owned by the test (VTEST.md hybrid): requests go out on raw
// fds, the test calls server_ref().shutdown() itself, and the stopwatch
// MEASURES how long it blocked. The one barrier before it is "the requests
// are parked" (sd_until_parked): the handlers count their parks, then the
// server's in-flight sum must reach that number — asserted too, after the
// shutdown: a parked request must count as in flight.
import server
import core
import sync.stdatomic
import time
import transport
import testkit
import vtest

#include <sys/timerfd.h>
#include <sys/socket.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// /delay parks on one 800 ms timer (the issue's repro, examples/async_timer).
const sd_delay_ms = 800
const sd_delay_req = 'GET /delay HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const sd_delay_prefix = 'GET /delay '.bytes()
const sd_delayed = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\ndelayed'.bytes()

// /long parks on a 5 s timer: longer than every grace below it is compared to.
const sd_long_ms = 5000
const sd_long_req = 'GET /long HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const sd_long_prefix = 'GET /long '.bytes()

// /chain parks sd_chain_steps times in a row, sd_chain_ms each: every
// continuation but the last re-arms a fresh timer and suspends again.
const sd_chain_steps = 4
const sd_chain_ms = 150
const sd_chain_req = 'GET /chain HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const sd_chain_prefix = 'GET /chain '.bytes()
const sd_chained = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\nchained'.bytes()

// /pq parks on the shared mock upstream (sd_up.up0) with watch_fd_persistent,
// like a pg_async query on a pooled connection: a second client parking on it
// promotes the watch to a FIFO queue. Each result is one byte the "DB" writes
// into up1, answered as a 1-byte body.
const sd_pq_req = 'GET /pq HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const sd_pq_prefix = 'GET /pq '.bytes()
const sd_pq_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n'.bytes()

// /busy runs for 800 ms on the worker before it answers (a synchronous slow
// handler, e.g. an inline password hash): it is in flight the whole time.
const sd_busy_ms = 800
const sd_busy_req = 'GET /busy HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const sd_busy_prefix = 'GET /busy '.bytes()
const sd_busy = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nbusy'.bytes()

const sd_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// SdUpstream holds the mock upstream's two socketpair ends: the handlers run
// on the worker thread, the check on the test thread. -1 = unset.
struct SdUpstream {
mut:
	up0 i64 = -1 // the end every /pq parks on (server side)
	up1 i64 = -1 // the end the "DB" writes results into
}

const sd_up = &SdUpstream{}

// sd_parks counts the requests sd_handler parked, and sd_runs the /busy
// requests it started (each check resets both).
const sd_parks = &core.Counter{}
const sd_runs = &core.Counter{}

fn sd_has_prefix(req []u8, prefix []u8) bool {
	if req.len < prefix.len {
		return false
	}
	for i, b in prefix {
		if req[i] != b {
			return false
		}
	}
	return true
}

// sd_timer is a one-shot timerfd expiring in ms (the read after readiness
// never blocks).
fn sd_timer(ms int) int {
	tfd := C.timerfd_create(1, 0) // 1 = CLOCK_MONOTONIC
	if tfd < 0 {
		return tfd
	}
	mut spec := [4]i64{}
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	return tfd
}

fn sd_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if sd_has_prefix(req, sd_delay_prefix) {
		event_loop.watch_fd(sd_timer(sd_delay_ms), .readable, sd_timer_done, unsafe { nil })
		return sd_parked()
	}
	if sd_has_prefix(req, sd_long_prefix) {
		event_loop.watch_fd(sd_timer(sd_long_ms), .readable, sd_timer_done, unsafe { nil })
		return sd_parked()
	}
	if sd_has_prefix(req, sd_chain_prefix) {
		event_loop.watch_fd(sd_timer(sd_chain_ms), .readable, sd_chain_step, voidptr(usize(sd_chain_steps - 1)))
		return sd_parked()
	}
	if sd_has_prefix(req, sd_pq_prefix) {
		u := unsafe { sd_up }
		event_loop.watch_fd_persistent(int(stdatomic.load_i64(&u.up0)), .readable, sd_pq_done,
			unsafe { nil })
		return sd_parked()
	}
	if sd_has_prefix(req, sd_busy_prefix) {
		r := unsafe { sd_runs }
		stdatomic.add_i64(&r.n, 1)
		time.sleep(sd_busy_ms * time.millisecond)
		out << sd_busy
		return .done
	}
	out << sd_ok
	return .done
}

fn sd_parked() core.Step {
	p := unsafe { sd_parks }
	stdatomic.add_i64(&p.n, 1)
	return .suspend
}

fn sd_timer_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	out << sd_delayed
	return .done
}

// sd_chain_step: watch_payload is the number of parks still to go.
fn sd_chain_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	left := int(usize(watch_payload))
	if left > 0 {
		event_loop.watch_fd(sd_timer(sd_chain_ms), .readable, sd_chain_step, voidptr(usize(left - 1)))
		return .suspend
	}
	out << sd_chained
	return .done
}

// sd_pq_done takes the next result off the mock upstream, in order.
fn sd_pq_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut b := [1]u8{}
	if C.read(ready_fd, &b[0], 1) != 1 {
		event_loop.watch_fd_persistent(ready_fd, .readable, sd_pq_done, watch_payload)
		return .suspend
	}
	out << sd_pq_head
	out << b[0]
	return .done
}

fn sd_config(backend server.IOBackend) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing: backend
		handler:         sd_handler
		workers:         1 // every connection on one worker: /pq clients share its queue
	}
}

// sd_send dials the server and writes req on a raw fd.
fn sd_send(port int, req []u8) !int {
	fd := transport.dial_tcp('127.0.0.1', port)!
	if !testkit.fd_write_all(fd, req, 3000) {
		transport.close_fd(fd)
		return error('could not write the request')
	}
	return fd
}

fn sd_inflight(mut h vtest.Harness) i64 {
	mut sum := i64(0)
	for c in h.server_ref().inflight {
		sum += stdatomic.load_i64(&c.n)
	}
	return sum
}

// sd_until_inflight waits, for at most 3 s, until the server's in-flight sum
// is `want`, and returns the last value read.
fn sd_until_inflight(mut h vtest.Harness, want i64) i64 {
	for _ in 0 .. 3000 {
		if sd_inflight(mut h) == want {
			return want
		}
		time.sleep(time.millisecond)
	}
	return sd_inflight(mut h)
}

// sd_until_parked is the barrier "`parks` requests are parked now": the
// handlers have returned .suspend that many times (at most 3 s), and then the
// server's in-flight sum reaches it (at most 3 s more; it never does if a
// parked request does not count). Returns that sum, for the caller to assert.
fn sd_until_parked(mut h vtest.Harness, parks i64) i64 {
	p := unsafe { sd_parks }
	for _ in 0 .. 3000 {
		if stdatomic.load_i64(&p.n) >= parks {
			break
		}
		time.sleep(time.millisecond)
	}
	return sd_until_inflight(mut h, parks)
}

fn sd_reset_parks() {
	p := unsafe { sd_parks }
	stdatomic.store_i64(&p.n, 0)
	r := unsafe { sd_runs }
	stdatomic.store_i64(&r.n, 0)
}

// sd_shutdown calls shutdown(grace_ms) and returns how long it blocked, in ms.
fn sd_shutdown(mut h vtest.Harness, grace_ms int) i64 {
	sw := time.new_stopwatch()
	h.server_ref().shutdown(grace_ms)
	return sw.elapsed().milliseconds()
}

fn sd_close_upstream() {
	mut u := unsafe { sd_up }
	for p in [&u.up0, &u.up1] {
		fd := stdatomic.load_i64(p)
		if fd >= 0 {
			stdatomic.store_i64(p, -1)
			C.close(int(fd))
		}
	}
}

// check_shutdown_waits_for_parked is the issue's repro as asserts: one
// request parked on an 800 ms timer, then shutdown(5000). It must block until
// the parked response is written (~800 ms), not return at once — and not wait
// out the grace either: the count goes when the response does.
fn check_shutdown_waits_for_parked(backend server.IOBackend) ! {
	sd_reset_parks()
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
	}
	fd := sd_send(h.port(), sd_delay_req)!
	defer {
		transport.close_fd(fd)
	}
	parked := sd_until_parked(mut h, 1)
	waited := sd_shutdown(mut h, 5000)
	got := testkit.fd_read_until(fd, 'delayed', 2000)
	assert waited >= sd_delay_ms - 300, '${backend}: shutdown(5000) returned after ${waited} ms with a request parked on an ${sd_delay_ms} ms timer'
	assert got.contains('delayed'), '${backend}: the parked request was not answered: ${got}'
	assert waited < 4000, '${backend}: shutdown(5000) waited ${waited} ms: the parked request kept its count after it was answered'
	assert parked == 1, '${backend}: a request parked on a watch must count as in flight, the sum was ${parked}'
	left := sd_until_inflight(mut h, 0)
	assert left == 0, '${backend}: ${left} in-flight count(s) leaked after the parked request was answered'
}

// check_shutdown_waits_for_running: the baseline the parked checks build on,
// on every backend — a handler still running when shutdown(5000) is called
// (800 ms of synchronous work) is waited for, and answered.
fn check_shutdown_waits_for_running(backend server.IOBackend) ! {
	sd_reset_parks()
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
	}
	fd := sd_send(h.port(), sd_busy_req)!
	defer {
		transport.close_fd(fd)
	}
	r := unsafe { sd_runs }
	for _ in 0 .. 3000 {
		if stdatomic.load_i64(&r.n) >= 1 {
			break
		}
		time.sleep(time.millisecond)
	}
	waited := sd_shutdown(mut h, 5000)
	got := testkit.fd_read_until(fd, 'busy', 2000)
	assert waited >= sd_busy_ms - 300, '${backend}: shutdown(5000) returned after ${waited} ms while an ${sd_busy_ms} ms handler was running'
	assert got.contains('busy'), '${backend}: the running request was not answered: ${got}'
	assert waited < 4000, '${backend}: shutdown(5000) waited ${waited} ms: the request kept its count after it was answered'
	left := sd_until_inflight(mut h, 0)
	assert left == 0, '${backend}: ${left} in-flight count(s) leaked after the running request was answered'
}

// check_shutdown_grace_bounds_parked: a request parked for 5 s holds
// shutdown(300) for its whole grace, and no longer.
fn check_shutdown_grace_bounds_parked(backend server.IOBackend) ! {
	sd_reset_parks()
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
	}
	fd := sd_send(h.port(), sd_long_req)!
	defer {
		transport.close_fd(fd)
	}
	parked := sd_until_parked(mut h, 1)
	waited := sd_shutdown(mut h, 300)
	assert waited >= 250, '${backend}: shutdown(300) returned after ${waited} ms with a request parked for ${sd_long_ms} ms'
	assert waited < 2500, '${backend}: shutdown(300) blocked ${waited} ms: the grace must bound the wait'
	assert parked == 1, '${backend}: a request parked on a watch must count as in flight, the sum was ${parked}'
}

// check_shutdown_after_parked_client_left: the client of a parked request
// disconnects, then shutdown(5000). Its count must not be held until the
// grace runs out. epoll tears the watch down when the client leaves, so the
// count goes at once (req parks for 5 s, bound_ms is far below it). io_uring
// arms no op on a parked client, so it learns of the hangup only when the
// request resumes (req parks for 800 ms) and the reply finds the peer gone.
fn check_shutdown_after_parked_client_left(backend server.IOBackend, req []u8, bound_ms i64) ! {
	sd_reset_parks()
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
	}
	fd := sd_send(h.port(), req)!
	parked := sd_until_parked(mut h, 1)
	transport.close_fd(fd)
	waited := sd_shutdown(mut h, 5000)
	assert waited < bound_ms, '${backend}: shutdown(5000) blocked ${waited} ms after the parked client left: its count was not released'
	assert parked == 1, '${backend}: a request parked on a watch must count as in flight, the sum was ${parked}'
	left := sd_until_inflight(mut h, 0)
	assert left == 0, '${backend}: ${left} in-flight count(s) leaked by a parked client that left'
}

// check_shutdown_waits_for_reparked_chain: a continuation that re-parks keeps
// the request in flight through every step (shutdown waits for the whole
// chain, not its first step) and is counted once (nothing left afterwards).
fn check_shutdown_waits_for_reparked_chain(backend server.IOBackend) ! {
	sd_reset_parks()
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
	}
	fd := sd_send(h.port(), sd_chain_req)!
	defer {
		transport.close_fd(fd)
	}
	parked := sd_until_parked(mut h, 1)
	waited := sd_shutdown(mut h, 5000)
	got := testkit.fd_read_until(fd, 'chained', 2000)
	chain_ms := sd_chain_steps * sd_chain_ms
	assert waited >= chain_ms / 2, '${backend}: shutdown(5000) returned after ${waited} ms during a ${chain_ms} ms chain of parks'
	assert got.contains('chained'), '${backend}: the chained request was not answered: ${got}'
	assert waited < 4000, '${backend}: shutdown(5000) waited ${waited} ms: the chain was counted more than once'
	assert parked == 1, '${backend}: a request parked on a watch must count as in flight, the sum was ${parked}'
	left := sd_until_inflight(mut h, 0)
	assert left == 0, '${backend}: ${left} in-flight count(s) leaked by a request that re-parked'
}

// check_shutdown_waits_for_pipelined_parks: three clients parked in order on
// one shared persistent fd (a pipelined pg connection: A heads its queue).
// A disconnects: on epoll its slot becomes a tombstone and its count goes at
// once; io_uring keeps it until A's result arrives. The "DB" answers all
// three 300 ms after shutdown(5000) starts: shutdown must wait for B's and
// C's responses (in order: A's result is never handed to them) and leave
// nothing counted.
fn check_shutdown_waits_for_pipelined_parks(backend server.IOBackend, hangup_seen bool) ! {
	sd_reset_parks()
	sd_close_upstream()
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) == 0
	mut u := unsafe { sd_up }
	stdatomic.store_i64(&u.up0, i64(sv[0]))
	stdatomic.store_i64(&u.up1, i64(sv[1]))
	mut h := vtest.start(sd_config(backend))!
	defer {
		h.stop()
		sd_close_upstream()
	}
	// One at a time, so that they queue in this order: A, B, C.
	a := sd_send(h.port(), sd_pq_req)!
	n1 := sd_until_parked(mut h, 1)
	b := sd_send(h.port(), sd_pq_req)!
	defer {
		transport.close_fd(b)
	}
	n2 := sd_until_parked(mut h, 2)
	c := sd_send(h.port(), sd_pq_req)!
	defer {
		transport.close_fd(c)
	}
	n3 := sd_until_parked(mut h, 3)
	transport.close_fd(a)
	want_after_a := if hangup_seen { i64(2) } else { i64(3) }
	n4 := sd_until_inflight(mut h, want_after_a)
	up1 := int(stdatomic.load_i64(&u.up1))
	spawn fn [up1] () {
		time.sleep(300 * time.millisecond) // the query latency
		results := '123'.bytes()
		C.write(up1, &results[0], usize(results.len))
	}()
	waited := sd_shutdown(mut h, 5000)
	got_b := testkit.fd_read_until(b, '\r\n\r\n2', 2000)
	got_c := testkit.fd_read_until(c, '\r\n\r\n3', 2000)
	assert waited >= 150, '${backend}: shutdown(5000) returned after ${waited} ms with two requests queued on a pipelined fd'
	assert got_b.ends_with('\r\n\r\n2'), '${backend}: client B did not get its own result: ${got_b}'
	assert got_c.ends_with('\r\n\r\n3'), '${backend}: client C did not get its own result: ${got_c}'
	assert waited < 4000, '${backend}: shutdown(5000) waited ${waited} ms: a pipelined park kept its count after it was answered'
	assert n1 == 1, '${backend}: client A must count as in flight once parked, the sum was ${n1}'
	assert n2 == 2, '${backend}: client B must count once queued behind A, the sum was ${n2}'
	assert n3 == 3, '${backend}: client C must count once queued behind B, the sum was ${n3}'
	assert n4 == want_after_a, '${backend}: after queued client A left the sum was ${n4}, want ${want_after_a}'
	left := sd_until_inflight(mut h, 0)
	assert left == 0, '${backend}: ${left} in-flight count(s) leaked by the pipelined queue'
}

// --- epoll --------------------------------------------------------------------

fn test_epoll_shutdown_waits_for_running() ! {
	check_shutdown_waits_for_running(.epoll)!
}

fn test_epoll_shutdown_waits_for_parked() ! {
	check_shutdown_waits_for_parked(.epoll)!
}

fn test_epoll_shutdown_grace_bounds_parked() ! {
	check_shutdown_grace_bounds_parked(.epoll)!
}

fn test_epoll_shutdown_after_parked_client_left() ! {
	check_shutdown_after_parked_client_left(.epoll, sd_long_req, 2000)!
}

fn test_epoll_shutdown_waits_for_reparked_chain() ! {
	check_shutdown_waits_for_reparked_chain(.epoll)!
}

fn test_epoll_shutdown_waits_for_pipelined_parks() ! {
	check_shutdown_waits_for_pipelined_parks(.epoll, true)!
}

// --- io_uring -----------------------------------------------------------------
// Self-skipping where io_uring_setup is blocked (sandboxed CI runners) or
// VANILLA_NO_IOURING is set, like every io_uring e2e test.

fn test_iouring_shutdown_waits_for_running() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_waits_for_running(.io_uring)!
}

fn test_iouring_shutdown_waits_for_parked() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_waits_for_parked(.io_uring)!
}

fn test_iouring_shutdown_grace_bounds_parked() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_grace_bounds_parked(.io_uring)!
}

fn test_iouring_shutdown_after_parked_client_left() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_after_parked_client_left(.io_uring, sd_delay_req, 4000)!
}

fn test_iouring_shutdown_waits_for_reparked_chain() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_waits_for_reparked_chain(.io_uring)!
}

fn test_iouring_shutdown_waits_for_pipelined_parks() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	check_shutdown_waits_for_pipelined_parks(.io_uring, false)!
}
