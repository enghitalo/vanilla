module main

// Shipping to a collector: each worker keeps a bounded queue of NDJSON lines
// and POSTs it in batches through its own http1_1.upstream pool, one batch
// in flight at a time. The batch is driven by clientless watches on the
// worker's loop (the tick sends it, on_ship advances it), so the request path
// never sees the collector: a slow or dead one fills the queue, and what does
// not fit is dropped and counted. The file stays the source of truth;
// the collector gets each line at least once while it keeps up (a batch that
// timed out after the collector took it is sent again).
import core
import time
import http1_1.upstream

const ndjson = 'application/x-ndjson'.bytes()
const max_backoff_ms = 30_000

// Shipper is one worker's link to the collector.
struct Shipper {
mut:
	pool       &upstream.Pool = unsafe { nil } // nil: no collector
	q          []u8 // whole lines waiting for the collector; never grown past its cap
	x          &upstream.Exchange = unsafe { nil } // the batch in flight
	sent       int  // bytes at the head of q that batch carries
	done       bool // on_ship saw the batch end: the next tick releases it
	status     int  // the collector's status for it (0: no answer)
	backoff_ms int
	retry_at   u64 // monotonic ns: no batch before this (after a failure)
}

// enqueue copies the flushed buffer (whole lines) into the queue. What does
// not fit, when the collector is slow or down, is dropped and counted.
fn (mut w Worker) enqueue() {
	room := w.ship.q.cap - w.ship.q.len
	mut n := w.buf.len
	if n > room {
		n = last_line_end(w.buf, room)
		w.counts.ship_dropped += count_lines(w.buf, n, w.buf.len)
	}
	if n > 0 {
		unsafe { w.ship.q.push_many(w.buf.data, n) }
	}
}

// send_batch runs on the tick: it hands back a finished batch (accounting for
// it), then sends the next one if the queue has lines and no backoff is
// running. Nothing here blocks: send() starts a non-blocking connect or write
// and parks the pool's socket on this worker's loop, and on_ship carries the
// batch to its end.
fn (mut w Worker) send_batch(mut el core.EventLoop) {
	if w.ship.pool == unsafe { nil } {
		return
	}
	now := time.sys_mono_now()
	if w.ship.done {
		w.ship.x.release()
		w.ship.x = unsafe { nil }
		w.ship.done = false
		w.settle(now)
	}
	if w.ship.x != unsafe { nil } || w.ship.q.len == 0 || now < w.ship.retry_at {
		return
	}
	mut x := w.ship.pool.acquire() or { return } // max_conns busy: the next tick
	n := if w.ship.q.len <= w.sh.batch_bytes {
		w.ship.q.len
	} else {
		last_line_end(w.ship.q, w.sh.batch_bytes)
	}
	x.request('POST', w.sh.target)
	x.header('Content-Type', ndjson)
	x.retryable(true) // a batch sent twice beats a batch lost
	mut b := x.body()
	unsafe { b.push_many(w.ship.q.data, n) }
	w.ship.sent = n
	if x.send(mut el, on_ship, unsafe { nil }) == .pending {
		w.ship.x = x
		return
	}
	// Failed before parking (no address took the connect, an invalid
	// target): no watch holds its socket, so it is released here.
	x.release()
	w.ship.status = 0
	w.settle(now)
}

// on_ship is the batch's continuation, a clientless watch on the pool's
// socket: it advances the exchange until the collector answered or it
// failed. It never releases the exchange itself: a clientless continuation
// that returns .done has the runtime close the watched fd, here the pool's
// connection, which release() may want to keep. It steps to the timer
// instead (the runtime then only takes the socket out of epoll) and kicks it,
// so the tick releases the exchange and sends the next batch right away.
fn on_ship(mut _ []u8, _ int, ready_fd_error bool, payload voidptr, worker_state voidptr, mut el core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	if w.ship.x != unsafe { nil } && !w.ship.done {
		mut x := w.ship.x
		match x.advance(ready_fd_error, mut el, on_ship, payload) {
			.pending {
				return .suspend // advance re-armed the socket it woke on
			}
			.ready {
				w.ship.status = x.status()
			}
			.failed {
				w.ship.status = 0
			}
		}
		w.ship.done = true
	}
	w.kick()
	el.watch_fd(w.timer_fd, .readable, tick, unsafe { nil })
	return .suspend
}

// settle accounts for a finished batch. A 2xx takes it off the queue. A 4xx
// other than 408 and 429 will never be accepted: it is dropped (counted).
// Anything else (no answer, a 5xx, 408, 429) keeps it at the head of the
// queue for a retry after a doubling backoff.
fn (mut w Worker) settle(now u64) {
	st := w.ship.status
	n := w.ship.sent
	if st >= 200 && st < 300 {
		w.counts.shipped += count_lines(w.ship.q, 0, n)
		w.ship.consume(n)
		w.ship.backoff_ms = 0
		w.ship.retry_at = 0
		return
	}
	w.counts.ship_failures++
	if st >= 400 && st < 500 && st != 408 && st != 429 {
		w.counts.ship_dropped += count_lines(w.ship.q, 0, n)
		w.ship.consume(n)
		return
	}
	w.ship.backoff_ms = if w.ship.backoff_ms == 0 {
		w.sh.retry_ms
	} else if w.ship.backoff_ms * 2 < max_backoff_ms {
		w.ship.backoff_ms * 2
	} else {
		max_backoff_ms
	}
	w.ship.retry_at = now + u64(w.ship.backoff_ms) * u64(time.millisecond)
}

// consume drops the first n bytes of the queue (whole lines).
fn (mut s Shipper) consume(n int) {
	left := s.q.len - n
	if left > 0 {
		unsafe { vmemmove(s.q.data, &u8(s.q.data) + n, left) }
	}
	unsafe {
		s.q.len = left
	}
}

// last_line_end is the length of the longest prefix of b[..limit] made of
// whole lines (just past its last newline); 0 if it holds none.
@[direct_array_access]
fn last_line_end(b []u8, limit int) int {
	mut i := if limit < b.len { limit } else { b.len }
	for i > 0 && b[i - 1] != `\n` {
		i--
	}
	return i
}

// count_lines counts the newlines in b[from..to].
@[direct_array_access]
fn count_lines(b []u8, from int, to int) i64 {
	mut n := i64(0)
	for i in from .. to {
		if b[i] == `\n` {
			n++
		}
	}
	return n
}
