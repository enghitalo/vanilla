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
//
// OUTCOMES. Every submitted query gets exactly ONE outcome from
// async_on_readable, in submission order: its Result once its ReadyForQuery
// arrived (a complete result followed by the server closing the connection
// is still a success), or a PgError — kind server (the statement failed, the
// connection is fine) or kind unknown (the connection broke before its
// ReadyForQuery: it may or may not have run). Park every submitted query
// (watch_fd_persistent) even when the flush failed: its continuation's
// async_on_readable call is what delivers its outcome, and it keeps the
// reactor's queue of parked requests aligned with the in-flight FIFO. The one
// way to abandon a query is PgPool.release() on a connection held with
// acquire(), without parking: the connection is then retired.

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

// recv_eof is fill_recv's "the server closed the connection".
const recv_eof = 1

// PendingQuery is one pipelined query's reply accumulator: its framed backend
// messages (ParseComplete..ReadyForQuery), the rows-affected count, and whether
// the server failed it (the error itself is in the connection's err record:
// only the front query is ever being framed). It lives on the connection's
// in-flight FIFO until ReadyForQuery completes it, at which point
// async_on_readable pops it and yields its Result.
// `frames` is BORROWED from the connection's frame_pool (reused round-robin), not
// allocated per query; `frame_slot` is the pool index it borrows so the buffer
// can be returned (and any growth captured) on completion.
struct PendingQuery {
mut:
	frames        []u8
	rows_affected u64
	frame_slot    int
	failed        bool
}

// set_nonblocking flips the connection socket to non-blocking. The dialer
// already opens it non-blocking; kept for callers that call it after connect.
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
// (pipeline depth below max_inflight, and not broken). The caller sheds when
// this is false on every pooled connection.
pub fn (c &PgConn) can_submit() bool {
	return !c.broken && c.inflight.len < max_inflight
}

// is_broken reports whether the connection is broken: it takes no new query,
// and a pool re-dials it once its in-flight queries are drained.
pub fn (c &PgConn) is_broken() bool {
	return c.broken
}

// broken_reason is the error recording why the connection broke (or did not
// connect); see PgError for its lifetime.
pub fn (c &PgConn) broken_reason() &PgError {
	return c.conn_err
}

// mark_broken marks the connection broken from the application's side (e.g.
// it gave up on a reply): no new query goes to it, every query in flight
// ends with PgErrorKind.unknown, and a pool re-dials it once they are drained.
pub fn (mut c PgConn) mark_broken() {
	c.mark_broken_reason('pg: connection marked broken by the application')
}

// set_broken is the one way a live connection becomes broken: on the
// transition it pulls the pool's maintenance timer in (one syscall per
// break), so the re-dial starts as soon as the in-flight queries are drained.
fn (mut c PgConn) set_broken() {
	if !c.broken {
		c.broken = true
		if c.kick_fd >= 0 {
			kick_timer(c.kick_fd)
		}
	}
}

fn (mut c PgConn) mark_broken_reason(what string) {
	c.set_broken()
	c.conn_err.record_reason(what, 0)
}

fn (mut c PgConn) mark_broken_errno(what string, errno int) {
	c.set_broken()
	c.conn_err.record_reason(what, errno)
}

// mark_desync breaks the connection on bytes that cannot be a reply in this
// state: nothing after them can be framed reliably, so they are dropped and
// every query in flight ends unknown.
fn (mut c PgConn) mark_desync(what string) {
	c.set_broken()
	c.conn_err.record_reason(what, 0)
	c.recv_pos = c.recv_buf.len
}

// submit queues one extended-protocol query (binary results): its
// Parse/Bind/Describe/Execute/Sync are APPENDED to the fixed send buffer and a
// PendingQuery is pushed onto the in-flight FIFO. Up to max_inflight queries
// may be pipelined back-to-back; each carries its own Sync so Postgres replies
// in submit order. Returns true when queued — then park on the connection
// (watch_fd_persistent) for its outcome — and false when the connection is
// saturated (the ring is full or the send buffer cannot fit the frame): shed,
// e.g. 503. A broken connection refuses with a PgError of kind broken
// (nothing was sent; another connection may take it). Pair with async_flush
// (on writable) and async_on_readable (on readable).
pub fn (mut c PgConn) submit(query_text string, params []?[]u8) !bool {
	if c.broken {
		c.conn_err.kind = .broken
		return c.conn_err
	}
	if c.inflight.len >= max_inflight {
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

// async_submit is submit with every refusal as false: queued (true), or not
// queued (false) — saturated, or broken (is_broken tells which). Prefer
// submit, which says why.
pub fn (mut c PgConn) async_submit(query_text string, params []?[]u8) bool {
	return c.submit(query_text, params) or { false }
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
	return !c.broken && c.send_off < c.send_len
}

// async_flush sends as much of the pending request as the socket will take.
// Returns true once the whole request is sent; false on EAGAIN (leave writable
// interest armed and call again when writable). A failed send breaks the
// connection and returns its PgError; the queries in flight still get their
// outcomes from async_on_readable — park them anyway.
pub fn (mut c PgConn) async_flush() !bool {
	if c.broken {
		c.conn_err.kind = .unknown
		return c.conn_err
	}
	c.flush_nonblocking() or {
		c.mark_broken_errno('pg: async send failed', C.errno)
		c.conn_err.kind = .unknown
		return c.conn_err
	}
	return c.send_off >= c.send_len
}

// flush_nonblocking sends [send_off, send_len) until done or EAGAIN; an error
// leaves errno set. Resets the buffer to its front once everything is sent.
fn (mut c PgConn) flush_nonblocking() ! {
	for c.send_off < c.send_len {
		n := C.send(c.fd, unsafe { &u8(c.send_buf.data) + c.send_off }, usize(c.send_len - c.send_off),
			C.MSG_NOSIGNAL)
		if n > 0 {
			c.send_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		return error_sentinel
	}
	// Fully drained — reset so the next append starts at the front of the buffer.
	c.send_off = 0
	c.send_len = 0
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

// fill_recv drains the socket to EAGAIN into recv_buf's spare tail — no
// per-iteration scratch alloc + copy: recv_buf is persistent and reused; only
// when the tail is full is the framed prefix compacted, then the buffer grown by
// doubling. Returns 0 (drained), recv_eof (the server closed the connection),
// or -errno (a recv error).
fn (mut c PgConn) fill_recv() int {
	// Everything received so far has been framed → reset the cursor to the front so
	// recv_buf doesn't ratchet upward (the common between-edges state).
	if c.recv_pos > 0 && c.recv_pos >= c.recv_buf.len {
		c.recv_pos = 0
		unsafe {
			c.recv_buf.len = 0
		}
	}
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
				// (grow_cap(0) would be a no-op, leaving spare=0 and recv reading
				// nothing forever).
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
			return recv_eof
		}
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			return 0
		}
		if C.errno == C.EINTR {
			continue
		}
		return -C.errno
	}
	return 0
}

// async_on_readable drains the socket to EAGAIN and frames complete backend
// messages into the FRONT in-flight query. When that query's ReadyForQuery
// arrives it is popped and returned as a ready QueryPoll; replies arrive in
// submit order, so the front of the FIFO is always the current target. Call
// repeatedly to drain all queries that one readable edge completed — each call
// returns the next finished query in FIFO order, then a not-ready poll once the
// new front needs more bytes (stay parked). A server ErrorResponse fails only
// its own query (a PgError of kind server, surfaced after that query's
// ReadyForQuery, keeping the stream in sync); pipelined siblings still
// complete on subsequent calls.
//
// When the connection breaks (EOF, a reset, a FATAL, bytes that cannot be a
// reply), what was already received is framed first — a complete result
// followed by the close is a success — then each call pops ONE remaining
// in-flight query with a PgError of kind unknown (its ReadyForQuery never
// came: it may or may not have run), carrying the server's reason when it
// sent one (e.g. SQLSTATE 57P01). One outcome per call keeps every parked
// request's continuation paired with its own query. A broken connection
// never returns not-ready: with nothing left in flight, a call fails too.
@[direct_array_access]
pub fn (mut c PgConn) async_on_readable() !QueryPoll {
	if !c.broken {
		got := c.fill_recv()
		if got == recv_eof {
			// Frame what arrived before the close first (below).
			c.mark_broken_reason('pg: connection closed by server')
		} else if got < 0 {
			c.mark_broken_errno('pg: async recv failed', -got)
		}
	}
	for c.inflight.len > 0 {
		total := frame_at(c.recv_buf, c.recv_pos)
		if total == 0 {
			break // the front query needs more bytes
		}
		if total < 0 {
			c.mark_desync('pg: protocol desync: bad message length')
			break
		}
		typ := c.recv_buf[c.recv_pos]
		match typ {
			bt_data_row, bt_command_complete, bt_ready_for_query, bt_parse_complete,
			bt_bind_complete,
			bt_row_description, bt_no_data, bt_empty_query_response, bt_notice_response,
			bt_parameter_status, bt_close_complete, bt_portal_suspended, bt_parameter_description,
			bt_notification_response {
			}
			bt_error_response {
				payload := unsafe { (&u8(c.recv_buf.data) + c.recv_pos + 5).vbytes(total - 5) }
				if is_fatal(payload) {
					// The server ends the session: no ReadyForQuery follows.
					c.conn_err.record_fatal(payload)
					c.set_broken()
					c.recv_pos += total
					continue
				}
				c.err.record_server(payload)
				c.inflight[0].failed = true
			}
			else {
				c.mark_desync('pg: protocol desync: unexpected message type')
				break
			}
		}
		if typ == bt_command_complete {
			c.inflight[0].rows_affected = parse_command_complete(unsafe {
				(&u8(c.recv_buf.data) +
					c.recv_pos + 5).vbytes(total - 5)
			})
		}
		unsafe { c.inflight[0].frames.push_many(&u8(c.recv_buf.data) + c.recv_pos, total) }
		c.recv_pos += total
		if typ == bt_ready_for_query {
			// Pop the completed front query. Its frames buffer is now owned
			// solely by `done`, so it is handed off without cloning.
			done := c.pop_front()
			if done.failed {
				return c.err
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
	if c.broken {
		// The front query's ReadyForQuery will never come. A broken connection
		// never answers not-ready: a caller whose query is gone (dropped by
		// release()) must not re-arm a watch on a dead socket.
		if c.inflight.len > 0 {
			done := c.pop_front()
			if done.failed {
				return c.err // the server failed the statement itself: definitive
			}
		}
		c.conn_err.kind = .unknown
		return c.conn_err
	}
	return not_ready // front query needs more bytes (or none in flight) — see `not_ready`
}

// drop_inflight forgets every query in flight (nothing will wait for their
// outcomes), returning their reply buffers to the pool.
fn (mut c PgConn) drop_inflight() {
	for c.inflight.len > 0 {
		c.pop_front()
	}
}

// pop_front removes the front in-flight query, returning its (possibly grown)
// accumulator to its pool slot so any growth is kept and the slot is reused next
// ring cycle — no per-query alloc. A Result borrows the same backing; it is
// consumed by the resume callback before the slot can be reused (a full ring
// cycle away).
@[inline]
fn (mut c PgConn) pop_front() PendingQuery {
	done := c.inflight[0]
	c.inflight.delete(0)
	if done.frame_slot >= 0 && done.frame_slot < c.frame_pool.len {
		c.frame_pool[done.frame_slot] = done.frames
	}
	return done
}

// probe_idle checks an idle connection (nothing in flight) without blocking:
// a server that closed it (FATAL + EOF: idle_session_timeout, an
// administrator's pg_terminate_backend, a failover) breaks it now, so the pool
// re-dials it before a request finds it dead. One recv(MSG_PEEK) when there is
// nothing to read. Unsolicited notices and parameter reports are consumed.
@[direct_array_access]
fn (mut c PgConn) probe_idle() {
	if c.broken || c.inflight.len > 0 || c.fd < 0 {
		return
	}
	mut b := u8(0)
	n := C.recv(c.fd, &b, 1, C.MSG_PEEK | C.MSG_DONTWAIT)
	if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR) {
		return
	}
	if n < 0 {
		c.mark_broken_errno('pg: recv failed on an idle connection', C.errno)
		return
	}
	got := if n == 0 { recv_eof } else { c.fill_recv() }
	for {
		total := frame_at(c.recv_buf, c.recv_pos)
		if total == 0 {
			break
		}
		if total < 0 {
			c.mark_desync('pg: protocol desync: bad message length')
			return
		}
		typ := c.recv_buf[c.recv_pos]
		payload := unsafe { (&u8(c.recv_buf.data) + c.recv_pos + 5).vbytes(total - 5) }
		c.recv_pos += total
		match typ {
			bt_notice_response, bt_parameter_status, bt_notification_response {}
			bt_error_response {
				if is_fatal(payload) {
					c.conn_err.record_fatal(payload)
					c.set_broken()
				} else {
					c.mark_desync('pg: protocol desync: an error while idle')
					return
				}
			}
			else {
				c.mark_desync('pg: protocol desync: unexpected message while idle')
				return
			}
		}
	}
	if got == recv_eof {
		c.mark_broken_reason('pg: connection closed by server')
	} else if got < 0 {
		c.mark_broken_errno('pg: recv failed on an idle connection', -got)
	}
}
