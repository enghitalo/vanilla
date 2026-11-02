// vtest build: linux
module backend_epoll

import core
import epoll
import os
import strconv

#include <sys/socket.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.dup2(oldfd int, newfd int) int

// Unit tests for the watch slot that outlives its fd (#342): the app closed
// the fd under the watch, and the kernel gives the number to another file.
// Each registration that can put that file in the worker's epoll retires
// the slot first: a watch (register_watch), a tombstone run's step to a
// pooled fd (register_dead_watch), and the mailbox's eventfd (subscribe_conn,
// posts off). tests/stale_watch_slot_test.v covers a connection the accept
// thread registers under the number, end to end.

fn old_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	return .done
}

fn new_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	return .suspend
}

fn taken_over(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	return 0, .done
}

// registered_events is fd's event mask in the epoll set ep, as the kernel
// reports it (/proc/self/fdinfo); 0 when fd is not in the set.
fn registered_events(ep int, fd int) u32 {
	info := os.read_file('/proc/self/fdinfo/${ep}') or { return 0 }
	for line in info.split_into_lines() {
		f := line.fields()
		if f.len >= 4 && f[0] == 'tfd:' && f[1] == fd.str() && f[2] == 'events:' {
			return u32(strconv.parse_uint(f[3], 16, 32) or { 0 })
		}
	}
	return 0
}

fn socket_pair() (int, int) {
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM | C.SOCK_CLOEXEC, 0, &sv[0]) == 0
	return int(sv[0]), int(sv[1])
}

// new_worker_state is a worker's connection table with its counters, one
// connection open (the one stale_slot parks).
fn new_worker_state() PlainState {
	mut st := new_plain_state()
	st.inflight = &core.Counter{}
	st.active_conns = &core.Counter{
		n: 1
	}
	return st
}

// stale_slot arms a persistent watch on p for connection c, parks c there,
// queues a tombstone behind it (client number d, gone), then closes p as
// the app does and puts another file under its number. Returns c's state.
fn stale_slot(mut r Reactor, mut st PlainState, ep int, p int, c int, d int) &ConnState {
	mut w := core.EventLoop{
		client_fd: c
		loop_fd:   ep
		reactor:   unsafe { voidptr(&r) }
		register:  register_watch
	}
	w.watch_fd_persistent(p, .readable, old_cont, voidptr(u64(1)))
	assert w.last_watched == p
	mut cs := state_create(mut st, c)
	park_conn(mut st, mut cs, c, p, -1)
	r.reactor_watch(p, d, old_cont, voidptr(u64(2)))
	r.reactor_mark_dead(p, d)
	assert r.watches[p].queue.len == 2 && r.watches[p].queue[1].dead
	other, other_peer := socket_pair() // before the close, so that it does not take p
	C.close(p)
	assert C.dup2(other, p) == p
	C.close(other)
	C.close(other_peer)
	assert registered_events(ep, p) == 0 // the closed file left the set
	return cs
}

// eof reports whether the peer of a closed connection reads end of file.
fn eof(peer int) bool {
	mut b := [1]u8{}
	return C.vanilla_recv(peer, &b[0], 1, 0) == 0
}

// A watch on the new file under the number: the old slot goes (its
// tombstone never runs, and the request parked on the closed fd is closed),
// and the watch is the fd's only one, armed in the set. Before, it was
// queued behind the old entries, whose continuations ran on its readiness.
fn test_watch_on_the_number_of_a_closed_watch_fd_retires_its_slot() {
	ep := epoll.create_epoll_fd()
	p, p_peer := socket_pair()
	c, c_peer := socket_pair()
	defer {
		C.close(p)
		C.close(p_peer)
		C.close(c_peer)
		C.close(ep)
	}
	mut st := new_worker_state()
	mut r := Reactor{
		st: unsafe { &st }
	}
	st.reactor = unsafe { &r }
	stale_slot(mut r, mut st, ep, p, c, c + 1000)
	mut w := core.EventLoop{
		client_fd: c + 2000 // another request
		loop_fd:   ep
		reactor:   unsafe { voidptr(&r) }
		register:  register_watch
	}
	w.watch_fd_persistent(p, .readable, new_cont, voidptr(u64(3)))
	assert w.last_watched == p
	assert r.watches[p].active && r.watches[p].queue.len == 0
	assert r.watches[p].client_fd == c + 2000 && r.watches[p].udata == voidptr(u64(3))
	assert r.watches[p].persistent
	assert registered_events(ep, p) != 0
	assert unsafe { st.conns[c] == nil }, 'the request parked on the closed fd was not closed'
	assert eof(c_peer)
	assert st.inflight.n == 0 && st.active_conns.n == 0
}

// The same watch from the continuation of a request that waits on that slot
// (here c's, as drain_pipelined runs it: unparked, its slot in place) is the
// run's own re-arm: the slot stays as it was, c's entry updated in place, as
// before #342 (its caller reads the slot again once it returns).
fn test_rearm_by_a_run_of_the_slot_keeps_it() {
	ep := epoll.create_epoll_fd()
	p, p_peer := socket_pair()
	c, c_peer := socket_pair()
	defer {
		C.close(p)
		C.close(p_peer)
		C.close(c)
		C.close(c_peer)
		C.close(ep)
	}
	mut st := new_worker_state()
	mut r := Reactor{
		st: unsafe { &st }
	}
	st.reactor = unsafe { &r }
	mut cs := stale_slot(mut r, mut st, ep, p, c, c + 1000)
	unpark_conn(mut st, mut cs)
	mut w := core.EventLoop{
		client_fd: c
		loop_fd:   ep
		reactor:   unsafe { voidptr(&r) }
		register:  register_watch
	}
	w.watch_fd_persistent(p, .readable, new_cont, voidptr(u64(3)))
	assert w.last_watched == p
	assert r.watches[p].active && r.watches[p].queue.len == 2
	assert r.watches[p].queue[0].client_fd == c && r.watches[p].queue[0].udata == voidptr(u64(3))
	assert r.watches[p].queue[1].dead
	assert unsafe { st.conns[c] != nil }
}

// A tombstone's run that steps to a pooled fd now under the closed fd's
// number: the old slot goes, and the step's dead slot is the fd's only one.
fn test_tombstone_step_to_the_number_of_a_closed_watch_fd_retires_its_slot() {
	ep := epoll.create_epoll_fd()
	p, p_peer := socket_pair()
	c, c_peer := socket_pair()
	defer {
		C.close(p)
		C.close(p_peer)
		C.close(c_peer)
		C.close(ep)
	}
	mut st := new_worker_state()
	mut r := Reactor{
		st: unsafe { &st }
	}
	st.reactor = unsafe { &r }
	stale_slot(mut r, mut st, ep, p, c, c + 1000)
	gone := c + 3000 // the tombstone's client, which left
	r.rearming_dead = true
	r.dead_fd = c + 4000 // the fd the tombstone drains
	mut w := core.EventLoop{
		client_fd: gone
		loop_fd:   ep
		reactor:   unsafe { voidptr(&r) }
		register:  register_watch
	}
	w.watch_fd_persistent(p, .readable, new_cont, voidptr(u64(4)))
	assert w.last_watched == p && !r.dead_refused
	assert r.watches[p].active && r.watches[p].queue.len == 1
	assert r.watches[p].queue[0].dead && r.watches[p].queue[0].client_fd == gone
	assert r.watches[p].queue[0].udata == voidptr(u64(4))
	assert registered_events(ep, p) != 0
	assert unsafe { st.conns[c] == nil }, 'the request parked on the closed fd was not closed'
	assert eof(c_peer)
}

// With posts off, a worker's first subscription makes the mailbox's eventfd,
// which takes the lowest free number: here a watch fd's, closed under its
// slot. The slot goes, or it would get the mailbox's wakes (Server.shutdown's
// signal).
fn test_mailbox_eventfd_on_the_number_of_a_closed_watch_fd_retires_its_slot() {
	ep := epoll.create_epoll_fd()
	t, t_peer := socket_pair()
	mut st := new_worker_state()
	st.mbox = unsafe { &Mailbox(new_mailbox(0)) }
	mut r := Reactor{
		st: unsafe { &st }
	}
	st.reactor = unsafe { &r }
	defer {
		C.close(t)
		C.close(t_peer)
		if st.mbox.wake_fd >= 0 {
			C.close(st.mbox.wake_fd)
		}
		C.close(ep)
	}
	// A clientless watch on an eventfd, which the app closes: its number is
	// the lowest free one again.
	l := C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
	mut bg := core.EventLoop{
		loop_fd:  ep
		reactor:  unsafe { voidptr(&r) }
		register: register_watch
	}
	bg.watch_fd(l, .readable, old_cont, unsafe { nil })
	assert bg.last_watched == l
	C.close(l)
	mut cs := state_create(mut st, t)
	cs.takeover = taken_over
	mut el := core.EventLoop{
		client_fd: t
		loop_fd:   ep
		reactor:   unsafe { voidptr(&r) }
		register:  register_watch
	}
	subscribe_conn(mut el, new_cont, unsafe { nil })
	assert st.mbox_armed
	if st.mbox.wake_fd != l {
		eprintln('skipped: the mailbox eventfd got ${st.mbox.wake_fd}, not the freed number ${l}')
		return
	}
	assert !r.watches[l].active, "the closed watch fd's slot would get the mailbox's wakes"
}
