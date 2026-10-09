// vtest build: linux
// Connection-reaping edge cases on the plain epoll worker that
// backend_behaviors_test.v does not cover: what the read/idle deadlines must
// NOT reap (a taken-over connection, also once a frame split across bursts
// completes; a parked request; a request streaming from a watch), a suspended
// request that can never resume (closed, not leaked), and the flows that keep
// a request open across edges (Expect: 100-continue, a streamed > 1 MiB
// upload) while those deadlines are armed. Plus a connect storm whose
// requests arrive with the connection — the accept-time EPOLLOUT birth edge
// must still serve the EPOLLIN half. Also: a pipelined request's own read
// deadline; no 408 inside a pending response, yet a stalled streamed upload
// still gets its 408, also after Expect: 100-continue; streams whose clients
// all vanish at once are released exactly once; an app's fd that a finished
// watch left registered is never adopted as a connection, nor spun on once
// it reads EOF (a pooled fd whose upstream went away), births on or off; and a
// request that parks on its own client's writability leaves the connection
// serving. And the #155 checks, each built as an exact order of events in one
// epoll_wait batch (see "choreographed checks" below): the sweep's 408 to a
// peer that is already gone must not raise SIGPIPE; a pipelined head whose
// client vanished mid-stream keeps its result from the next client; a
// continuation that steps away from an fd leaves no spin and no zombie
// behind; and a stale event for an fd closed earlier in the batch neither
// releases a connection twice nor wakes the new watch on a reused number.
// The checks that need no watch reactor or takeover also run on the poll
// backend (`-d vanilla_poll`), which shares the 408 / fresh-deadline rules.
//
// vtest contract (docs/VTEST.md): the only clocks are the server's Limits. A
// "pause longer than idle" is produced by a WITNESS connection the server
// itself reaps by a deadline at least as long as the idle budget: when
// fire(witness) returns, that much server time has passed while the
// connection under test sat still — no client sleeps, no stopwatch deadlines.
import os
import server
import core
import socket
import sync.stdatomic
import time
import transport
import vtest

$if linux {
	#include <sys/timerfd.h>
	#include <sys/socket.h>
}

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.clock() i64 // this process's CPU time, in CLOCKS_PER_SEC (1e6 on POSIX) units
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int

const et_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const et_delay_req = 'GET /delay HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_delayed = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\ndelayed'.bytes()

// /stream answers a Content-Length body in et_ticks pieces, one per timer tick:
// the connection streams from a watch (flush, re-park) for et_ticks *
// et_tick_ms — several idle budgets — before the response completes.
const et_ticks = 6
const et_tick_ms = 150
const et_stream_req = 'GET /stream HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_stream_head = 'HTTP/1.1 200 OK\r\nContent-Length: 30\r\nConnection: keep-alive\r\n\r\n'.bytes() // 30 = et_ticks * et_tick.len
const et_tick = 'tick\n'.bytes()

const et_upgrade_req = 'GET /up HTTP/1.1\r\nHost: x\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n'.bytes()
const et_switching = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n'.bytes()

// /lines upgrades to a line protocol (et_line_conn): a frame is one line.
const et_lines_req = 'GET /lines HTTP/1.1\r\nHost: x\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n'.bytes()

const et_expect_head = 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()
const et_expect_body = 'hello'.bytes()

const et_upload_body_len = 2 * 1024 * 1024 // > the 1 MiB streaming threshold ⇒ drain path
const et_upload_chunk_len = 64 * 1024
const et_upload_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\nuploaded'.bytes()

// /big answers 7 MiB (under the 8 MiB pending-write cap): more than a peer
// that is not reading can take, so the rest stays parked in write_buf.
const et_big_len = 7 * 1024 * 1024
const et_big_req = 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: ${et_big_len}\r\nConnection: keep-alive\r\n\r\n'.bytes()
const et_big_fill = u8(`a`)

// /sock parks on a socketpair end (.writable), then steps to a timer while
// keeping that end open (and registered: its watch is level-triggered).
const et_sock_req = 'GET /sock HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// /pool parks on a pooled "upstream" (a socketpair end) for its reply, then
// answers and keeps that end open for the next request (a plain watch_fd: the
// examples/mesh and DB-pool pattern). The upstream then goes away.
const et_pool_req = 'GET /pool HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// EtPool is where /pool leaves its pooled end, for the check to inspect: its
// number and its socket's inode (a closed fd's number is soon reused).
struct EtPool {
mut:
	fd    i64 = -1
	inode i64
}

const et_pool = &EtPool{}

// --- choreographed checks (#155) ---------------------------------------------
// Each needs a given order of events inside ONE epoll_wait batch. An
// orchestrator handler produces it: with workers: 1 it runs on the only
// worker, which is busy inside it, so the events it makes ready (closing a
// hand-rolled client, writing a socketpair peer or a request into a client)
// queue in the kernel's FIFO ready list and come back in that order in the
// next batch. The server listens on a unix socket: a send to a closed AF_UNIX
// peer fails at once (EPIPE), where a TCP peer that sent FIN takes one more.
// No connection is opened while that batch runs: accept (another thread)
// could hand it a number the batch frees. A check's helper connections are
// opened, and served once, before its orchestrator.

// EtChoreo is where those checks keep the fds their handlers act on: the
// handlers run on the worker thread, the check on the test thread. -1 = unset.
struct EtChoreo {
mut:
	a        i64 = -1 // hand-rolled client A's own end (an orchestrator closes it)
	b        i64 = -1 // hand-rolled client B's own end (an orchestrator writes a request into it)
	x        i64 = -1 // a watched socketpair end, server side
	peer     i64 = -1 // x's peer: writing it makes x readable
	up0      i64 = -1 // the mock pipelined upstream: the end every /pq parks on
	up1      i64 = -1 // ...and the end its "DB" writes the results into, in order
	pinned   i64 // 1 once /h6new's timer holds x's (freed) number
	spurious i64 // continuations that ran with nothing ready
}

const et_ch = &EtChoreo{}

fn et_ch_reset() {
	mut c := unsafe { et_ch }
	for p in [&c.a, &c.b, &c.x, &c.peer, &c.up0, &c.up1] {
		stdatomic.store_i64(p, -1)
	}
	stdatomic.store_i64(&c.pinned, 0)
	stdatomic.store_i64(&c.spurious, 0)
}

// et_ch_close closes and clears the fd kept in *p, if any. Each fd has one
// closer at a time (its handler on the worker, or the check once the harness
// stopped), so a load then a store is enough.
fn et_ch_close(p &i64) {
	fd := stdatomic.load_i64(p)
	if fd >= 0 {
		stdatomic.store_i64(p, -1)
		C.close(int(fd))
	}
}

// et_ch_write writes b into the fd kept in *p (a peer or a client end).
fn et_ch_write(p &i64, b []u8) {
	fd := stdatomic.load_i64(p)
	if fd >= 0 {
		et_write_all(int(fd), b)
	}
}

fn et_uds(tag string) string {
	return os.join_path(os.temp_dir(), 'vanilla_et_${tag}_${os.getpid()}.sock')
}

// et_dial connects a hand-rolled client to the unix socket at path and writes
// req on it. Blocking: vtest does not own this fd, the check reads it itself.
fn et_dial(path string, req []u8) !int {
	fd := transport.dial_unix(path)!
	socket.set_blocking(fd, true)
	et_write_all(fd, req)
	return fd
}

fn et_write_all(fd int, b []u8) {
	mut off := 0
	for off < b.len {
		n := C.send(fd, unsafe { &b[off] }, usize(b.len - off), C.MSG_NOSIGNAL)
		if n <= 0 {
			return
		}
		off += n
	}
}

// et_read_response reads one Content-Length framed response from a blocking
// hand-rolled client. No timeout (the vtest liveness contract): a server that
// never answers hangs the check, which the CI step timeout bounds.
fn et_read_response(fd int) []u8 {
	mut acc := []u8{}
	mut buf := [4096]u8{}
	for {
		s := acc.bytestr()
		head := s.index('\r\n\r\n') or { -1 }
		if head >= 0 {
			cl := s.all_after('Content-Length: ').all_before('\r\n').int()
			if acc.len >= head + 4 + cl {
				return acc[..head + 4 + cl]
			}
		}
		n := C.recv(fd, &buf[0], usize(buf.len), 0)
		if n <= 0 {
			return acc
		}
		acc << buf[..n]
	}
	return acc
}

const et_zombie = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nzombie'.bytes()
const et_spurious = 'HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\nspurious'.bytes()

// /block408 holds the worker for longer than a 500 ms read budget plus a
// sweep interval, then parks on a socketpair end that is already readable,
// whose continuation closes client A.
const et_block408_req = 'GET /block408 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_block408_prefix = 'GET /block408'.bytes()

// /park parks on a request-owned socketpair end (et_ch.x / et_ch.peer). Two
// orchestrators then order a hangup of client A (parked there) and x's
// readiness: /hupfirst closes A first, /readyfirst makes x readable first.
const et_park_req = 'GET /park HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_park_prefix = 'GET /park'.bytes()
const et_hupfirst_req = 'GET /hupfirst HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_hupfirst_prefix = 'GET /hupfirst'.bytes()
const et_readyfirst_req = 'GET /readyfirst HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_readyfirst_prefix = 'GET /readyfirst'.bytes()

// /h6orch closes client A (parked on x), writes /h6new into client B, then
// makes x readable. /h6new parks on a fresh 300 ms timer that takes x's
// number.
const et_h6orch_req = 'GET /h6orch HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_h6orch_prefix = 'GET /h6orch'.bytes()
const et_h6new_req = 'GET /h6new HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_h6new_prefix = 'GET /h6new'.bytes()

// /pq pipelines on one mock upstream (et_ch.up0, persistent): every request
// parks on it, and the results come back in order, one byte each. A `.`
// streams the head of the parked request's response first. /qorch streams a
// `.` to the head and closes client A (the head) behind it; /qfeed writes
// the results `1` then `2`.
const et_pq_req = 'GET /pq HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_pq_prefix = 'GET /pq'.bytes()
const et_pq_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: keep-alive\r\n\r\n'.bytes()
const et_qorch_req = 'GET /qorch HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_qorch_prefix = 'GET /qorch'.bytes()
const et_qfeed_req = 'GET /qfeed HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_qfeed_prefix = 'GET /qfeed'.bytes()

// /stepw parks on a socketpair end (.writable), then steps to a 500 ms timer
// keeping that end open. /stepr does the same on an end that is readable (a
// complete request waits in it), then checks that nothing read it meanwhile.
const et_stepw_req = 'GET /stepw HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_stepw_prefix = 'GET /stepw'.bytes()
const et_stepr_req = 'GET /stepr HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_stepr_prefix = 'GET /stepr'.bytes()

// /self parks on its own client socket becoming writable (the backpressure
// pattern), then answers.
const et_self_req = 'GET /self HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

// /forever streams one byte per 1 ms timer tick and never ends (an SSE-style
// stream whose client simply goes away).
const et_forever_req = 'GET /forever HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_forever_head = 'HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\nConnection: keep-alive\r\n\r\n'.bytes()

// A connection that never sends: completes only when the server closes it.
const et_silent = vtest.Script{
	rounds:   [
		vtest.Round{
			send: []u8{}
			want: 0
		},
	]
	then_eof: true
}

// A connection that is served once, then goes idle: completes only when the
// server's idle deadline closes it, at least idle_ms after its response.
const et_idle_witness = vtest.Script{
	rounds:   [
		vtest.Round{
			send: et_req
			want: 1
		},
	]
	then_eof: true
}

@[direct_array_access]
fn et_has_prefix(req []u8, prefix []u8) bool {
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

const et_delay_prefix = 'GET /delay'.bytes()
const et_stream_prefix = 'GET /stream'.bytes()
const et_up_prefix = 'GET /up'.bytes()
const et_lines_prefix = 'GET /lines'.bytes()
const et_upload_prefix = 'POST /upload'.bytes()
const et_lost_prefix = 'GET /lost'.bytes()
const et_lost_req = 'GET /lost HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_nowatch_prefix = 'GET /nowatch'.bytes()
const et_ok_nowatch_ok = 'GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /nowatch HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const et_big_prefix = 'GET /big'.bytes()
const et_sock_prefix = 'GET /sock'.bytes()
const et_forever_prefix = 'GET /forever'.bytes()
const et_self_prefix = 'GET /self'.bytes()
const et_pool_prefix = 'GET /pool'.bytes()

// et_timerfd arms a CLOCK_MONOTONIC timerfd that first fires after `ms`, then
// every `interval_ms` (0 = one-shot). itimerspec = {it_interval, it_value}.
fn et_timerfd(ms int, interval_ms int) int {
	tfd := C.timerfd_create(1, 0) // 1 = CLOCK_MONOTONIC
	if tfd < 0 {
		return tfd
	}
	mut spec := [4]i64{}
	spec[0] = i64(interval_ms / 1000)
	spec[1] = i64(interval_ms % 1000) * 1_000_000
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	return tfd
}

fn et_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if et_has_prefix(req, et_delay_prefix) {
		// Parked for 3x the 300 ms budgets used below.
		event_loop.watch_fd(et_timerfd(900, 0), .readable, et_delay_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_stream_prefix) {
		out << et_stream_head
		event_loop.watch_fd(et_timerfd(et_tick_ms, et_tick_ms), .readable, et_stream_tick,
			voidptr(usize(0)))
		return .suspend
	}
	if et_has_prefix(req, et_lines_prefix) {
		if !core.queue_takeover(et_line_conn, unsafe { nil }) {
			out << et_ok // not takeover-capable: the test then fails on the missing 101
			return .done
		}
		out << et_switching
		return .done
	}
	if et_has_prefix(req, et_up_prefix) {
		if !core.queue_takeover(et_echo_conn, unsafe { nil }) {
			out << et_ok // not takeover-capable: the test then fails on the missing 101
			return .done
		}
		out << et_switching
		return .done
	}
	if et_has_prefix(req, et_lost_prefix) {
		event_loop.watch_fd(et_timerfd(50, 0), .readable, et_lost_rearm, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_nowatch_prefix) {
		return .suspend // no watch_fd: nothing can ever resume it
	}
	if et_has_prefix(req, et_upload_prefix) {
		out << et_upload_ok // answered from the head; the body is drained unseen
		return .done
	}
	if et_has_prefix(req, et_forever_prefix) {
		out << et_forever_head
		event_loop.watch_fd(et_timerfd(1, 1), .readable, et_forever_tick, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_big_prefix) {
		out << et_big_head
		start := out.len
		unsafe {
			out.grow_len(et_big_len)
			vmemset(&out[start], et_big_fill, et_big_len)
		}
		return .done
	}
	if et_has_prefix(req, et_self_prefix) {
		event_loop.watch_fd(client_fd, .writable, et_self_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_pool_prefix) {
		mut sv := [2]i32{} // C ints: V int is 64-bit
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close // no response: the test fails on the missing frame
		}
		reply := [u8(`x`)]!
		C.write(int(sv[1]), &reply[0], 1) // the upstream's reply, ready at once
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .readable, et_pool_done, pair)
		return .suspend
	}
	if et_has_prefix(req, et_sock_prefix) {
		mut sv := [2]i32{} // C ints: V int is 64-bit
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close // no response: the test fails on the missing frame
		}
		// Both ends ride in the payload: low 32 bits, high 32 bits.
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .writable, et_sock_step, pair)
		return .suspend
	}
	return et_choreo_handler(req, mut out, mut event_loop)
}

// et_choreo_handler serves the routes of the choreographed checks (#155).
fn et_choreo_handler(req []u8, mut out []u8, mut event_loop core.EventLoop) core.Step {
	mut c := unsafe { et_ch }
	if et_has_prefix(req, et_block408_prefix) {
		// A blocking read on a timerfd holds the worker (lower bound only).
		tfd := et_timerfd(1000, 0)
		mut tmp := [8]u8{}
		C.read(tfd, &tmp[0], 8)
		C.close(tfd)
		mut sv := [2]i32{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close
		}
		one := [u8(`x`)]!
		C.write(int(sv[1]), &one[0], 1)
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .readable, et_block408_done, pair)
		return .suspend
	}
	if et_has_prefix(req, et_park_prefix) {
		mut sv := [2]i32{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close
		}
		stdatomic.store_i64(&c.x, i64(sv[0]))
		stdatomic.store_i64(&c.peer, i64(sv[1]))
		event_loop.watch_fd(int(sv[0]), .readable, et_park_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_hupfirst_prefix) {
		et_ch_close(&c.a)
		et_ch_write(&c.peer, 'x'.bytes())
		out << et_ok
		return .done
	}
	if et_has_prefix(req, et_readyfirst_prefix) {
		et_ch_write(&c.peer, 'x'.bytes())
		et_ch_close(&c.a)
		out << et_ok
		return .done
	}
	if et_has_prefix(req, et_h6orch_prefix) {
		et_ch_close(&c.a)
		et_ch_write(&c.b, et_h6new_req)
		et_ch_write(&c.peer, 'x'.bytes())
		out << et_ok
		return .done
	}
	if et_has_prefix(req, et_h6new_prefix) {
		mut tfd := et_timerfd_nonblock(300)
		// The kernel hands out the lowest free number, which is x's here unless
		// a lower one is free too: fd numbers are process-wide, shared with the
		// check's own clients and earlier checks. Pin it, as long as x is free.
		x := int(stdatomic.load_i64(&c.x))
		if tfd >= 0 && x >= 0 && tfd != x && et_fd_inode(x) == 0 {
			C.dup2(i32(tfd), i32(x))
			C.close(tfd)
			tfd = x
		}
		if tfd == x {
			stdatomic.store_i64(&c.pinned, 1)
		}
		event_loop.watch_fd(tfd, .readable, et_h6_done, unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_pq_prefix) {
		if stdatomic.load_i64(&c.up0) < 0 {
			mut sv := [2]i32{}
			if C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) != 0 {
				return .close
			}
			stdatomic.store_i64(&c.up1, i64(sv[1]))
			stdatomic.store_i64(&c.up0, i64(sv[0]))
		}
		event_loop.watch_fd_persistent(int(stdatomic.load_i64(&c.up0)), .readable, et_pq_done,
			unsafe { nil })
		return .suspend
	}
	if et_has_prefix(req, et_qorch_prefix) {
		et_ch_write(&c.up1, '.'.bytes())
		et_ch_close(&c.a)
		out << et_ok
		return .done
	}
	if et_has_prefix(req, et_qfeed_prefix) {
		et_ch_write(&c.up1, '12'.bytes())
		out << et_ok
		return .done
	}
	if et_has_prefix(req, et_stepw_prefix) {
		mut sv := [2]i32{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) != 0 {
			return .close
		}
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .writable, et_stepw_step, pair)
		return .suspend
	}
	if et_has_prefix(req, et_stepr_prefix) {
		mut sv := [2]i32{}
		if C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0, &sv[0]) != 0 {
			return .close
		}
		et_write_all(int(sv[1]), et_req) // a whole request waits in sv[0]
		pair := voidptr(usize(u32(sv[0])) | (usize(u32(sv[1])) << 32))
		event_loop.watch_fd(int(sv[0]), .readable, et_stepr_step, pair)
		return .suspend
	}
	out << et_ok
	return .done
}

// et_block408_done closes client A behind the batch that runs it (A's hangup
// is only reported by the next epoll_wait), then answers.
fn et_block408_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	et_ch_close(unsafe { &et_ch.a })
	pair := u64(usize(watch_payload))
	C.close(int(u32(pair & 0xffff_ffff)))
	C.close(int(u32(pair >> 32)))
	out << et_ok
	return .done
}

// et_park_done consumes x's byte, closes both ends and the connection.
fn et_park_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	mut c := unsafe { et_ch }
	stdatomic.store_i64(&c.x, -1)
	C.close(ready_fd)
	et_ch_close(&c.peer)
	return .close
}

// et_h6_done answers `ok` once its timer really expired, `spurious` if it
// ran with nothing to read.
fn et_h6_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut v := u64(0)
	mut c := unsafe { et_ch }
	if C.read(ready_fd, &v, 8) == 8 {
		out << et_ok
	} else {
		stdatomic.add_i64(&c.spurious, 1)
		out << et_spurious
	}
	C.close(ready_fd)
	return .done
}

// et_timerfd_nonblock is a one-shot, non-blocking et_timerfd: a read before
// it expires fails (EAGAIN) instead of blocking the worker.
fn et_timerfd_nonblock(ms int) int {
	tfd := C.timerfd_create(1, C.TFD_NONBLOCK) // 1 = CLOCK_MONOTONIC
	if tfd < 0 {
		return tfd
	}
	mut spec := [4]i64{}
	spec[2] = i64(ms / 1000)
	spec[3] = i64(ms % 1000) * 1_000_000
	C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
	return tfd
}

// et_pq_done takes the next result off the mock upstream, in order: `.`
// streams the response head (payload 1 = head sent), a digit completes it.
fn et_pq_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut b := [1]u8{}
	if C.read(ready_fd, &b[0], 1) != 1 {
		event_loop.watch_fd_persistent(ready_fd, .readable, et_pq_done, watch_payload)
		return .suspend
	}
	if b[0] == `.` {
		out << et_pq_head
		event_loop.watch_fd_persistent(ready_fd, .readable, et_pq_done, voidptr(usize(1)))
		return .suspend
	}
	if watch_payload == unsafe { nil } {
		out << et_pq_head
	}
	out << b[0]
	return .done
}

// et_stepw_step steps from the (writable) socketpair end to a 500 ms timer,
// keeping the end open: from then on nothing watches it.
fn et_stepw_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	event_loop.watch_fd(et_timerfd(500, 0), .readable, et_sock_done, watch_payload)
	return .suspend
}

// et_stepr_step steps from the readable end to a 200 ms timer without reading.
fn et_stepr_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	event_loop.watch_fd(et_timerfd(200, 0), .readable, et_stepr_done, watch_payload)
	return .suspend
}

// et_stepr_done answers `ok` if the request is still unread in the end it
// stepped away from and nothing was written back into it; `zombie` if the
// worker served that end as if it were a client connection.
fn et_stepr_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	pair := u64(usize(watch_payload))
	s := int(u32(pair & 0xffff_ffff))
	peer := int(u32(pair >> 32))
	unread := C.recv(s, &tmp[0], 1, C.MSG_PEEK | C.MSG_DONTWAIT) == 1
	answered := C.recv(peer, &tmp[0], 1, C.MSG_DONTWAIT) > 0
	C.close(s)
	C.close(peer)
	if unread && !answered {
		out << et_ok
	} else {
		out << et_zombie
	}
	return .done
}

// et_forever_tick appends one byte per tick and re-parks, forever. The timer
// is request-owned: the runtime closes it when the client goes away.
fn et_forever_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	out << u8(`x`)
	event_loop.watch_fd(ready_fd, .readable, et_forever_tick, unsafe { nil })
	return .suspend
}

// et_sock_step runs once the socketpair end is writable (at once). It steps
// the request to a timer and keeps that end OPEN (the app may use it again).
// The end stays registered for EPOLLOUT with no watch behind it until
// et_sock_done closes it: it is not a new connection.
fn et_sock_step(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	event_loop.watch_fd(et_timerfd(100, 0), .readable, et_sock_done, watch_payload)
	return .suspend
}

// et_sock_done answers once the timer fires, then closes the timer and both
// socketpair ends (the request owns them).
fn et_sock_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	pair := u64(usize(watch_payload))
	C.close(int(u32(pair & 0xffff_ffff)))
	C.close(int(u32(pair >> 32)))
	out << et_ok
	return .done
}

// et_pool_done reads the upstream's reply and answers, keeping the pooled end
// open (and registered: the watch is level-triggered) for reuse. Then the
// upstream closes its end, as one that reaps idle connections would: from
// now on the pooled end reads EOF, with no watch behind it.
fn et_pool_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	pair := u64(usize(watch_payload))
	C.close(int(u32(pair >> 32)))
	mut pool := unsafe { et_pool }
	stdatomic.store_i64(&pool.inode, i64(et_fd_inode(ready_fd)))
	stdatomic.store_i64(&pool.fd, i64(ready_fd))
	out << et_ok
	return .done
}

// et_fd_inode is the inode of what fd refers to now (0 if it is closed).
fn et_fd_inode(fd int) u64 {
	st := os.stat('/proc/self/fd/${fd}') or { return 0 }
	return st.inode
}

// et_self_done answers once the client socket is writable (at once).
fn et_self_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	out << et_ok
	return .done
}

fn et_delay_done(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	out << et_delayed
	return .done
}

// et_lost_rearm "re-parks" on an fd it just closed: the watch cannot be armed
// (epoll ADD fails), yet it returns .suspend. Nothing would ever resume the
// request, and it holds no deadline while suspended.
fn et_lost_rearm(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8)
	C.close(ready_fd)
	event_loop.watch_fd(ready_fd, .readable, et_lost_rearm, unsafe { nil })
	return .suspend
}

// et_stream_tick appends one body piece per tick and re-parks (the SSE shape:
// append, .suspend ⇒ the runtime flushes, then re-parks) until the last piece.
// The tick count rides in watch_payload, so the stream allocates nothing.
fn et_stream_tick(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut tmp := [8]u8{}
	C.read(ready_fd, &tmp[0], 8) // level-triggered: consume the expiration
	out << et_tick
	n := int(usize(watch_payload)) + 1
	if n >= et_ticks {
		C.close(ready_fd)
		return .done
	}
	event_loop.watch_fd(ready_fd, .readable, et_stream_tick, voidptr(usize(n)))
	return .suspend
}

// et_echo_conn is the taken-over protocol: echo every byte back.
fn et_echo_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	out << buf
	return buf.len, core.Step.done
}

// et_line_conn echoes every complete line and leaves a partial one buffered,
// so a frame can span bursts.
fn et_line_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	for i := buf.len - 1; i >= 0; i-- {
		if buf[i] == `\n` {
			out << buf[..i + 1]
			return i + 1, core.Step.done
		}
	}
	return 0, core.Step.done
}

fn et_concat(a []u8, b []u8) []u8 {
	mut out := []u8{cap: a.len + b.len}
	out << a
	out << b
	return out
}

fn et_never(acc []u8) bool {
	return false
}

// GcStorm forces a garbage collection every 20 ms until stopped. Each Boehm
// collection stops every thread with a signal, so each worker's blocking wait
// returns EINTR far more often than its sweep interval — the condition that
// once kept a quiet worker from ever sweeping (it retried a wait computed
// from a stale clock), so its silent connections were never reaped. (A no-op
// under -gc none.)
struct GcStorm {
mut:
	stop i64
}

fn gc_storm(mut s GcStorm) {
	for stdatomic.load_i64(&s.stop) == 0 {
		gc_collect()
		time.sleep(20 * time.millisecond)
	}
}

// check_reaped_under_gc_signals: a silent connection is still reaped when the
// worker's wait is interrupted (EINTR) every 20 ms — shorter than its 100 ms
// sweep interval (read_timeout_ms 400). then_eof: only the server can end it.
fn check_reaped_under_gc_signals(backend server.IOBackend) ! {
	mut storm := &GcStorm{}
	t := spawn gc_storm(mut storm)
	defer {
		stdatomic.store_i64(&storm.stop, 1)
		t.wait()
	}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 400
		}
	}, [et_silent])!
	assert out.conns[0].connect_err == '', out.conns[0].connect_err
	assert out.conns[0].eof, '${backend}: a silent connection must be reaped under EINTR storms'
}

// check_pipelined_expect_gets_its_100: A asks for 100-continue and gets it;
// A's body and the head of B (also Expect: 100-continue) then arrive in ONE
// write. A is answered, and B must be prompted with its own 100 — the 100
// already sent was A's, not B's.
fn check_pipelined_expect_gets_its_100(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 5000
		}
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_expect_head
					until: vtest.count('100 Continue', 1)
				},
				vtest.Round{
					send:  et_concat(et_expect_body, et_expect_head)
					until: vtest.count('100 Continue', 2)
				},
				vtest.Round{
					send: et_expect_body
					want: 2
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the pipelined Expect request was not prompted with its own 100: ${c.raw.bytestr()}'
	assert c.frames.len >= 2
}

// check_streamed_expect_uploads_get_their_100: two streamed (> 1 MiB)
// Expect: 100-continue uploads on one keep-alive connection. Each must be
// prompted with its own 100 — the first upload's 100 must not suppress the
// second's (it never passes the pipelined-request path that resets it).
fn check_streamed_expect_uploads_get_their_100(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes()
	body := []u8{len: et_upload_body_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         et_handler
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  head
					until: vtest.count('100 Continue', 1)
				},
				vtest.Round{
					send:  body
					until: vtest.count('uploaded', 1)
				},
				vtest.Round{
					send:  head
					until: vtest.count('100 Continue', 2)
				},
				vtest.Round{
					send:  body
					until: vtest.count('uploaded', 2)
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the second streamed Expect upload was not prompted with its own 100: ${c.raw#[..300].bytestr()}'
}

// check_takeover_not_idle_reaped: a taken-over connection keeps only its
// mid-frame read deadline — sitting quiet between messages for longer than
// the idle budget must not close it. The silent witness is reaped by its
// accept-time deadline, which is at least as long as the idle budget.
fn check_takeover_not_idle_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_upgrade_req
					until: vtest.count('101 Switching Protocols', 1)
				},
			]
		},
	])!
	assert !up.conns[0].unmet, '${backend}: upgrade not answered: ${up.conns[0].raw.bytestr()}'
	witness := h.fire([et_silent])!
	assert witness.conns[0].eof, '${backend}: the silent witness must be reaped'
	again := h.send(up.group, 'ping-after-idle'.bytes(), vtest.count('ping-after-idle', 1))!
	c := again.conns[0]
	assert !c.eof, '${backend}: a taken-over connection must not be idle-reaped'
	assert !c.unmet, '${backend}: echo after the quiet period missing: ${c.raw.bytestr()}'
}

// check_takeover_quiet_after_partial_frame: a taken-over connection holds a
// read deadline only while a frame is partly buffered. Once the frame
// completes, the connection may sit quiet for longer than that budget. The
// partial frame goes out first, then a plain request on a second connection
// is answered: with workers: 1 the worker has read the partial by then (its
// event was queued first), so the frame really spans two bursts.
fn check_takeover_quiet_after_partial_frame(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  et_lines_req
					until: vtest.count('101 Switching Protocols', 1)
				},
			]
		},
	])!
	assert !up.conns[0].unmet, '${backend}: upgrade not answered: ${up.conns[0].raw.bytestr()}'
	h.send(up.group, 'par'.bytes(), et_always)!
	barrier := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_req
				},
			]
		},
	])!
	assert barrier.conns[0].frames.len == 1, '${backend}: barrier request not answered'
	line := h.send(up.group, 'tial\n'.bytes(), vtest.count('partial\n', 1))!
	assert !line.conns[0].eof && !line.conns[0].unmet, '${backend}: the split frame was not echoed: ${line.conns[0].raw.bytestr()}'
	// Server time passes: two silent witnesses, each reaped by its own 300 ms
	// accept-time deadline, so the partial frame's deadline has long passed.
	w1 := h.fire([et_silent])!
	assert w1.conns[0].eof, '${backend}: the silent witness must be reaped'
	w2 := h.fire([et_silent])!
	assert w2.conns[0].eof, '${backend}: the silent witness must be reaped'
	again := h.send(up.group, 'ping\n'.bytes(), vtest.count('ping\n', 1))!
	c := again.conns[0]
	assert !c.eof && !c.unmet, '${backend}: a taken-over connection was reaped on the deadline of a completed frame: ${c.raw.bytestr()}'
}

// check_parked_request_not_reaped: a request parked on a watch (a timerfd that
// fires after 3x the budgets) waits on its fd, not on the client: neither the
// accept-time deadline nor idle may reap it. Once the continuation answers,
// the connection is back at rest and the idle deadline must close it.
fn check_parked_request_not_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_delay_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: a parked request was reaped before its watch fired: ${c.raw.bytestr()}'
	assert c.frames.len == 1
	assert c.frames[0].bytestr().ends_with('delayed'), '${backend}: expected the continuation answer, got: ${c.raw.bytestr()}'
	assert c.eof, '${backend}: after the resumed response the idle deadline must close the connection'
	assert !c.raw.bytestr().contains('408'), '${backend}: idle close must be silent'
}

// check_lost_resume_closed: a continuation that returns .suspend without a
// live watch (watch_fd failed, or was never called) can never be resumed. The
// connection must be closed then — not left waiting forever with no deadline
// holding its max_connections slot. then_eof: only the server can end it.
fn check_lost_resume_closed(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_lost_req
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: a suspend that cannot be resumed must close the connection'
	assert out.active_after == 0
}

// check_unwatched_suspend_closed: three pipelined requests, the middle one's
// handler returns .suspend without a watch. Nothing can resume it, so the
// connection is closed (the poll backend, which has no watch reactor, drops it
// too) — after the first request's answer is flushed, and without answering
// the third in the middle one's place: its client would take that answer for
// the middle one's. Also run on io_uring, which has the same drain.
fn check_unwatched_suspend_closed(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_ok_nowatch_ok
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: want only the first answer, got: ${c.raw.bytestr()}'
	assert c.frames[0] == et_ok, '${backend}: the first answer was not flushed: ${c.raw.bytestr()}'
	assert c.eof
	assert out.active_after == 0
}

// check_streaming_watch_not_idle_reaped: a continuation that streams (append,
// .suspend, flushed, re-parked) for several idle budgets is not at rest between
// pieces — the idle clock must not start at those flushes (they run BEFORE the
// runtime re-parks the connection). After the last piece it is at rest again.
fn check_streaming_watch_not_idle_reaped(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_stream_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: a streaming response was cut mid-stream: ${c.raw.bytestr()}'
	assert c.frames.len == 1
	assert c.frames[0].bytestr().ends_with('tick\n'.repeat(et_ticks)), '${backend}: stream incomplete: ${c.raw.bytestr()}'
	assert c.eof, '${backend}: after the stream completed the idle deadline must close the connection'
}

// check_expect_100_under_timeouts: Expect: 100-continue with read and idle
// armed. The client holds the body for longer than the idle budget after the
// interim 100 (the idle witness): the head is buffered, so the connection is
// mid-request — the read deadline governs, idle must not fire. Then the final
// 200, then idle closes the connection silently.
fn check_expect_100_under_timeouts(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 5000
			idle_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	exp := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_expect_head
					want: 1
				},
			]
		},
	])!
	assert exp.conns[0].frames.len == 1
	assert exp.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 100'), '${backend}: interim 100 missing'
	witness := h.fire([et_idle_witness])!
	assert witness.conns[0].eof, '${backend}: the idle witness must be reaped'
	fin := h.send(exp.group, et_expect_body, vtest.frames(2))!
	c := fin.conns[0]
	assert !c.eof && !c.unmet, '${backend}: a request held after 100-continue was reaped: ${c.raw.bytestr()}'
	assert c.frames.len == 2
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 200')
	closed := h.wait(exp.group, et_never)!
	assert closed.conns[0].eof, '${backend}: idle must close the connection after the final response'
	assert !closed.conns[0].raw.bytestr().contains('408')
}

// check_streamed_upload_under_timeouts: a > 1 MiB body takes the drain path
// (head answered and held, body consumed unseen). The client stalls mid-body
// for longer than the idle budget (the idle witness): a draining connection
// is mid-request, so idle must not fire. Then a second full upload on the same
// connection proves the drain was exact and keep-alive survived.
fn check_streamed_upload_under_timeouts(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
	first_chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
	rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
	full_body := []u8{len: et_upload_body_len, init: u8(0x61)}
	mut h := vtest.start(server.ServerConfig{
		workers:         1
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			max_request_bytes: 8 * 1024 * 1024
			read_timeout_ms:   5000
			idle_timeout_ms:   300
		}
	})!
	defer {
		h.stop()
	}
	up := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_concat(head, first_chunk)
					want: 0
				},
			]
		},
	])!
	witness := h.fire([et_idle_witness])!
	assert witness.conns[0].eof, '${backend}: the idle witness must be reaped'
	one := h.send(up.group, rest, vtest.frames(1))!
	assert !one.conns[0].eof && !one.conns[0].unmet, '${backend}: an upload stalled mid-body was idle-reaped: ${one.conns[0].raw.bytestr()}'
	two := h.send(up.group, et_concat(head, full_body), vtest.frames(2))!
	c := two.conns[0]
	assert !c.eof && !c.unmet, '${backend}: keep-alive after a drained upload broke'
	assert c.frames.len == 2
	for f in c.frames {
		assert f.bytestr().ends_with('uploaded'), '${backend}: unexpected upload answer: ${f.bytestr()}'
	}
}

// check_connect_storm_served: many connections whose request is written right
// behind the connect, with an accept-time deadline armed. Some of them reach
// the worker as ONE event carrying the birth EPOLLOUT and the request's
// EPOLLIN; under EPOLLET the EPOLLIN half must be served in that same event,
// or the request is never reported again and the client waits forever.
fn check_connect_storm_served(backend server.IOBackend, limits server.Limits) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          limits
	}, vtest.repeat(128, vtest.Script{
		rounds: [
			vtest.Round{
				send: et_req
				want: 1
			},
		]
	}))!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert c.frames.len == 1, '${backend}: storm conn ${i} not served'
	}
}

// check_vanished_streams_released: many streams parked on their timers, and
// every client goes away at once (stop() closes them all, with ticks still
// unread, so most peers reset). In one batch a client's close and its timer's
// tick then arrive in either order, and the flush of a tick can be the first
// to see the peer gone. Every connection must be released exactly once. A
// stale event for an fd already closed in the batch (a client, or the timer
// its hangup tore down) must not release it again (active_conns drifts below
// zero) or build a zombie. Every stream's timer is closed with its connection
// too, including when a tick's flush is the first to see the peer gone (the
// re-armed watch is torn down there).
fn check_vanished_streams_released(backend server.IOBackend) ! {
	before := et_open_fds()
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 60000 // accept-time births on; nothing expires here
			idle_timeout_ms: -1
		}
	}, vtest.repeat(128, vtest.Script{
		rounds: [
			vtest.Round{
				send:  et_forever_req
				until: vtest.count('xxx', 1)
			},
		]
	}))!
	for i, c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert !c.unmet, '${backend}: stream ${i} did not start: ${c.raw.bytestr()}'
	}
	assert out.active_after == 0, '${backend}: active_conns drifted to ${out.active_after}'
	// Every stream's timer must be closed with its connection. drive() settles
	// the connection count; a timer closed on the tick that found its peer gone
	// may follow a moment later, so allow the same bounded settle. The stopped
	// server keeps 2 fds of its own; a leaked timer per vanished stream would
	// be one per stream (128).
	mut leaked := et_open_fds() - before
	for _ in 0 .. 500 {
		if leaked < 6 {
			break
		}
		time.sleep(time.millisecond)
		leaked = et_open_fds() - before
	}
	assert leaked < 6, '${backend}: ${leaked} fds leaked — a watch outlived its client'
}

fn et_open_fds() int {
	fds := os.ls('/proc/self/fd') or { return 0 }
	return fds.len
}

fn et_always(acc []u8) bool {
	return true
}

// et_big_mismatch returns the first index where raw stops being a prefix of
// the /big response (head, then only fill bytes), or -1 if it is one.
@[direct_array_access]
fn et_big_mismatch(raw []u8) int {
	for i in 0 .. raw.len {
		want := if i < et_big_head.len { et_big_head[i] } else { et_big_fill }
		if i >= et_big_head.len + et_big_len || raw[i] != want {
			return i
		}
	}
	return -1
}

// check_pipelined_partial_fresh_deadline: a request that arrives behind a
// completed one gets its own read deadline from its first byte. It must not
// inherit the clock armed at accept (or for the request before it). `first`
// starts a request, `second` completes it and starts the next one, `third`
// completes that one. Budgets: read 1200 ms, idle 800 ms (sweep 200 ms). The
// idle witness takes 800 to ~1000 ms. `second` goes out before the first
// request's deadline (1200 ms from accept); `third` goes out well after that
// deadline, but within 1200 ms of `second`. workers: 1, so each witness shares
// the sweep with the connection under test.
fn check_pipelined_partial_fresh_deadline(backend server.IOBackend, first []u8, second []u8, third []u8) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 1200
			idle_timeout_ms: 800
		}
	})!
	defer {
		h.stop()
	}
	conn := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: first
					want: 0
				},
			]
		},
	])!
	w1 := h.fire([et_idle_witness])!
	assert w1.conns[0].eof, '${backend}: the idle witness must be reaped'
	one := h.send(conn.group, second, vtest.frames(1))!
	assert !one.conns[0].eof && !one.conns[0].unmet, '${backend}: the first request was not answered: ${one.conns[0].raw.bytestr()}'
	w2 := h.fire([et_idle_witness])!
	assert w2.conns[0].eof, '${backend}: the idle witness must be reaped'
	two := h.send(conn.group, third, vtest.frames(2))!
	c := two.conns[0]
	assert !c.eof && !c.unmet, "${backend}: the pipelined request was reaped on the previous request's clock: ${c.raw.bytestr()}"
	assert c.frames.len == 2
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 200'), '${backend}: unexpected answer: ${c.frames[1].bytestr()}'
}

// check_no_408_inside_pending_response: a read deadline that expires while a
// response is still pending must close silently. The 408 must not be written
// into the middle of that response. /big (7 MiB) is parked part-sent because
// the client does not read. A streamed upload then stalls mid-body: its
// response is held until the body drains, and that hold also stops the
// writable drain of /big. The client then reads what was sent, so the socket
// has room when the upload's read deadline expires. The bytes received must be
// exactly a prefix of the /big response, and the connection must end.
fn check_no_408_inside_pending_response(backend server.IOBackend) ! {
	upload_head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
	// One full read buffer (8 KiB) starts the streamed drain. The send still
	// fits a fresh socket's send buffer, so it goes out in one call and the
	// client reads nothing yet.
	upload_start := et_concat(upload_head, []u8{len: 8192, init: u8(0x61)})
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		workers:         1
		limits:          server.Limits{
			read_timeout_ms: 1000
			idle_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	big := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_big_req
					want: 0
				},
			]
		},
	])!
	// Server time passes: /big is answered and parks part-sent. Its request is
	// complete and nothing is buffered, so no read or idle deadline is armed.
	w1 := h.fire([et_idle_witness])!
	assert w1.conns[0].eof, '${backend}: the idle witness must be reaped'
	// et_always: write the upload start and return without reading.
	h.send(big.group, upload_start, et_always)!
	// Server time passes again (300 to ~400 ms): the upload head has been read
	// and the drain has started. Its read deadline (1000 ms) is still ahead.
	w2 := h.fire([et_idle_witness])!
	assert w2.conns[0].eof, '${backend}: the idle witness must be reaped'
	out := h.wait(big.group, et_never)!
	c := out.conns[0]
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.len > et_big_head.len, '${backend}: precondition: /big should be part-sent, got ${c.raw.len} bytes'
	assert c.raw.len < et_big_head.len + et_big_len, '${backend}: precondition: /big should still be pending, but all of it arrived'
	bad := et_big_mismatch(c.raw)
	assert bad < 0, '${backend}: bytes after offset ${bad} are not /big response bytes (408 inside it?): ${c.raw#[bad..bad + 120].bytestr()}'
}

// check_stalled_upload_408: a streamed upload that stalls mid-body until its
// read deadline passes gets a 408, then the close (plaintext epoll sends the
// 408 when part of a request arrived). The upload's own reply is held in
// write_buf until the body drains. The client has not seen it, so it must
// not suppress the 408: the 408 replaces it. But when a request pipelined
// ahead of the upload still has its reply held too, a 408 would be read as
// the answer to that request: the close is silent then.
fn check_stalled_upload_408(backend server.IOBackend) ! {
	upload := et_concat('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes(),
		[]u8{len: et_upload_chunk_len, init: u8(0x61)})
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: upload
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(et_req, upload)
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled upload must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	behind := out.conns[1]
	assert behind.connect_err == '', behind.connect_err
	assert behind.eof, '${backend}: the stalled upload must be reaped'
	assert behind.raw.len == 0, '${backend}: a 408 ahead of the reply owed to the pipelined GET: ${behind.raw.bytestr()}'
	assert out.active_after == 0
}

// check_stalled_upload_408_after_expect: an upload with Expect: 100-continue
// whose client sends the first body bytes in the same write as the head
// (RFC 9110 §10.1.1 lets it skip the wait), then stalls. The server queues the
// interim 100 in the burst that also starts the streamed drain, so the 100 is
// held with the upload's reply and never sent. It is that request's own
// output, not a response owed to an earlier request: the stall still gets its
// 408. When the client does wait for the 100, the 408 follows it.
fn check_stalled_upload_408_after_expect(backend server.IOBackend) ! {
	head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes()
	chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(head, chunk)
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: head
					want: 1
				},
				vtest.Round{
					send: chunk
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled upload whose 100 Continue was never sent must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	waited := out.conns[1]
	assert waited.connect_err == '', waited.connect_err
	assert waited.eof, '${backend}: the stalled upload must be reaped'
	assert waited.raw.bytestr().starts_with('HTTP/1.1 100'), '${backend}: interim 100 missing: ${waited.raw.bytestr()}'
	assert waited.raw.bytestr().contains('\r\n\r\nHTTP/1.1 408'), '${backend}: no 408 after the 100 Continue: ${waited.raw.bytestr()}'
	assert !waited.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	assert out.active_after == 0
}

// check_stepped_away_watch_not_adopted: a continuation that steps from one fd
// to another keeps the first one open. That fd stays registered, and its
// level-triggered EPOLLOUT keeps coming back with no watch and no connection
// behind it. It must not be taken for a new connection's birth: adopted, its
// state expired and closed the app's fd, which also decremented active_conns
// for a connection that was never counted. Only a socket accepted on the
// listener is born. `uds` = '' listens on TCP; otherwise on that unix socket
// path, where the app's fd (a socketpair end) is AF_UNIX too, but unnamed.
fn check_stepped_away_watch_not_adopted(backend server.IOBackend, uds string) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing:  backend
		handler:          et_handler
		workers:          1
		unix_socket_path: uds
		limits:           server.Limits{
			read_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_sock_req
					want: 1
				},
			]
			then_eof: true // idle-reaped; any adopted fd expired earlier
		},
		et_silent, // reaped by its accept-time deadline: births work here
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend} ${uds}: /sock not answered: ${c.raw.bytestr()}'
	assert c.eof
	assert out.conns[1].connect_err == '', out.conns[1].connect_err
	assert out.conns[1].eof, '${backend} ${uds}: the silent connection must be reaped'
	assert out.active_after == 0, '${backend} ${uds}: active_conns drifted to ${out.active_after}'
}

// check_pooled_fd_eof_no_spin: a pooled fd kept open after its watch finished
// stays registered, level-triggered. Once its upstream closes it, it reads
// EOF on every epoll_wait, with no watch and no connection behind it. The
// worker must not busy-loop on it (a report dropped on every wait never lets
// epoll_wait block), must not adopt it as a connection (its close would free
// a slot that was never counted) and must leave it open (the app owns it). The
// window is the silent witness, reaped by its accept-time deadline after at
// least 500 ms; the worker, blocked in epoll_wait, should use next to no CPU
// in it. `uds` = '' listens on TCP; otherwise on that unix socket path.
fn check_pooled_fd_eof_no_spin(backend server.IOBackend, uds string) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing:  backend
		handler:          et_handler
		workers:          1
		unix_socket_path: uds
		limits:           server.Limits{
			read_timeout_ms: 500
			idle_timeout_ms: -1 // the client connection stays at rest meanwhile
		}
	})!
	defer {
		h.stop()
	}
	pool := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_pool_req
					want: 1
				},
			]
		},
	])!
	assert !pool.conns[0].unmet, '${backend} ${uds}: /pool not answered: ${pool.conns[0].raw.bytestr()}'
	cpu0 := C.clock()
	witness := h.fire([et_silent])!
	cpu_us := C.clock() - cpu0
	assert witness.conns[0].eof, '${backend} ${uds}: the silent witness must be reaped'
	assert cpu_us < 100_000, '${backend} ${uds}: the worker busy-looped on a pooled fd whose upstream closed: ${cpu_us} us of CPU in a window of at least 500 ms'
	again := h.send(pool.group, et_req, vtest.frames(2))!
	assert !again.conns[0].eof && !again.conns[0].unmet, '${backend} ${uds}: the client connection stopped serving: ${again.conns[0].raw.bytestr()}'
	assert again.active_after == 1, '${backend} ${uds}: active_conns drifted to ${again.active_after}'
	pooled := int(stdatomic.load_i64(&et_pool.fd))
	assert et_fd_inode(pooled) == u64(stdatomic.load_i64(&et_pool.inode)), '${backend} ${uds}: the pooled end was closed under the app'
	C.close(pooled)
}

// check_self_watch_keepalive: a request parks on its own client socket
// becoming writable (watch_fd(client_fd, .writable)), then answers. The
// connection must go on serving: its next request is read and answered, and
// it is then idle-reaped as usual. A watch that replaced the socket's
// EPOLLIN|EPOLLET registration with a one-shot EPOLLOUT would leave it
// reporting nothing once the watch fired.
fn check_self_watch_keepalive(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			idle_timeout_ms: 300
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_self_req
					want: 1
				},
				vtest.Round{
					send: et_req
					want: 1
				},
			]
			then_eof: true // idle-reaped after the second answer
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 2, '${backend}: the request after a self-watch was not answered: ${c.raw.bytestr()}'
	for f in c.frames {
		assert f == et_ok, '${backend}: unexpected answer: ${f.bytestr()}'
	}
	assert c.eof
	assert out.active_after == 0, '${backend}: active_conns drifted to ${out.active_after}'
}

// Accept-time births on, with nothing expiring during a check.
const et_births_on = server.Limits{
	read_timeout_ms: 60000
	idle_timeout_ms: -1
}

fn et_births(limits server.Limits) string {
	return if limits.read_timeout_ms > 0 || limits.idle_timeout_ms > 0 {
		'births on'
	} else {
		'births off'
	}
}

fn et_uds_server(path string, limits server.Limits) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing:  .epoll
		handler:          et_handler
		workers:          1
		unix_socket_path: path
		limits:           limits
	}
}

fn et_one(req []u8) vtest.Script {
	return vtest.Script{
		rounds: [
			vtest.Round{
				send: req
				want: 1
			},
		]
	}
}

// check_408_to_vanished_peer_no_sigpipe (#155): the sweep's 408 goes to a
// peer that left after epoll_wait collected the batch, so its hangup is only
// reported by the next one. Client A sends part of a request (it earns a 408);
// /block408 holds the worker past A's 500 ms deadline and parks on an fd that
// is already ready. The next pass (hot: epoll_wait(0), its clock now past the
// deadline) runs the continuation, which closes A; its sweep then writes the
// 408 to a closed AF_UNIX peer: EPIPE, and without MSG_NOSIGNAL a SIGPIPE,
// whose default action kills this test binary. The witness proves the sweep ran.
fn check_408_to_vanished_peer_no_sigpipe() ! {
	path := et_uds('408')
	et_ch_reset()
	mut c := unsafe { et_ch }
	mut h := vtest.start(et_uds_server(path, server.Limits{ read_timeout_ms: 500 }))!
	defer {
		h.stop()
	}
	stdatomic.store_i64(&c.a, i64(et_dial(path, 'GET / HTTP/1.1\r\nHo'.bytes())!))
	x := h.fire([et_one(et_block408_req)])!
	assert !x.conns[0].unmet && x.conns[0].frames.len == 1, '/block408 not answered: ${x.conns[0].raw.bytestr()}'
	witness := h.fire([et_silent])!
	assert witness.conns[0].eof, 'the silent witness must be reaped'
}

// check_pipelined_head_flush_failure (#155 H2): two clients pipelined on one
// mock upstream. The head's continuation streams its response head and
// suspends (its result is still in flight), and that flush finds client A
// gone. Its queue slot must become a tombstone that consumes A's result when
// it arrives; dropping it handed A's result (`1`) to the next client.
fn check_pipelined_head_flush_failure(limits server.Limits) ! {
	path := et_uds('pq')
	et_ch_reset()
	mut c := unsafe { et_ch }
	mut h := vtest.start(et_uds_server(path, limits))!
	defer {
		h.stop()
		et_ch_close(&c.up0)
		et_ch_close(&c.up1)
	}
	label := et_births(limits)
	stdatomic.store_i64(&c.a, i64(et_dial(path, et_pq_req)!))
	second := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_pq_req
					want: 0 // parks behind A, answered at the end
				},
			]
		},
	])!
	feed := h.fire([et_one(et_req)])! // accepted before the orchestrated batch

	orch := h.fire([et_one(et_qorch_req)])!
	assert orch.conns[0].frames.len == 1, '${label}: /qorch not answered'
	fed := h.send(feed.group, et_qfeed_req, vtest.frames(2))!
	assert fed.conns[0].frames.len == 2, '${label}: /qfeed not answered'
	out := h.wait(second.group, vtest.frames(1))!
	r := out.conns[0]
	assert !r.unmet && r.frames.len == 1, '${label}: the second client was not answered: ${r.raw.bytestr()}'
	assert r.frames[0] == et_concat(et_pq_head, '2'.bytes()), "${label}: the second client got the first client's in-flight result: ${r.frames[0].bytestr()}"
	// A's hangup was still queued in the batch whose flush closed it: a stale
	// event, which must not release A again (the second client, the feed and
	// the orchestrator stay open).
	assert out.active_after == 3, '${label}: active_conns drifted to ${out.active_after}'
}

// check_stepped_away_watch (#155 H4): a continuation that steps from one fd
// to another, keeping the first open, leaves it registered, level-triggered,
// with no watch behind it — and with births off nothing else ever looks at it.
// /stepw leaves a writable end for 500 ms: it reports on every epoll_wait, so
// the worker spun. /stepr leaves a readable end with a request in it: the
// worker served it as a client connection — read the request, wrote the
// response back into it.
fn check_stepped_away_watch(limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         et_handler
		workers:         1
		limits:          limits
	})!
	defer {
		h.stop()
	}
	label := et_births(limits)
	cpu0 := C.clock()
	w := h.fire([et_one(et_stepw_req)])!
	cpu_us := C.clock() - cpu0
	assert !w.conns[0].unmet && w.conns[0].frames.len == 1, '${label}: /stepw not answered: ${w.conns[0].raw.bytestr()}'
	assert cpu_us < 100_000, '${label}: the worker busy-looped on an end a continuation stepped away from: ${cpu_us} us of CPU in 500 ms'
	r := h.fire([et_one(et_stepr_req)])!
	assert !r.conns[0].unmet && r.conns[0].frames.len == 1, '${label}: /stepr not answered: ${r.conns[0].raw.bytestr()}'
	assert r.conns[0].frames[0] == et_ok, '${label}: the end a continuation stepped away from was served as a connection'
	assert r.active_after == 2, '${label}: active_conns drifted to ${r.active_after}'
}

// check_stale_event_after_close (#155 H5): an event for an fd the worker
// closed earlier in the same batch describes a registration that is gone. It
// must be dropped, births on or off. /hupfirst closes client A (parked on x)
// and then makes x readable: A's hangup tears x down, and x's stale event
// built a zombie on the closed number, whose close released a slot that was
// never taken. /readyfirst makes x readable first: its continuation closes
// A, and A's stale hangup released A a second time. Either way active_conns
// fell below the two connections open (the orchestrator's and the barrier's).
fn check_stale_event_after_close(limits server.Limits, orch []u8) ! {
	path := et_uds('h5')
	et_ch_reset()
	mut c := unsafe { et_ch }
	mut h := vtest.start(et_uds_server(path, limits))!
	defer {
		h.stop()
		et_ch_close(&c.peer)
	}
	label := '${et_births(limits)} ${orch.bytestr().all_before(' HTTP')}'
	stdatomic.store_i64(&c.a, i64(et_dial(path, et_park_req)!))
	barrier := h.fire([et_one(et_req)])! // accepted before the orchestrated batch
	o := h.fire([et_one(orch)])!
	assert o.conns[0].frames.len == 1, '${label}: orchestrator not answered'
	after := h.send(barrier.group, et_req, vtest.frames(2))!
	assert after.conns[0].frames.len == 2, '${label}: barrier not answered'
	assert after.active_after == 2, '${label}: active_conns is ${after.active_after} with 2 connections open: a stale event released a closed connection again'
}

// check_stale_event_not_routed_to_new_watch (#155 H6): in one batch, client
// A's hangup tears down its watch fd x, client B's request then parks on a
// fresh timer that takes x's number, and x's stale readiness follows. It must
// not reach B's continuation, which would run with nothing ready (or block,
// on a blocking fd): B answers `ok` only once its timer expires.
fn check_stale_event_not_routed_to_new_watch(limits server.Limits) ! {
	path := et_uds('h6')
	et_ch_reset()
	mut c := unsafe { et_ch }
	mut h := vtest.start(et_uds_server(path, limits))!
	defer {
		h.stop()
		et_ch_close(&c.peer)
		et_ch_close(&c.b)
	}
	label := et_births(limits)
	stdatomic.store_i64(&c.a, i64(et_dial(path, et_park_req)!))
	stdatomic.store_i64(&c.b, i64(et_dial(path, []u8{})!))
	o := h.fire([et_one(et_h6orch_req)])!
	assert o.conns[0].frames.len == 1, '${label}: orchestrator not answered'
	resp := et_read_response(int(stdatomic.load_i64(&c.b)))
	assert stdatomic.load_i64(&c.pinned) == 1, "${label}: precondition: /h6new's timer did not take the torn-down number"
	assert stdatomic.load_i64(&c.spurious) == 0, '${label}: a stale event for a torn-down fd ran the continuation of the new watch on its number'
	assert resp == et_ok, '${label}: /h6new answered ${resp.bytestr()}'
}

// check_pooled_fd_eof_births_off: check_pooled_fd_eof_no_spin with births off
// (the default Limits), where no birth guard looks at an fd with no state.
// The pooled end reading EOF was taken for a client hanging up: the worker
// closed the app's fd under it and released a slot that was never taken. The
// window is a /delay request (900 ms), with the worker blocked in epoll_wait.
fn check_pooled_fd_eof_births_off(uds string) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing:  .epoll
		handler:          et_handler
		workers:          1
		unix_socket_path: uds
	})!
	defer {
		h.stop()
	}
	pool := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: et_pool_req
					want: 1
				},
			]
		},
	])!
	assert !pool.conns[0].unmet, '${uds}: /pool not answered: ${pool.conns[0].raw.bytestr()}'
	cpu0 := C.clock()
	window := h.fire([et_one(et_delay_req)])!
	cpu_us := C.clock() - cpu0
	assert window.conns[0].frames.len == 1, '${uds}: /delay not answered'
	assert cpu_us < 100_000, '${uds}: the worker busy-looped on a pooled fd whose upstream closed: ${cpu_us} us of CPU in 900 ms'
	again := h.send(pool.group, et_req, vtest.frames(2))!
	assert !again.conns[0].eof && !again.conns[0].unmet, '${uds}: the client connection stopped serving: ${again.conns[0].raw.bytestr()}'
	assert again.active_after == 2, '${uds}: active_conns drifted to ${again.active_after}'
	pooled := int(stdatomic.load_i64(&et_pool.fd))
	assert et_fd_inode(pooled) == u64(stdatomic.load_i64(&et_pool.inode)), '${uds}: the pooled end was closed under the app'
	C.close(pooled)
}

fn test_epoll_408_to_vanished_peer_no_sigpipe() ! {
	$if linux {
		check_408_to_vanished_peer_no_sigpipe()!
	}
}

fn test_epoll_pipelined_head_flush_failure() ! {
	$if linux {
		check_pipelined_head_flush_failure(et_births_on)!
		check_pipelined_head_flush_failure(server.Limits{})!
	}
}

fn test_epoll_stepped_away_watch() ! {
	$if linux {
		check_stepped_away_watch(server.Limits{})!
		check_stepped_away_watch(et_births_on)!
	}
}

fn test_epoll_stale_event_after_close() ! {
	$if linux {
		for limits in [server.Limits{}, et_births_on] {
			check_stale_event_after_close(limits, et_hupfirst_req)!
			check_stale_event_after_close(limits, et_readyfirst_req)!
		}
	}
}

fn test_epoll_stale_event_not_routed_to_new_watch() ! {
	$if linux {
		check_stale_event_not_routed_to_new_watch(server.Limits{})!
		check_stale_event_not_routed_to_new_watch(et_births_on)!
	}
}

fn test_epoll_pooled_fd_eof_births_off() ! {
	$if linux {
		check_pooled_fd_eof_births_off('')!
		check_pooled_fd_eof_births_off(et_uds('pool_off'))!
	}
}

fn test_epoll_takeover_not_idle_reaped() ! {
	$if linux {
		check_takeover_not_idle_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
		check_takeover_not_idle_reaped(.epoll, server.Limits{
			idle_timeout_ms: 300
		})!
	}
}

fn test_epoll_takeover_quiet_after_partial_frame() ! {
	$if linux {
		check_takeover_quiet_after_partial_frame(.epoll)!
	}
}

fn test_epoll_parked_request_not_reaped() ! {
	$if linux {
		check_parked_request_not_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
		check_parked_request_not_reaped(.epoll, server.Limits{
			idle_timeout_ms: 300
		})!
	}
}

fn test_epoll_streaming_watch_not_idle_reaped() ! {
	$if linux {
		check_streaming_watch_not_idle_reaped(.epoll, server.Limits{
			read_timeout_ms: 300
		})!
	}
}

fn test_epoll_lost_resume_closed() ! {
	$if linux {
		check_lost_resume_closed(.epoll)!
	}
}

fn test_epoll_unwatched_suspend_closed() ! {
	$if linux {
		check_unwatched_suspend_closed(.epoll)!
	}
}

fn test_iouring_unwatched_suspend_closed() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_unwatched_suspend_closed(.io_uring)!
	}
}

fn test_epoll_reaped_under_gc_signals() ! {
	$if linux {
		check_reaped_under_gc_signals(.epoll)!
	}
}

fn test_epoll_pipelined_partial_fresh_deadline() ! {
	$if linux {
		// A partial head, completed together with the next request's partial.
		check_pipelined_partial_fresh_deadline(.epoll, 'GET / HTTP/1.1\r\nHost: x\r\n'.bytes(),
			'\r\nGET / HTTP/1.1\r\nHo'.bytes(), 'st: x\r\n\r\n'.bytes())!
		// A streamed upload, whose body completes together with the next
		// request's partial.
		head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
		chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
		rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
		check_pipelined_partial_fresh_deadline(.epoll, et_concat(head, chunk), et_concat(rest,
			'GET / HTTP/1.1\r\nHo'.bytes()), 'st: x\r\n\r\n'.bytes())!
	}
}

fn test_epoll_no_408_inside_pending_response() ! {
	$if linux {
		check_no_408_inside_pending_response(.epoll)!
	}
}

fn test_epoll_stalled_upload_408() ! {
	$if linux {
		check_stalled_upload_408(.epoll)!
	}
}

fn test_epoll_stalled_upload_408_after_expect() ! {
	$if linux {
		check_stalled_upload_408_after_expect(.epoll)!
	}
}

fn test_epoll_stepped_away_watch_not_adopted() ! {
	$if linux {
		check_stepped_away_watch_not_adopted(.epoll, '')!
		check_stepped_away_watch_not_adopted(.epoll, os.join_path(os.temp_dir(),
			'vanilla_et_sock_${os.getpid()}.sock'))!
	}
}

fn test_epoll_pooled_fd_eof_no_spin() ! {
	$if linux {
		check_pooled_fd_eof_no_spin(.epoll, '')!
		check_pooled_fd_eof_no_spin(.epoll, os.join_path(os.temp_dir(), 'vanilla_et_pool_${os.getpid()}.sock'))!
	}
}

fn test_epoll_self_watch_keepalive() ! {
	$if linux {
		check_self_watch_keepalive(.epoll)!
	}
}

fn test_epoll_expect_100_under_timeouts() ! {
	$if linux {
		check_expect_100_under_timeouts(.epoll)!
	}
}

fn test_epoll_pipelined_expect_gets_its_100() ! {
	$if linux {
		check_pipelined_expect_gets_its_100(.epoll)!
	}
}

fn test_epoll_streamed_expect_uploads_get_their_100() ! {
	$if linux {
		check_streamed_expect_uploads_get_their_100(.epoll)!
	}
}

fn test_epoll_streamed_upload_under_timeouts() ! {
	$if linux {
		check_streamed_upload_under_timeouts(.epoll)!
	}
}

fn test_epoll_connect_storm_served() ! {
	$if linux {
		check_connect_storm_served(.epoll, server.Limits{
			read_timeout_ms: 2000
		})!
		check_connect_storm_served(.epoll, server.Limits{
			idle_timeout_ms: 2000
		})!
	}
}

fn test_epoll_vanished_streams_released() ! {
	$if linux {
		check_vanished_streams_released(.epoll)!
	}
}

// --- poll (-d vanilla_poll): the checks that need no watch reactor ----------

fn test_poll_pipelined_partial_fresh_deadline() ! {
	$if linux {
		$if vanilla_poll ? {
			check_pipelined_partial_fresh_deadline(.poll, 'GET / HTTP/1.1\r\nHost: x\r\n'.bytes(),
				'\r\nGET / HTTP/1.1\r\nHo'.bytes(), 'st: x\r\n\r\n'.bytes())!
			head := 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\n\r\n'.bytes()
			chunk := []u8{len: et_upload_chunk_len, init: u8(0x61)}
			rest := []u8{len: et_upload_body_len - et_upload_chunk_len, init: u8(0x61)}
			check_pipelined_partial_fresh_deadline(.poll, et_concat(head, chunk), et_concat(rest,
				'GET / HTTP/1.1\r\nHo'.bytes()), 'st: x\r\n\r\n'.bytes())!
		}
	}
}

fn test_poll_no_408_inside_pending_response() ! {
	$if linux {
		$if vanilla_poll ? {
			check_no_408_inside_pending_response(.poll)!
		}
	}
}

fn test_poll_stalled_upload_408() ! {
	$if linux {
		$if vanilla_poll ? {
			check_stalled_upload_408(.poll)!
		}
	}
}

fn test_poll_expect_100_under_timeouts() ! {
	$if linux {
		$if vanilla_poll ? {
			check_expect_100_under_timeouts(.poll)!
		}
	}
}

fn test_poll_pipelined_expect_gets_its_100() ! {
	$if linux {
		$if vanilla_poll ? {
			check_pipelined_expect_gets_its_100(.poll)!
		}
	}
}

fn test_poll_streamed_expect_uploads_get_their_100() ! {
	$if linux {
		$if vanilla_poll ? {
			check_streamed_expect_uploads_get_their_100(.poll)!
		}
	}
}

fn test_poll_unwatched_suspend_closed() ! {
	$if linux {
		$if vanilla_poll ? {
			check_unwatched_suspend_closed(.poll)!
		}
	}
}

fn test_poll_streamed_upload_under_timeouts() ! {
	$if linux {
		$if vanilla_poll ? {
			check_streamed_upload_under_timeouts(.poll)!
		}
	}
}

fn test_poll_connect_storm_served() ! {
	$if linux {
		$if vanilla_poll ? {
			check_connect_storm_served(.poll, server.Limits{
				read_timeout_ms: 2000
			})!
			check_connect_storm_served(.poll, server.Limits{
				idle_timeout_ms: 2000
			})!
		}
	}
}

fn test_poll_reaped_under_gc_signals() ! {
	$if linux {
		$if vanilla_poll ? {
			check_reaped_under_gc_signals(.poll)!
		}
	}
}

// check_poll_stalled_expect_upload_408: the stalled-upload 408 when the head
// also asks for 100-continue and comes in one write with body bytes. The first
// read fills the read buffer, so the interim 100 is queued and the drain
// starts in the same burst, before any flush. That unsent 100 belongs to the
// upload itself, not to an earlier request: the 408 replaces it along with the
// held reply. With a GET pipelined ahead, its reply is owed first: silent.
fn check_poll_stalled_expect_upload_408(backend server.IOBackend) ! {
	upload := et_concat('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${et_upload_body_len}\r\nExpect: 100-continue\r\n\r\n'.bytes(),
		[]u8{len: et_upload_chunk_len, init: u8(0x61)})
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         et_handler
		limits:          server.Limits{
			read_timeout_ms: 500
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: upload
					want: 0
				},
			]
			then_eof: true
		},
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: et_concat(et_req, upload)
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: the stalled upload must be reaped'
	assert c.raw.bytestr().starts_with('HTTP/1.1 408'), '${backend}: a stalled Expect: 100-continue upload must get its 408, got ${c.raw.len} bytes: ${c.raw.bytestr()}'
	assert !c.raw.bytestr().contains('uploaded'), '${backend}: the held reply went out for an incomplete upload'
	behind := out.conns[1]
	assert behind.connect_err == '', behind.connect_err
	assert behind.eof, '${backend}: the stalled upload must be reaped'
	assert behind.raw.len == 0, '${backend}: a 408 ahead of the reply owed to the pipelined GET: ${behind.raw.bytestr()}'
	assert out.active_after == 0
}

fn test_poll_stalled_expect_upload_408() ! {
	$if linux {
		$if vanilla_poll ? {
			check_poll_stalled_expect_upload_408(.poll)!
		}
	}
}
