module backend_epoll

// The per-worker mailbox (vanilla#230): how any thread posts to a connection an
// epoll worker owns (core.ConnHandle.post_wake / post_bytes) without touching
// the connection, and how Server.shutdown() tells the worker to deliver
// .shutdown. Every epoll worker has one; its ring is opt-in,
// ServerConfig.push_mailbox_slots (0 = off: no ring, posts report
// .unsupported, and the eventfd is made only when the worker's first
// connection subscribes, so a server that never subscribes pays nothing).
//
// A bounded multi-producer, single-consumer ring, preallocated when the
// server is built (new_mailbox) and never freed (handles may outlive the
// server), plus an eventfd in the worker's epoll. Producers claim a ticket
// with a CAS on `tail` and publish their slot with its sequence number
// (Dmitry Vyukov's bounded queue): a slot is free for ticket `pos` while its
// seq is `pos`, and holds a message for the worker once seq is `pos + 1`; the
// worker frees it by storing `pos + slots`. A producer that finds the slot of
// its ticket still holding last lap's message reports .full: it never waits.
// The payload is copied into the slot inline (mailbox_inline bytes), so a post
// allocates nothing; bigger data stays in the application's store, the post
// carries its tag.
//
// The wake-up is the BirthQueue handshake, announced before EVERY wait that
// may block (not only the unbounded one: a post must not sit out a sweep
// interval or a park deadline): the worker stores `sleeping` and then looks at
// the slot it reads next; a producer publishes its slot and then looks at
// `sleeping`. Both seq_cst, so at least one sees the other: either the worker
// does not block, or the producer writes the eventfd. Only the producer whose
// CAS takes `sleeping` from 1 to 0 writes it, so a burst of posts to a
// sleeping worker costs one write(2). A hot worker (wait 0) announces nothing
// and pays one atomic load per loop iteration to look at the ring.
//
// Shutdown is a handshake on `state` (sig_*). The worker arms its mailbox
// (eventfd in its epoll, idle -> armed) at start when posts are on, else at
// its first subscription. Server.shutdown() moves an armed mailbox to
// signalled and holds one in-flight count, which the worker gives back once
// it has delivered .shutdown; an idle one (nothing subscribed there yet, or
// the worker never ran) goes to early, and shutdown waits for nothing. A
// worker that arms after that finds early and wakes itself: what subscribed
// on it during the drain gets .shutdown too. So does a connection that
// subscribes after its worker delivered .shutdown (subscribe_conn queues it
// and writes the eventfd).
//
// Every atomic here is sync.stdatomic's (C11, seq_cst) or the C11 CAS it
// declares; the slot's plain fields are published by the seq store and read
// after the seq load, and wake_fd, written before the arming CAS, is read
// after it, which ThreadSanitizer models.
import core
import epoll
import sync.stdatomic

#include "@VMODROOT/core/libc_shim.h"

fn C.vanilla_write(fd int, buf voidptr, count u64) int

// mailbox_inline is the payload a mailbox slot carries inline: post_bytes with
// more reports .too_big.
pub const mailbox_inline = 240

// mailbox_drain_max bounds how many messages one loop iteration delivers, so
// a flood of posts cannot starve the worker's I/O.
const mailbox_drain_max = 1024

// Mailbox.state, the shutdown handshake (see the top of this file).
const sig_idle = u64(0) // not armed: Server.shutdown() has nothing to wait for
const sig_armed = u64(1) // the eventfd is in the worker's epoll: shutdown signals it
const sig_early = u64(2) // shutdown came while idle: no count is owed
const sig_signalled = u64(3) // shutdown signalled an armed worker: it owes one in-flight count

struct MailSlot {
mut:
	seq   u64 // the Vyukov sequence (see above)
	epoch u64
	tag   u64
	fd    int
	len   int
	data  [mailbox_inline]u8
}

// Mailbox is one worker's ring. The fields producers and the worker
// both write each sit on their own cache line.
@[heap]
struct Mailbox {
mut:
	head     u64 // the next ticket the worker reads (the worker only)
	pad0     [56]u8
	tail     u64 // the next ticket a producer claims (CAS)
	pad1     [56]u8
	sleeping u64 // 1: the worker announced a wait (the worker sets it; a producer CASes it to 0)
	pad2     [56]u8
	state    u64 // the shutdown handshake: sig_idle, sig_armed, sig_early or sig_signalled
	pad3     [56]u8
	// Counters (push_stats): posted and full by producers, delivered and stale
	// by the worker; all atomic.
	posted    u64
	full      u64
	delivered u64
	stale     u64
	wake_fd   int = -1 // an eventfd in the worker's epoll (-1 until arm makes it: posts off)
	mask      u64
	slots     []MailSlot // empty: posts are off
}

// new_mailbox builds a worker's mailbox. With `slots` > 0 it has a ring of at
// least that many slots (rounded up to a power of two, at least 2) and its
// eventfd; with 0 it has neither, only the shutdown handshake (arm makes the
// eventfd). Called once per worker when the server is built; never freed.
pub fn new_mailbox(slots int) voidptr {
	if slots <= 0 {
		return voidptr(&Mailbox{})
	}
	mut n := 2
	for n < slots {
		n *= 2
	}
	mut m := &Mailbox{
		wake_fd: C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		mask:    u64(n - 1)
		slots:   []MailSlot{len: n}
	}
	if m.wake_fd < 0 {
		C.perror(c'eventfd')
		exit(1)
	}
	for i in 0 .. n {
		m.slots[i].seq = u64(i)
	}
	return voidptr(m)
}

// arm puts the mailbox's eventfd (made here when posts are off) in the
// worker's epoll, so Server.shutdown() signals this worker (the worker only,
// once). False when the eventfd cannot be made or added: the worker then gets
// no .shutdown. If shutdown came first (sig_early), the worker writes its own
// eventfd: its next wake delivers .shutdown to what has subscribed since.
fn (mut m Mailbox) arm(epoll_fd int) bool {
	if m.wake_fd < 0 {
		m.wake_fd = C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		if m.wake_fd < 0 {
			return false
		}
	}
	if epoll.add_fd_to_epoll(epoll_fd, m.wake_fd, u32(C.EPOLLIN) | u32(C.EPOLLET)) < 0 {
		return false
	}
	mut was := sig_idle
	if !C.atomic_compare_exchange_strong_u64(voidptr(&m.state), &was, sig_armed) {
		one := u64(1)
		C.vanilla_write(m.wake_fd, &one, 8)
	}
	return true
}

// mailbox_post is core.PostFn for the epoll worker: enqueue, never
// block, from any thread.
fn mailbox_post(mbox voidptr, fd int, epoch u64, tag u64, data []u8) core.PostResult {
	mut m := unsafe { &Mailbox(mbox) }
	if data.len > mailbox_inline {
		return .too_big
	}
	mut pos := stdatomic.load_u64(&m.tail)
	for {
		mut slot := unsafe { &m.slots[int(pos & m.mask)] }
		seq := stdatomic.load_u64(&slot.seq)
		if seq == pos {
			mut expected := pos
			if C.atomic_compare_exchange_weak_u64(voidptr(&m.tail), &expected, pos + 1) {
				slot.fd = fd
				slot.epoch = epoch
				slot.tag = tag
				slot.len = data.len
				if data.len > 0 {
					unsafe { vmemcpy(&slot.data[0], data.data, data.len) }
				}
				stdatomic.store_u64(&slot.seq, pos + 1) // publish
				stdatomic.add_u64(&m.posted, 1)
				if stdatomic.load_u64(&m.sleeping) != 0 {
					mut was := u64(1)
					if C.atomic_compare_exchange_strong_u64(voidptr(&m.sleeping), &was, 0) {
						one := u64(1)
						C.vanilla_write(m.wake_fd, &one, 8)
					}
				}
				return .ok
			}
			pos = expected // another producer took the ticket: try the current tail
		} else if seq < pos {
			// The slot still holds the message of the previous lap: full.
			stdatomic.add_u64(&m.full, 1)
			return .full
		} else {
			pos = stdatomic.load_u64(&m.tail) // claimed meanwhile: catch up
		}
	}
	return .full
}

// ready reports whether the next message is published (the worker only).
@[inline]
fn (m &Mailbox) ready() bool {
	return stdatomic.load_u64(unsafe { &m.slots[int(m.head & m.mask)].seq }) == m.head + 1
}

// announce is the worker's last look before a wait that may block: it
// announces the wait, then re-checks the ring. True: a message is ready (the
// announcement is withdrawn), so do not block.
@[inline]
fn (mut m Mailbox) announce() bool {
	stdatomic.store_u64(&m.sleeping, 1)
	if m.ready() {
		stdatomic.store_u64(&m.sleeping, 0)
		return true
	}
	return false
}

// mailbox_signal_shutdown tells the worker that owns `mbox` that
// Server.shutdown() was called (once; a second call does nothing). An armed
// worker gets one count of its in-flight counter, which it gives back once it
// has delivered .shutdown to its subscribed connections (deliver_shutdown):
// the shutdown drain then waits for those goodbyes, and no longer. An idle
// one (nothing subscribed there, or the worker never ran) holds nothing.
pub fn mailbox_signal_shutdown(mbox voidptr, inflight &core.Counter) {
	mut m := unsafe { &Mailbox(mbox) }
	stdatomic.add_i64(&inflight.n, 1) // before the signal: the worker may act on it at once
	for {
		mut was := stdatomic.load_u64(&m.state)
		if was == sig_armed {
			if C.atomic_compare_exchange_strong_u64(voidptr(&m.state), &was, sig_signalled) {
				one := u64(1)
				C.vanilla_write(m.wake_fd, &one, 8)
				return
			}
			continue
		}
		if was == sig_idle
			&& !C.atomic_compare_exchange_strong_u64(voidptr(&m.state), &was, sig_early) {
			continue // armed meanwhile
		}
		stdatomic.add_i64(&inflight.n, -1) // idle, or signalled already: nothing to wait for
		return
	}
}

// mailbox_counters reads a mailbox's counters: posted, full, delivered,
// stale (a post whose connection was gone, or no longer subscribed).
pub fn mailbox_counters(mbox voidptr) (u64, u64, u64, u64) {
	m := unsafe { &Mailbox(mbox) }
	return stdatomic.load_u64(&m.posted), stdatomic.load_u64(&m.full), stdatomic.load_u64(&m.delivered), stdatomic.load_u64(&m.stale)
}
