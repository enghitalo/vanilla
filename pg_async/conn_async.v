module pg_async

// Non-blocking query pump on a PgConn. Reactor-agnostic: the caller flips the
// socket to non-blocking once (after bring-up), submits a query, then drives it
// from readiness events — async_flush() on writable, async_on_readable() on
// readable. This is the exact mechanism the async HTTP worker uses via
// ac.watch(conn_fd, ...); here it is split out so any event loop can drive it
// (and so it can be tested with a simple pump loop against a live server).
//
// The wire encoding, framing, binary decode and error handling are all the
// already-validated protocol.v layer — only the I/O pump is new.

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>

fn C.recv(fd int, buf voidptr, len usize, flags int) int
fn C.send(fd int, buf voidptr, len usize, flags int) int
fn C.fcntl(fd int, cmd int, arg int) int

// max_inflight bounds the per-connection pipeline depth. Postgres has no wire
// limit; this caps memory (one PendingQuery accumulator each) and bounds how much
// one readable edge can complete. The caller sheds when a connection is full.
const max_inflight = 8

// send_buf_cap is the fixed per-connection send-buffer size. Allocated once and
// never reallocated, so a pipelined send in flight never sees its backing store
// move. 64 KiB holds hundreds of the small extended-
// protocol queries vanilla issues; append_send sheds if a frame won't fit.
const send_buf_cap = 64 * 1024

// frame_buf_cap is the per-accumulator reply-buffer size in the per-connection
// frames pool (see PgConn.frame_pool). Sized to hold a typical query's full reply
// (RowDescription + a LIMIT-bounded set of DataRows + CommandComplete) without a
// realloc; a larger reply still grows via `<<` and the grown buffer is written
// back to its pool slot, so growth is kept and never re-allocated per query.
const frame_buf_cap = 16 * 1024

// PendingQuery is one pipelined query's reply accumulator: its framed backend
// messages (ParseComplete..ReadyForQuery), the rows-affected count, and any
// server error. It lives on the connection's in-flight FIFO until ReadyForQuery
// completes it, at which point async_on_readable pops it and yields its Result.
// `frames` is BORROWED from the connection's frame_pool (reused round-robin), not
// allocated per query; `frame_slot` is the pool index it borrows so the buffer
// can be returned (and any growth captured) on completion.
struct PendingQuery {
mut:
	frames        []u8
	error         string
	sqlstate      string
	rows_affected u64
	frame_slot    int
}

// set_nonblocking flips the connection socket to non-blocking. Call once, after
// the connection is ready (connect + handshake done blocking).
pub fn (mut c PgConn) set_nonblocking() ! {
	flags := C.fcntl(c.fd, C.F_GETFL, 0)
	if flags < 0 {
		return error('pg: fcntl(F_GETFL) failed')
	}
	if C.fcntl(c.fd, C.F_SETFL, flags | int(C.O_NONBLOCK)) < 0 {
		return error('pg: fcntl(F_SETFL, O_NONBLOCK) failed')
	}
}

// is_busy reports whether any query is in flight on this connection.
pub fn (c &PgConn) is_busy() bool {
	return c.inflight.len > 0
}

// inflight_count is the current pipeline depth (submitted, not yet drained). The
// reactor uses it for shortest-queue routing across a small pool.
pub fn (c &PgConn) inflight_count() int {
	return c.inflight.len
}

// can_submit reports whether the connection can accept another pipelined query
// (pipeline depth below max_inflight). The caller sheds when this is false on
// every pooled connection.
pub fn (c &PgConn) can_submit() bool {
	return c.inflight.len < max_inflight
}

// async_submit serializes one extended-protocol query (binary results) and
// APPENDS it to the fixed send buffer, pushing a PendingQuery onto the in-flight
// FIFO. Up to max_inflight queries may be pipelined back-to-back; each carries
// its own Sync so Postgres replies in submit order. Returns false (and submits
// nothing) when the connection is saturated — the ring is full or the send
// buffer cannot fit the frame — so the caller must shed. Pair with async_flush
// (on writable) and async_on_readable (on readable).
pub fn (mut c PgConn) async_submit(query_text string, params []?[]u8) bool {
	if c.inflight.len >= max_inflight {
		return false
	}
	// Serialize into a small scratch frame, then copy it into the fixed buffer.
	// (The write_* helpers append via `<<`, which would reallocate the fixed
	// buffer; the scratch keeps the buffer's backing store pinned.)
	mut frame := []u8{cap: 256}
	write_parse(mut frame, '', query_text)
	write_bind(mut frame, '', '', params)
	write_describe_portal(mut frame, '')
	write_execute(mut frame, '', 0)
	write_sync(mut frame)
	if !c.append_send(frame) {
		return false
	}
	// Borrow a reply accumulator from the per-connection pool instead of allocating
	// one per query (which would leak under `-gc none`). The pool holds max_inflight
	// buffers reused round-robin; a slot is only reused after a full ring cycle, by
	// which time the query that last used it has been drained AND rendered (at most
	// max_inflight queries are in flight, enforced by the guard above), so the borrow
	// can never alias a still-in-use reply.
	if c.frame_pool.len < max_inflight {
		c.frame_pool = [][]u8{cap: max_inflight}
		for _ in 0 .. max_inflight {
			c.frame_pool << []u8{cap: frame_buf_cap}
		}
	}
	slot := c.frame_ring
	c.frame_ring = (c.frame_ring + 1) % max_inflight
	mut fbuf := c.frame_pool[slot]
	unsafe {
		fbuf.len = 0
	}
	c.inflight << PendingQuery{
		frames:     fbuf
		frame_slot: slot
	}
	return true
}

// append_send copies one serialized query frame into the fixed-capacity send
// buffer, compacting the unsent region to the front first so the buffer never
// marches forward. The buffer is allocated once and
// never reallocated. Returns false if the frame will not fit — the connection is
// saturated and the caller must shed.
fn (mut c PgConn) append_send(frame []u8) bool {
	if c.send_buf.len < send_buf_cap {
		c.send_buf = []u8{len: send_buf_cap}
		c.send_off = 0
		c.send_len = 0
	}
	if c.send_off == c.send_len {
		// Fully drained — reset to the front.
		c.send_off = 0
		c.send_len = 0
	} else if c.send_off > 0 {
		// Slide the still-unsent tail [send_off, send_len) down to the front. A
		// forward byte copy is overlap-safe (dst index <= src index).
		n := c.send_len - c.send_off
		for i in 0 .. n {
			c.send_buf[i] = c.send_buf[c.send_off + i]
		}
		c.send_off = 0
		c.send_len = n
	}
	if c.send_len + frame.len > send_buf_cap {
		return false
	}
	for i in 0 .. frame.len {
		c.send_buf[c.send_len + i] = frame[i]
	}
	c.send_len += frame.len
	return true
}

// async_wants_write reports whether request bytes are still pending (so the
// reactor should keep writable interest armed).
pub fn (c &PgConn) async_wants_write() bool {
	return c.send_off < c.send_len
}

// async_flush sends as much of the pending request as the socket will take.
// Returns true once the whole request is sent; false on EAGAIN (leave writable
// interest armed and call again when writable).
pub fn (mut c PgConn) async_flush() !bool {
	for c.send_off < c.send_len {
		n := C.send(c.fd, unsafe { &u8(c.send_buf.data) + c.send_off },
			usize(c.send_len - c.send_off), C.MSG_NOSIGNAL)
		if n > 0 {
			c.send_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return false
		}
		return error('pg: async send failed (errno ${C.errno})')
	}
	// Fully drained — reset so the next append starts at the front of the buffer.
	c.send_off = 0
	c.send_len = 0
	return true
}

// QueryPoll is the outcome of one async_on_readable call: ready=false means
// more bytes are needed (stay parked); ready=true means `result` is the
// complete result. (V has no `!?T`, so completion is a flag, not an Option.)
pub struct QueryPoll {
pub:
	ready  bool
	result Result
}

// async_on_readable drains the socket to EAGAIN and frames complete backend
// messages into the FRONT in-flight query. When that query's ReadyForQuery
// arrives it is popped and returned as a ready QueryPoll; replies arrive in
// submit order, so the front of the FIFO is always the current target. Call
// repeatedly to drain all queries that one readable edge completed — each call
// returns the next finished query in FIFO order, then a not-ready poll once the
// new front needs more bytes (stay parked). A server ErrorResponse fails only
// its own query (surfaced after that query's ReadyForQuery, keeping the stream
// in sync); pipelined siblings still complete on subsequent calls.
pub fn (mut c PgConn) async_on_readable() !QueryPoll {
	// Everything received so far has been framed → reset the cursor to the front so
	// recv_buf doesn't ratchet upward (the common between-edges state).
	if c.recv_pos > 0 && c.recv_pos >= c.recv_buf.len {
		c.recv_pos = 0
		unsafe {
			c.recv_buf.len = 0
		}
	}
	// Drain the socket to EAGAIN, recv-ing STRAIGHT into recv_buf's spare tail — no
	// per-iteration 16 KiB scratch alloc + copy. recv_buf is persistent + reused; only
	// when the tail is full do we compact the framed prefix, then grow by doubling.
	for {
		if c.recv_buf.len == c.recv_buf.cap {
			if c.recv_pos > 0 {
				rem := c.recv_buf.len - c.recv_pos
				if rem > 0 {
					unsafe {
						C.memmove(c.recv_buf.data, &u8(c.recv_buf.data) + c.recv_pos, usize(rem))
					}
				}
				unsafe {
					c.recv_buf.len = rem
				}
				c.recv_pos = 0
			}
			if c.recv_buf.len == c.recv_buf.cap {
				// Grow by the current cap (doubling), or a 16 KiB floor when cap is 0
				// (recv_buf comes back cap-0 after the blocking handshake — grow_cap(0)
				// would be a no-op, leaving spare=0 and recv reading nothing forever).
				unsafe {
					c.recv_buf.grow_cap(if c.recv_buf.cap > 0 {
						c.recv_buf.cap
					} else {
						16 * 1024
					})
				}
			}
		}
		spare := c.recv_buf.cap - c.recv_buf.len
		n := C.recv(c.fd, unsafe { &u8(c.recv_buf.data) + c.recv_buf.len }, usize(spare), 0)
		if n > 0 {
			unsafe {
				c.recv_buf.len += n
			}
			continue
		}
		if n == 0 {
			return error('pg: connection closed by server')
		}
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			break
		}
		return error('pg: async recv failed (errno ${C.errno})')
	}
	for c.inflight.len > 0 {
		hdr := next_message_at(c.recv_buf, c.recv_pos) or { break }
		typ := c.recv_buf[c.recv_pos]
		payload := c.recv_buf[c.recv_pos + 5..c.recv_pos + hdr.total]
		match typ {
			bt_command_complete {
				c.inflight[0].rows_affected = parse_command_complete(payload)
			}
			bt_error_response {
				info := parse_error_response(payload)
				c.inflight[0].error = info.message.bytestr()
				c.inflight[0].sqlstate = info.code.bytestr()
			}
			else {}
		}

		c.inflight[0].frames << c.recv_buf[c.recv_pos..c.recv_pos + hdr.total]
		is_ready := typ == bt_ready_for_query
		c.recv_pos += hdr.total
		if is_ready {
			// Pop the completed front query. Its frames buffer is now owned
			// solely by `done`, so it is handed off without cloning.
			done := c.inflight[0]
			c.inflight.delete(0)
			// Return the (possibly grown) accumulator to its pool slot so any growth
			// is kept and the slot is reused next ring cycle — no per-query alloc. The
			// Result borrows the same backing; it is consumed by the resume callback
			// before the slot can be reused (a full ring cycle away).
			if done.frame_slot >= 0 && done.frame_slot < c.frame_pool.len {
				c.frame_pool[done.frame_slot] = done.frames
			}
			if done.error != '' {
				return error('pg: query failed: ${done.error} (SQLSTATE ${done.sqlstate})')
			}
			return QueryPoll{
				ready:  true
				result: Result{
					frames:        done.frames
					rows_affected: done.rows_affected
				}
			}
		}
	}
	return QueryPoll{} // not ready — front query needs more bytes (or none in flight)
}
