module pg_async

// Non-blocking query pump on a PgConn. Reactor-agnostic: the caller flips the
// socket to non-blocking once (after bring-up), submits a query, then drives it
// from readiness events — async_flush() on writable, async_on_readable() on
// readable. This is the exact mechanism the async HTTP worker uses via
// event_loop.watch_fd_persistent(conn_fd, ...) (a pooled fd: never plain
// watch_fd); here it is split out so any event loop can drive it
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
	severity      string
	rows_affected u64
	frame_slot    int
}

// pg_error is the query's ErrorResponse as a typed error (call when error != '').
fn (q &PendingQuery) pg_error() PgError {
	return PgError{
		severity: q.severity
		sqlstate: q.sqlstate
		message:  q.error
	}
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
// (live, and pipeline depth below max_inflight). The caller sheds when this is
// false on every pooled connection.
pub fn (c &PgConn) can_submit() bool {
	return c.state == .ready && c.inflight.len < max_inflight
}

// async_submit serializes one extended-protocol query (binary results) and
// APPENDS it to the fixed send buffer, pushing a PendingQuery onto the in-flight
// FIFO. Up to max_inflight queries may be pipelined back-to-back; each carries
// its own Sync so Postgres replies in submit order. Returns false (and submits
// nothing) when the connection is saturated — the ring is full or the send
// buffer cannot fit the frame — or broken (is_broken), so the caller must shed.
// Pair with async_flush (on writable) and async_on_readable (on readable).
pub fn (mut c PgConn) async_submit(query_text string, params []?[]u8) bool {
	if c.state != .ready || c.inflight.len >= max_inflight {
		return false
	}
	// Serialize into the per-connection reusable scratch, then copy it into the fixed
	// send buffer. The scratch (1) keeps send_buf's backing pinned (write_* append via
	// `<<`, which would reallocate send_buf) and (2) is reused across submits — a fresh
	// `[]u8{cap: 256}` per submit would leak under -gc none. Reset to len 0 each submit;
	// grows to a high-water mark if a query frame ever exceeds 512 bytes.
	if c.submit_scratch.cap == 0 {
		c.submit_scratch = []u8{cap: 512}
	}
	unsafe {
		c.submit_scratch.len = 0
	}
	write_parse(mut c.submit_scratch, '', query_text)
	write_bind(mut c.submit_scratch, '', '', params)
	write_describe_portal(mut c.submit_scratch, '')
	write_execute(mut c.submit_scratch, '', 0)
	write_sync(mut c.submit_scratch)
	if !c.append_send(c.submit_scratch) {
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
// reactor should keep writable interest armed) — or, over TLS, a read is
// blocked until the socket takes a write of Mbed TLS's own. Either way
// async_flush is what moves it on.
pub fn (c &PgConn) async_wants_write() bool {
	return c.send_off < c.send_len || c.tls_read_blocked
}

// async_flush sends as much of the pending request as the socket will take.
// Returns true once the whole request is sent; false on EAGAIN (leave writable
// interest armed and call again when writable). A send failure breaks the
// connection (is_broken): the queries in flight then fail on async_on_readable.
pub fn (mut c PgConn) async_flush() !bool {
	if c.state != .ready {
		return c.loss_error()
	}
	if c.tls_read_blocked {
		// A TLS read waits to send something of Mbed TLS's own: retry that read
		// first (into recv_buf; async_on_readable frames it). A query record
		// written now would flush Mbed TLS's pending bytes in its place.
		c.fill_recv_buf()
		if c.state != .ready {
			return c.loss_error()
		}
		if c.tls_read_blocked {
			return false
		}
	}
	for c.send_off < c.send_len {
		n := c.send_some(unsafe { &u8(c.send_buf.data) + c.send_off }, c.send_len - c.send_off)
		if n > 0 {
			c.send_off += n
			continue
		}
		if n == io_again {
			return false
		}
		c.lose(c.io_error('async send'))
		return error('pg: ${c.loss}')
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

// not_ready is the singleton returned on the (very common) not-ready path. A fresh
// `QueryPoll{}` literal default-inits its `Result.frames` to `[]u8{}`, which under
// `-gc none` allocates a (never-freed) array header EVERY call — ~1 per request on
// the drain loop's terminating not-ready return (vlang/v#27487). The const allocates
// that header once; returning it by value just copies the (ready=false) struct.
const not_ready = QueryPoll{}

// async_on_readable drains the socket to EAGAIN and frames complete backend
// messages into the FRONT in-flight query. When that query's ReadyForQuery
// arrives it is popped and returned as a ready QueryPoll; replies arrive in
// submit order, so the front of the FIFO is always the current target. Call
// repeatedly to drain all queries that one readable edge completed — each call
// returns the next finished query in FIFO order, then a not-ready poll once the
// new front needs more bytes (stay parked). A server ErrorResponse fails only
// its own query (surfaced after that query's ReadyForQuery, keeping the stream
// in sync) as a PgError carrying its SQLSTATE; pipelined siblings still
// complete on subsequent calls.
//
// Connection loss (EOF, a socket error, a FATAL/PANIC ErrorResponse) breaks the
// connection (is_broken) but never discards what was already received: every
// reply buffered before the loss is still delivered in order — a result that
// arrived together with the server's FIN is a success. Only then does each
// remaining query fail, one per call: with the FATAL's PgError (e.g. 57P01,
// terminating connection due to administrator command) when the server sent
// one, else 'pg: connection closed by server'. A broken connection never
// reports not-ready, so a caller never re-arms a watch on a dead socket.
pub fn (mut c PgConn) async_on_readable() !QueryPoll {
	// Everything received so far has been framed → reset the cursor to the front so
	// recv_buf doesn't ratchet upward (the common between-edges state).
	if c.recv_pos > 0 && c.recv_pos >= c.recv_buf.len {
		c.recv_pos = 0
		unsafe {
			c.recv_buf.len = 0
		}
	}
	c.fill_recv_buf()
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
				c.inflight[0].severity = info.severity.bytestr()
				if ends_session(info.severity) {
					// FATAL/PANIC: the server ends the session, no ReadyForQuery
					// follows. The front query fails with it below; the queries
					// behind it fail with it too (loss_error).
					c.fatal = c.inflight[0].pg_error()
					c.lose('connection closed by server')
				}
			}
			else {}
		}

		c.inflight[0].frames << c.recv_buf[c.recv_pos..c.recv_pos + hdr.total]
		is_ready := typ == bt_ready_for_query
		c.recv_pos += hdr.total
		if is_ready {
			done := c.pop_front()
			if done.error != '' {
				return done.pg_error()
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
	if c.state != .ready {
		// Lost, and the front query's reply is not (all) here: it cannot
		// complete. Fail it with its own ErrorResponse when one arrived (the
		// FATAL), else with why the connection was lost.
		if c.inflight.len > 0 {
			done := c.pop_front()
			if done.error != '' {
				return done.pg_error()
			}
		}
		return c.loss_error()
	}
	return not_ready // front query needs more bytes (or none in flight) — see `not_ready`
}

// fill_recv_buf drains the transport to EAGAIN (over TLS: until the socket is
// drained AND Mbed TLS holds no more records), recv-ing STRAIGHT into
// recv_buf's spare tail — no per-iteration 16 KiB scratch alloc + copy.
// recv_buf is persistent + reused; only when the tail is full do we compact
// the framed prefix, then grow by doubling. Only while the connection is live:
// after a loss nothing more can arrive, but what already did is still framed.
@[inline]
fn (mut c PgConn) fill_recv_buf() {
	if c.tls.active() {
		// Any wake may follow new bytes: the session read on from where it
		// last found the socket drained.
		c.tls.mark_readable()
		c.tls_read_blocked = false
	}
	for c.state == .ready {
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
		n := c.recv_some(unsafe { &u8(c.recv_buf.data) + c.recv_buf.len }, spare)
		if n > 0 {
			unsafe {
				c.recv_buf.len += n
			}
			continue
		}
		if n == 0 {
			// EOF. Not an early return: the bytes that came with the FIN (a whole
			// result, or the FATAL that explains the close) are framed first.
			c.lose('connection closed by server')
			break
		}
		if n == io_again {
			break
		}
		c.lose(c.io_error('async recv'))
		break
	}
}

// pop_front removes the front in-flight query, returning its (possibly grown)
// accumulator to its pool slot so the growth is kept and the slot is reused
// next ring cycle — no per-query alloc. Its frames buffer is then owned solely
// by the returned query and handed off without cloning: a Result borrows the
// same backing and is consumed by the resume callback before the slot can be
// reused (a full ring cycle away).
@[inline]
fn (mut c PgConn) pop_front() PendingQuery {
	done := c.inflight[0]
	c.inflight.delete(0)
	if done.frame_slot >= 0 && done.frame_slot < c.frame_pool.len {
		c.frame_pool[done.frame_slot] = done.frames
	}
	return done
}
