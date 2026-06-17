module backend_epoll

import http_server.core

// Unit tests for the cross-request pipelining reactor primitives (Option B):
// auto-promotion of a single watch into a per-fd FIFO when a SECOND client parks
// on the same multiplexed fd, FIFO append order, re-arm idempotency (the front
// continuation asking for more bytes must not duplicate its slot), and the dead
// tombstone (a client that disconnected mid-pipeline keeps its slot so the queue
// stays aligned with the connection's in-flight FIFO). These are the subtle
// data-structure invariants the drain loop relies on; the end-to-end drain itself
// is exercised by the async-db pipelining benchmark (real Postgres + concurrent
// load), since the test harness is single-connection and the epoll backend runs
// one worker per core (concurrent parks can't be co-located in a unit test).

fn noop_cont(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	return .done
}

fn other_cont(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	return .suspend
}

// A single watch stays on the fast path: the flat WatchEntry fields drive it and
// no queue is allocated.
fn test_single_watch_no_queue() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	assert r.watches[10].active
	assert r.watches[10].client_fd == 100
	assert r.watches[10].queue.len == 0
}

// A second, distinct client on an active fd promotes it to a queue, moving the
// existing head into queue[0] and appending the newcomer in submission order.
fn test_second_client_promotes_to_queue() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	r.reactor_watch(10, 200, noop_cont, voidptr(usize(2)))
	assert r.watches[10].active
	assert r.watches[10].queue.len == 2
	assert r.watches[10].queue[0].client_fd == 100 // original head first (FIFO)
	assert r.watches[10].queue[1].client_fd == 200
	assert r.watches[10].queue[0].udata == voidptr(usize(1))
	assert r.watches[10].queue[1].udata == voidptr(usize(2))
}

// Further parks append at the tail, preserving submission order.
fn test_third_client_appends_fifo() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	r.reactor_watch(10, 200, noop_cont, voidptr(usize(2)))
	r.reactor_watch(10, 300, noop_cont, voidptr(usize(3)))
	assert r.watches[10].queue.len == 3
	assert r.watches[10].queue[0].client_fd == 100
	assert r.watches[10].queue[1].client_fd == 200
	assert r.watches[10].queue[2].client_fd == 300
}

// Re-arming an ALREADY-queued client (the front continuation that needs more
// bytes) updates its slot in place — never a duplicate append.
fn test_rearm_is_idempotent() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	r.reactor_watch(10, 200, noop_cont, voidptr(usize(2)))
	// Front (100) re-arms with fresh udata.
	r.reactor_watch(10, 100, other_cont, voidptr(usize(9)))
	assert r.watches[10].queue.len == 2 // no duplicate
	assert r.watches[10].queue[0].client_fd == 100
	assert r.watches[10].queue[0].udata == voidptr(usize(9)) // updated in place
	assert r.watches[10].queue[1].client_fd == 200
}

// Re-arming a single (un-promoted) watch by the same client updates in place and
// does NOT promote to a queue.
fn test_single_rearm_stays_single() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	r.reactor_watch(10, 100, other_cont, voidptr(usize(7)))
	assert r.watches[10].queue.len == 0
	assert r.watches[10].client_fd == 100
	assert r.watches[10].udata == voidptr(usize(7))
}

// A disconnected client is tombstoned in place: its slot survives (alignment with
// the connection's in-flight FIFO) but is marked dead; siblings are untouched.
fn test_mark_dead_tombstones_slot() {
	mut r := AsyncReactor{}
	r.reactor_watch(10, 100, noop_cont, voidptr(usize(1)))
	r.reactor_watch(10, 200, noop_cont, voidptr(usize(2)))
	r.reactor_watch(10, 300, noop_cont, voidptr(usize(3)))
	r.reactor_mark_dead(10, 200)
	assert r.watches[10].queue.len == 3 // slot kept, not removed
	assert !r.watches[10].queue[0].dead
	assert r.watches[10].queue[1].dead
	assert !r.watches[10].queue[2].dead
	// Marking an absent client is a no-op (no panic, nothing flipped).
	r.reactor_mark_dead(10, 999)
	assert !r.watches[10].queue[0].dead
	assert r.watches[10].queue[1].dead
	assert !r.watches[10].queue[2].dead
}

// The flat table grows by doubling for a high fd, like the connection table.
fn test_table_grows_for_high_fd() {
	mut r := AsyncReactor{}
	r.reactor_watch(5000, 100, noop_cont, voidptr(usize(1)))
	assert r.watches.len > 5000
	assert r.watches[5000].active
	assert r.watches[5000].client_fd == 100
}
