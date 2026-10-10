// vtest build: linux
module backend_epoll

import core

// Unit tests for the park-deadline heap (park_deadline_linux.c.v): the
// min-heap order, and the back-index every entry keeps in its connection
// (ConnState.park_timer), through arms, re-arms, cancels from the middle and
// pops. The e2e behaviour (what a timed-out park does) is
// tests/park_deadline_test.v.

fn pt_state(n int) PlainState {
	mut st := new_plain_state()
	for fd in 0 .. n {
		state_create(mut st, fd)
	}
	return st
}

fn pt_push(mut st PlainState, fd int, at u64) {
	t := ParkTimer{
		at: at
		fd: fd
	}
	st.timers << t
	st.timer_up(st.timers.len - 1, t)
}

// pt_ok: the heap order holds, and every entry's connection knows its slot.
fn pt_ok(st &PlainState) bool {
	for i, t in st.timers {
		if i > 0 && st.timers[(i - 1) / 2].at > t.at {
			return false
		}
		if st.conns[t.fd].park_timer != i {
			return false
		}
	}
	return true
}

fn test_heap_keeps_order_and_back_indexes() {
	mut st := pt_state(64)
	mut x := u64(12345)
	for fd in 0 .. 64 {
		x = x * 6364136223846793005 + 1442695040888963407 // an LCG: duplicates included
		pt_push(mut st, fd, (x >> 33) % 50)
		assert pt_ok(&st)
	}
	// Cancel every third connection: most sit in the middle of the heap.
	for fd := 0; fd < 64; fd += 3 {
		mut cs := st.conns[fd]
		st.cancel_park_timer(mut cs)
		assert cs.park_timer == -1
		assert pt_ok(&st)
	}
	assert st.timers.len == 64 - 22
	// Pop in deadline order, as fire_park_deadlines does.
	mut last := u64(0)
	for st.timers.len > 0 {
		t := st.timers[0]
		assert t.at >= last
		last = t.at
		st.conns[t.fd].park_timer = -1
		st.timer_remove(0)
		assert pt_ok(&st)
	}
	for fd in 0 .. 64 {
		assert st.conns[fd].park_timer == -1
	}
}

fn test_arm_resolves_the_deadline() {
	mut st := pt_state(4)
	mut cs := st.conns[1]
	// No default and none of its own: nothing armed.
	st.arm_park_timer(mut cs, 1, 0)
	assert st.timers.len == 0 && cs.park_timer == -1
	// Its own.
	st.arm_park_timer(mut cs, 1, 50)
	assert st.timers.len == 1 && cs.park_timer == 0
	first := st.timers[0].at
	// Re-armed: moved, never duplicated.
	st.arm_park_timer(mut cs, 1, 5000)
	assert st.timers.len == 1 && st.timers[0].at > first
	// 0 takes Limits.park_timeout_ms; a negative timeout exempts the park.
	st.park_ns = 100 * 1_000_000
	mut cs2 := st.conns[2]
	st.arm_park_timer(mut cs2, 2, 0)
	assert st.timers.len == 2 && cs2.park_timer >= 0
	assert pt_ok(&st)
	assert st.timers[0].fd == 2 // 100 ms is due before 5000 ms
	st.arm_park_timer(mut cs2, 2, -1)
	assert st.timers.len == 1 && cs2.park_timer == -1
	assert pt_ok(&st)
}

// park_conn arms the deadline with the park, unpark_conn cancels it with the
// resume, and the in-flight count moves with them; with no deadline anywhere
// a park touches no heap.
fn test_park_and_unpark_arm_and_cancel() {
	mut st := pt_state(8)
	st.inflight = &core.Counter{}
	mut cs := st.conns[3]
	park_conn(mut st, mut cs, 3, 7, 0)
	assert cs.awaiting_fd == 7 && cs.park_timer == -1 && st.timers.len == 0
	assert st.inflight.n == 1
	unpark_conn(mut st, mut cs)
	assert cs.awaiting_fd == -1 && st.inflight.n == 0
	park_conn(mut st, mut cs, 3, 7, 200)
	assert cs.park_timer == 0 && st.timers.len == 1 && st.timers[0].fd == 3
	unpark_conn(mut st, mut cs)
	assert cs.park_timer == -1 && st.timers.len == 0 && st.inflight.n == 0
	// With Limits.park_timeout_ms, every park has one. Two parks, one resumes:
	// the other's entry stays, re-indexed.
	st.park_ns = 50 * 1_000_000
	mut cs5 := st.conns[5]
	park_conn(mut st, mut cs, 3, 7, 0)
	park_conn(mut st, mut cs5, 5, 7, 0)
	assert st.timers.len == 2 && pt_ok(&st)
	unpark_conn(mut st, mut cs)
	assert st.timers.len == 1 && st.timers[0].fd == 5 && cs5.park_timer == 0
}
