// vtest build: linux
module backend_epoll

import core
import epoll

// Unit tests for the push mailbox ring (mailbox_linux.c.v): the size rounding,
// .full without blocking, .too_big, FIFO order across many laps, the sleep
// announcement's re-check, and the shutdown handshake. Delivery to
// connections and producer threads are tests/conn_push_test.v.

// mb_take is the worker's side, as drain_mailbox does it: the next message's
// tag and first data byte, then the slot is freed.
fn mb_take(mut m Mailbox) ?(u64, int) {
	if !m.ready() {
		return none
	}
	pos := m.head
	slot := unsafe { &m.slots[int(pos & m.mask)] }
	tag := slot.tag
	first := if slot.len > 0 { int(slot.data[0]) } else { -1 }
	unsafe {
		slot.seq = pos + m.mask + 1
	}
	m.head = pos + 1
	return tag, first
}

fn test_mailbox_rounds_up_and_reports_full() {
	mut m := unsafe { &Mailbox(new_mailbox(3)) }
	assert m.slots.len == 4
	for i in 0 .. 4 {
		assert mailbox_post(voidptr(m), 5, 1, u64(i), []u8{}) == .ok
	}
	assert mailbox_post(voidptr(m), 5, 1, 99, []u8{}) == .full
	tag, _ := mb_take(mut m) or { panic('empty') }
	assert tag == 0
	assert mailbox_post(voidptr(m), 5, 1, 4, []u8{}) == .ok // a slot came back
	posted, full, _, _ := mailbox_counters(voidptr(m))
	assert posted == 5 && full == 1
	assert mailbox_post(voidptr(m), 5, 1, 0, []u8{len: mailbox_inline + 1}) == .too_big
	assert mailbox_post(voidptr(m), 5, 1, 0, []u8{len: mailbox_inline}) == .full // fits, but no room
}

fn test_mailbox_keeps_fifo_order_over_many_laps() {
	mut m := unsafe { &Mailbox(new_mailbox(8)) }
	mut next := u64(0)
	mut want := u64(0)
	for round in 0 .. 1000 {
		for _ in 0 .. 1 + round % 8 {
			b := [u8(next & 0xff)]
			if mailbox_post(voidptr(m), 1, 2, next, b[..]) == .ok {
				next++
			}
		}
		for _ in 0 .. round % 5 {
			tag, first := mb_take(mut m) or { break }
			assert tag == want
			assert first == int(want & 0xff)
			want++
		}
	}
	for {
		tag, _ := mb_take(mut m) or { break }
		assert tag == want
		want++
	}
	assert want == next
}

fn test_mailbox_announce_sees_a_ready_post() {
	mut m := unsafe { &Mailbox(new_mailbox(2)) }
	assert !m.announce() // nothing posted: the worker may block
	assert m.sleeping == 1
	assert mailbox_post(voidptr(m), 1, 0, 7, []u8{}) == .ok // takes the announcement, writes the eventfd
	assert m.sleeping == 0
	assert m.announce() // a post is ready: do not block
	assert m.sleeping == 0
	tag, _ := mb_take(mut m) or { panic('empty') }
	assert tag == 7
	// A nil handle and a handle without a mailbox post nothing.
	assert core.ConnHandle{}.post_wake(1) == .unsupported
	assert core.ConnHandle{
		fd: 3
	}.post_bytes(1, [u8(1)]) == .unsupported
}

// mb_eventfd_count reads (and resets) an eventfd: 0 when nothing was written.
fn mb_eventfd_count(fd int) u64 {
	mut n := u64(0)
	if C.read(fd, &n, 8) != 8 {
		return 0
	}
	return n
}

// The shutdown handshake. A mailbox with no ring has no eventfd until it is
// armed. Server.shutdown() on an idle one (nothing subscribed on its worker,
// or the worker never ran) holds no in-flight count, and the worker that arms
// it afterwards wakes itself. On an armed one it holds one count (the worker
// gives it back after delivering .shutdown) and writes the eventfd, once.
fn test_mailbox_shutdown_handshake() {
	efd := epoll.create_epoll_fd()
	assert efd >= 0
	defer {
		C.close(efd)
	}
	mut inflight := &core.Counter{}
	// Idle, then armed late.
	mut idle := unsafe { &Mailbox(new_mailbox(0)) }
	assert idle.slots.len == 0 && idle.wake_fd == -1
	mailbox_signal_shutdown(voidptr(idle), inflight)
	assert idle.state == sig_early
	assert inflight.n == 0, 'shutdown waits for a worker with nothing to tell'
	idle_armed := idle.arm(efd)
	assert idle_armed
	assert idle.wake_fd >= 0
	assert idle.state == sig_early
	assert mb_eventfd_count(idle.wake_fd) == 1, 'a late arm must wake its own worker'
	// Armed, then signalled (twice).
	mut armed := unsafe { &Mailbox(new_mailbox(0)) }
	armed_ok := armed.arm(efd)
	assert armed_ok
	assert armed.state == sig_armed
	assert mb_eventfd_count(armed.wake_fd) == 0
	mailbox_signal_shutdown(voidptr(armed), inflight)
	assert armed.state == sig_signalled
	assert inflight.n == 1, 'the armed worker owes one count'
	mailbox_signal_shutdown(voidptr(armed), inflight)
	assert inflight.n == 1, 'a second shutdown takes nothing more'
	assert mb_eventfd_count(armed.wake_fd) == 1
	C.close(idle.wake_fd)
	C.close(armed.wake_fd)
}
