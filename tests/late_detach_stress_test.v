// vtest build: linux
// Stress companion to late_detach_test.v (vanilla#337), with NO forced
// interleaving: a /step request parks on a 1 ms timer whose continuation
// closes it and steps to an eventfd that is already readable (the shape of
// examples/async_multi_watch's after_a, and of PR #333's first on_backoff).
// Client threads open a new connection per request, half /step and half
// GET /, so the accept thread keeps handing out numbers while continuations
// close theirs. Before the fix about 0.1% of new connections (any of them,
// not only /step) were taken out of the worker's epoll by a late
// EPOLL_CTL_DEL and never answered.
//
// It runs only with LD_STRESS=1: its connection churn would compete with the
// timing-sensitive suites that `v test tests/` runs beside it, so CI runs it
// on its own (build_test_examples_on_linux.yml). A request with no answer
// within LD_TIMEOUT_S (default 5) counts as hung, and its server-side socket
// is inspected: still in the worker's epoll or not, request bytes unread or
// not. LD_STRESS_SECS (default 3) and LD_STRESS_CLIENTS (default 32) size the
// run; LD_KEEP_OPEN=1 is the control (the timer is closed one step later).
module main

import os
import core
import server
import sync.stdatomic
import time
import vtest

#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include "@VMODROOT/core/libc_shim.h"

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.eventfd(initval u32, flags int) int
fn C.vanilla_read(fd int, buf voidptr, count u64) int
fn C.close(fd int) int
fn C.socket(domain int, typ int, protocol int) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.vanilla_send(fd int, buf voidptr, n u64, flags int) int
fn C.vanilla_recv(fd int, buf voidptr, n u64, flags int) int
fn C.setsockopt(fd int, level int, opt int, val voidptr, len u32) int
fn C.getsockname(fd int, addr voidptr, len &u32) int
fn C.getpeername(fd int, addr voidptr, len &u32) int
fn C.ioctl(fd int, req u64, arg voidptr) int

const ok_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
const stepped_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\nstepped'

struct Counts {
mut:
	done     i64
	hung     i64
	hung_get i64 // hung plain GET / (victims that never parked)
	errs     i64
	stop     i64
	loop_fd  i64 = -1
	// what the server-side socket of each hung request looks like
	diag_in_epoll  i64 // still registered in the worker epoll
	diag_not_epoll i64 // missing from it (DEL'd)
	diag_nofd      i64 // no server-side socket found
	diag_unread    i64 // request bytes still unread in the server socket
}

const cnt = &Counts{}

// keep_open (LD_KEEP_OPEN=1) is the control: the timer is closed one step
// later (in after_b), once the runtime is done with it.
const keep_open = os.getenv('LD_KEEP_OPEN') == '1'

// diagnose finds the server side of a hung client (same process: the socket
// whose peer is the client's local address) and checks the worker's epoll.
fn diagnose(client int) {
	mut a := [128]u8{}
	mut l := u32(128)
	C.getsockname(client, voidptr(&a[0]), &l)
	cport := (int(a[2]) << 8) | int(a[3])
	mut p := unsafe { cnt }
	ep := int(stdatomic.load_i64(&cnt.loop_fd))
	entries := os.ls('/proc/self/fd') or { return }
	for e in entries {
		fd := e.int()
		if fd == client {
			continue
		}
		mut b := [128]u8{}
		mut bl := u32(128)
		if C.getpeername(fd, voidptr(&b[0]), &bl) != 0 || bl < 4 {
			continue
		}
		if ((int(b[2]) << 8) | int(b[3])) != cport {
			continue
		}
		mut unread := i32(0)
		C.ioctl(fd, C.FIONREAD, &unread)
		if unread > 0 {
			stdatomic.add_i64(&p.diag_unread, 1)
		}
		info := os.read_file('/proc/self/fdinfo/${ep}') or { '' }
		mut found := false
		for line in info.split_into_lines() {
			f := line.fields()
			if f.len > 1 && f[0] == 'tfd:' && f[1].int() == fd {
				found = true
			}
		}
		if found {
			stdatomic.add_i64(&p.diag_in_epoll, 1)
		} else {
			stdatomic.add_i64(&p.diag_not_epoll, 1)
		}
		return
	}
	stdatomic.add_i64(&p.diag_nofd, 1)
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
	C.vanilla_read(fd, &tmp[0], 8)
}

fn handle(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.len > 9 && req[5] == `s` { // GET /step
		b := C.eventfd(1, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		a := one_shot_timer(1)
		event_loop.watch_fd(a, .readable, after_a, unsafe { voidptr(i64(b)) })
		return .suspend
	}
	core.append_str(mut out, ok_resp)
	return .done
}

fn after_a(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	mut pc := unsafe { cnt }
	stdatomic.store_i64(&pc.loop_fd, event_loop.loop_fd)
	mut keep := i64(-1)
	if keep_open {
		keep = i64(ready_fd)
	} else {
		C.close(ready_fd) // freed here, before the runtime detaches the number
	}
	event_loop.watch_fd(int(i64(watch_payload)), .readable, after_b, unsafe { voidptr(keep) })
	return .suspend
}

fn after_b(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	drain(ready_fd)
	C.close(ready_fd)
	keep := int(i64(watch_payload))
	if keep >= 0 {
		C.close(keep)
	}
	core.append_str(mut out, stepped_resp)
	return .done
}

fn one_request(port int, step bool, timeout_s i64) {
	fd := C.socket(C.AF_INET, C.SOCK_STREAM | C.SOCK_CLOEXEC, 0)
	mut t := [2]i64{}
	t[0] = timeout_s
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_RCVTIMEO, voidptr(&t[0]), 16)
	mut a := [16]u8{}
	unsafe {
		*(&u16(&a[0])) = u16(C.AF_INET)
	}
	a[2] = u8(port >> 8)
	a[3] = u8(port & 0xff)
	a[4] = 127
	a[7] = 1
	mut p := unsafe { cnt }
	if C.connect(fd, voidptr(&a[0]), 16) != 0 {
		stdatomic.add_i64(&p.errs, 1)
		C.close(fd)
		return
	}
	req := if step {
		'GET /step HTTP/1.1\r\nHost: x\r\n\r\n'
	} else {
		'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
	}
	for {
		if C.vanilla_send(fd, req.str, u64(req.len), C.MSG_NOSIGNAL) >= 0 || C.errno != C.EINTR {
			break
		}
	}
	want := if step { stepped_resp.len } else { ok_resp.len }
	mut buf := [128]u8{}
	mut got := 0
	// A socket call with SO_RCVTIMEO is not restarted after a signal (the GC's
	// stop-the-world ones): retry on EINTR, up to the overall deadline.
	deadline := time.sys_mono_now() + u64(timeout_s) * 1_000_000_000
	for got < want && time.sys_mono_now() < deadline {
		n := C.vanilla_recv(fd, unsafe { &buf[got] }, u64(128 - got), 0)
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		if n <= 0 {
			break
		}
		got += n
	}
	if got == want {
		stdatomic.add_i64(&p.done, 1)
	} else if got == 0 {
		diagnose(fd)
		stdatomic.add_i64(&p.hung, 1)
		if !step {
			stdatomic.add_i64(&p.hung_get, 1)
		}
	} else {
		stdatomic.add_i64(&p.errs, 1)
	}
	C.close(fd)
}

fn client(port int, id int, timeout_s i64) {
	mut i := 0
	for stdatomic.load_i64(&cnt.stop) == 0 {
		one_request(port, (i + id) % 2 == 0, timeout_s)
		i++
	}
}

fn test_epoll_stress_close_then_step_away() {
	if os.getenv('LD_STRESS') != '1' {
		eprintln('late_detach_stress_test: skipped, set LD_STRESS=1 to run it')
		return
	}
	secs := (os.getenv_opt('LD_STRESS_SECS') or { '3' }).int()
	nclients := (os.getenv_opt('LD_STRESS_CLIENTS') or { '32' }).int()
	timeout_s := (os.getenv_opt('LD_TIMEOUT_S') or { '5' }).i64()
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: .epoll
		workers:         1
		handler:         handle
	}) or { panic(err) }
	defer {
		h.stop()
	}
	mut ths := []thread{}
	for id in 0 .. nclients {
		ths << spawn client(h.port(), id, timeout_s)
	}
	time.sleep(secs * time.second)
	mut p := unsafe { cnt }
	stdatomic.store_i64(&p.stop, 1)
	ths.wait()
	eprintln('[stress ${secs}s, ${nclients} clients, 1 worker, keep_open=${keep_open}] answered=${cnt.done} hung=${cnt.hung} (plain GET / hung=${cnt.hung_get}) other_errors=${cnt.errs}; hung server sockets: in worker epoll=${cnt.diag_in_epoll} missing from it=${cnt.diag_not_epoll} not found=${cnt.diag_nofd} with unread request=${cnt.diag_unread}')
	assert cnt.done > 0, 'nothing was answered'
	assert cnt.hung == 0, '${cnt.hung} requests never answered'
}
