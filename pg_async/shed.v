module pg_async

// The backpressure contract (vanilla#51). A pipelined query can be refused
// for three different reasons, and the caller answers each differently:
//
//   Shed           the pool or the connection is momentarily full: every
//                  pipeline is at max_inflight, or no send buffer has room
//                  for the frame now, or no connection is free. Nothing was
//                  sent. Answer 503 with Retry-After (never a 200 for a write
//                  that did not happen, nor a 4xx: the request was fine).
//   FrameTooLarge  the query's wire frame is larger than the connection's
//                  send buffer (PgConn.max_frame_len, ConnConfig.send_buf_cap):
//                  it can never be sent there, now or later; from
//                  acquire_pipelined_for, on no connection of the pool. A bug
//                  or an input to bound: answer 500 (or 413 when the size
//                  comes from the request). Nothing is serialized before the
//                  size is checked.
//   ConnBroken     the connection chosen is lost (PgConn.is_broken). The pool
//                  re-dials it on its own; acquire_pipelined_for never
//                  returns one, so this reaches only a caller that submits on
//                  a connection it took some other way.
//
// Test with `err is Shed`, `err is FrameTooLarge`, `err is ConnBroken`. Shed
// is a constant, and each connection's FrameTooLarge is boxed when the
// connection is made: refusing allocates nothing, which matters under
// -gc none, where the shed path is the hot path of an overload and a
// request-sized frame is a path a client drives. ConnBroken carries the loss's
// reason and is boxed per call: a lost connection is rare.

// max_frame_len is the largest wire frame (a query or a batch, as
// query_frame_len and batch_frame_len count it) that a connection can send
// by default: the size of its send buffer when ConnConfig.send_buf_cap is
// left at its default, 64 KiB. A connection's own is PgConn.max_frame_len().
pub const max_frame_len = send_buf_cap

// min_send_buf_cap and max_send_buf_cap bound ConnConfig.send_buf_cap. The
// floor, 16 KiB, is as much as one pipeline slot's reply buffer
// (frame_buf_cap): a smaller send buffer would save next to nothing. The
// ceiling bounds memory, since every connection keeps its buffer for life:
// 16 MiB on 4 connections and 16 workers is already 1 GiB.
pub const min_send_buf_cap = 16 * 1024
pub const max_send_buf_cap = 16 * 1024 * 1024

// max_inflight_limit bounds ConnConfig.max_inflight. Each pipeline slot
// keeps a reply accumulator of at least frame_buf_cap bytes (16 KiB) for the
// life of the connection, grown to the largest reply it held, so the limit
// bounds that memory: 256 slots are 4 MiB per connection at least. It also
// bounds the in-flight FIFO, whose pop moves the queries behind the front.
pub const max_inflight_limit = 256

// ShedReason says what was full when a query was shed.
pub enum ShedReason {
	// no connection could take a pipelined query: each is held by acquire(),
	// in a transaction, rolling back, or broken
	no_connection
	// every candidate connection has max_inflight queries in flight
	pipeline_full
	// a connection had a pipeline slot, but no send buffer had room for the
	// frame now
	send_buffer_full
}

// Shed is the error for a query refused because the pool or the connection
// is momentarily full. Nothing was sent; the same query can succeed later.
pub struct Shed {
	Error
pub:
	reason ShedReason // what was full
}

// msg says what was full.
pub fn (e Shed) msg() string {
	return match e.reason {
		.no_connection { 'pg: shed: no connection can take a pipelined query now' }
		.pipeline_full { 'pg: shed: every pipeline is at max_inflight' }
		.send_buffer_full { 'pg: shed: no send buffer has room for the frame now' }
	}
}

// FrameTooLarge is the error for a query or batch whose wire frame is larger
// than a connection's send buffer: it can never be sent there. `cap` is that
// buffer's size (PgConn.max_frame_len): the connection's own from submit and
// submit_batch, the largest of the pool's from acquire_pipelined_for. The
// frame's size is what the caller passed or can count (query_frame_len,
// batch_frame_len).
pub struct FrameTooLarge {
	Error
pub:
	cap int // the send buffer's size in bytes: max_frame_len
}

// msg gives the send buffer's size.
pub fn (e FrameTooLarge) msg() string {
	return 'pg: the query frame is larger than the send buffer (${e.cap} bytes) and can never be sent'
}

// ConnBroken is the error for a query submitted on a lost connection
// (PgConn.is_broken). `reason` is why it was lost, as seen from this side.
pub struct ConnBroken {
	Error
pub:
	// reason is why the connection was lost ('connection closed by server',
	// …); '' once its pool has started re-dialing it, or after close() ended
	// a live connection.
	reason string
}

// msg says why the connection was lost.
pub fn (e ConnBroken) msg() string {
	return 'pg: connection lost: ${e.reason}'
}

// The refusals, boxed once. Built by a function call: V (2f94b87) emits a
// const `IError(Struct{...})` of plain fields as a zero C initializer, which
// panics on msg(); a call moves the initialization to module start.
const err_shed_no_connection = shed_error(.no_connection)
const err_shed_pipeline_full = shed_error(.pipeline_full)
const err_shed_send_buffer_full = shed_error(.send_buffer_full)
// err_frame_too_large names the default send buffer: what a PgConn made
// without connect (a test, a benchmark) refuses with. A connection that is
// connected boxes the error of its own buffer (PgConn.frame_too_large).
const err_frame_too_large = frame_too_large_error(send_buf_cap)

fn shed_error(reason ShedReason) IError {
	return Shed{
		reason: reason
	}
}

fn frame_too_large_error(cap int) IError {
	return FrameTooLarge{
		cap: cap
	}
}

// Wire sizes of the extended-protocol messages async_submit writes, with the
// unnamed statement and portal: type byte + length + body.
const parse_overhead = 1 + 4 + 1 + 1 + 2 // name '' + NUL, SQL NUL, 0 type oids
// Bind: portal, statement, 0 parameter formats, the parameter count, 1
// result format and its code.
const bind_overhead = 1 + 4 + 1 + 1 + 2 + 2 + 2 + 2
const describe_len = 1 + 4 + 1 + 1
const execute_len = 1 + 4 + 1 + 4
const sync_len = 1 + 4

// query_frame_len is the size of the wire frame async_submit and submit
// write for this query: what acquire_pipelined_for needs to know. It
// serializes nothing.
pub fn query_frame_len(query_text string, params []?[]u8) int {
	return statement_frame_len(query_text, params) + sync_len
}

// batch_frame_len is the size of the wire frame async_submit_batch and
// submit_batch write for these statements.
pub fn batch_frame_len(stmts []Stmt) int {
	mut n := sync_len
	for s in stmts {
		n += statement_frame_len(s.sql, s.params)
	}
	return n
}

// statement_frame_len is one statement's Parse + Bind + Describe + Execute.
fn statement_frame_len(query_text string, params []?[]u8) int {
	mut n := parse_overhead + query_text.len + bind_overhead + describe_len + execute_len
	for p in params {
		n += 4 // the value's length (-1 for NULL)
		if v := p {
			n += v.len
		}
	}
	return n
}

// inflight_limit is this connection's pipeline depth cap: ConnConfig.max_inflight
// as the connection was opened with (max_inflight, 8, by default).
pub fn (c &PgConn) inflight_limit() int {
	return if c.inflight_cap > 0 { c.inflight_cap } else { max_inflight }
}

// max_frame_len is the largest wire frame (query_frame_len, batch_frame_len)
// this connection can send: the size of its send buffer, ConnConfig.send_buf_cap
// as the connection was opened with (max_frame_len, 64 KiB, by default). A
// larger frame is FrameTooLarge here; a smaller one sheds only while the
// buffer still holds unsent bytes (send_buffer_full).
pub fn (c &PgConn) max_frame_len() int {
	return if c.send_buf.len > 0 { c.send_buf.len } else { send_buf_cap }
}

// send_room is how many more frame bytes the send buffer can take now: its
// capacity less what is written and not yet sent.
@[inline]
fn (c &PgConn) send_room() int {
	return c.max_frame_len() - (c.send_len - c.send_off)
}

// check_max_inflight refuses a ConnConfig.max_inflight out of
// 1..max_inflight_limit.
fn check_max_inflight(n int) ! {
	if n < 1 || n > max_inflight_limit {
		return error('pg: max_inflight must be in 1..${max_inflight_limit}, got ${n}')
	}
}

// check_send_buf_cap refuses a ConnConfig.send_buf_cap out of
// min_send_buf_cap..max_send_buf_cap.
fn check_send_buf_cap(n int) ! {
	if n < min_send_buf_cap || n > max_send_buf_cap {
		return error('pg: send_buf_cap must be in ${min_send_buf_cap}..${max_send_buf_cap}, got ${n}')
	}
}

// submit is async_submit with the reason for a refusal: it serializes the
// query, appends it to the send buffer and pushes it onto the in-flight FIFO,
// or returns why it did not, submitting nothing:
//   - FrameTooLarge when the frame is larger than the send buffer
//     (max_frame_len; checked first, so the answer does not depend on what
//     is in flight);
//   - ConnBroken when the connection is lost;
//   - Shed (.pipeline_full) when max_inflight queries are already in flight;
//   - Shed (.send_buffer_full) when the send buffer has no room for it now.
// The frame is sized (query_frame_len) and checked before it is serialized,
// so a refusal costs no serialization and never grows the submit scratch.
// Pair with async_flush and async_on_readable, as async_submit. It allocates
// what async_submit does; a refusal allocates nothing, but for ConnBroken.
pub fn (mut c PgConn) submit(query_text string, params []?[]u8) ! {
	c.check_submit(query_frame_len(query_text, params))!
	c.reset_scratch()
	write_parse(mut c.submit_scratch, '', query_text)
	write_bind(mut c.submit_scratch, '', '', params)
	write_describe_portal(mut c.submit_scratch, '')
	write_execute(mut c.submit_scratch, '', 0)
	write_sync(mut c.submit_scratch)
	return c.queue_scratch()
}

// submit_batch is async_submit_batch with the reason for a refusal, as
// submit gives it. An empty batch is an error too.
pub fn (mut c PgConn) submit_batch(stmts []Stmt) ! {
	if stmts.len == 0 {
		return err_batch_empty
	}
	c.check_submit(batch_frame_len(stmts))!
	c.reset_scratch()
	for s in stmts {
		write_parse(mut c.submit_scratch, '', s.sql)
		write_bind(mut c.submit_scratch, '', '', s.params)
		write_describe_portal(mut c.submit_scratch, '')
		write_execute(mut c.submit_scratch, '', 0)
	}
	write_sync(mut c.submit_scratch)
	return c.queue_scratch()
}

// check_submit says why a frame of `frame_len` bytes cannot be queued now,
// in submit's order, or nothing when it can.
fn (c &PgConn) check_submit(frame_len int) ! {
	if frame_len > c.max_frame_len() {
		return c.frame_too_large
	}
	if c.state != .ready {
		return ConnBroken{
			reason: c.loss
		}
	}
	if c.inflight.len >= c.inflight_limit() {
		return err_shed_pipeline_full
	}
	if c.send_room() < frame_len {
		return err_shed_send_buffer_full
	}
}

// queue_scratch appends the frame serialized in submit_scratch, which
// check_submit found room for, and pushes its query onto the in-flight FIFO.
fn (mut c PgConn) queue_scratch() ! {
	if !c.append_send(c.submit_scratch) {
		return err_shed_send_buffer_full // not reached: check_submit saw the room
	}
	c.push_inflight()
}

// acquire_pipelined_for is acquire_pipelined for a frame of `frame_len`
// bytes (query_frame_len, batch_frame_len): it returns the connection with
// the shortest pipeline among those whose send buffer can take the frame
// now, so a submit of that frame on it succeeds. It shares a connection the
// same way acquire_pipelined does, and skips the same ones (held by
// acquire(), in a transaction, rolling back, or broken), and those whose
// send buffer is smaller than the frame (max_frame_len).
//
// The error says why there is none:
//   - Shed: no connection can take the frame now (see ShedReason). The caller
//     answers 503 with Retry-After. A retry on "another connection" is
//     already what this call did: every connection was looked at.
//   - FrameTooLarge: frame_len is larger than every connection's
//     max_frame_len (ConnConfig.send_buf_cap), so no connection will ever
//     take it.
// Refusing allocates nothing.
pub fn (mut p PgPool) acquire_pipelined_for(frame_len int) !int {
	mut best := -1
	mut best_depth := 0
	mut fits := false // the frame fits some connection's send buffer
	mut widest := -1 // the largest send buffer of those it does not fit
	mut full_buffer := false // a connection had a pipeline slot but no room for the frame
	mut full_pipeline := false // a live candidate was at its max_inflight
	for i in 0 .. p.conns.len {
		if frame_len > p.conns[i].max_frame_len() {
			// This connection can never take the frame.
			if widest < 0 || p.conns[i].max_frame_len() > p.conns[widest].max_frame_len() {
				widest = i
			}
			continue
		}
		fits = true
		if !p.pipelinable(i) {
			continue
		}
		d := p.conns[i].inflight_count()
		if d >= p.conns[i].inflight_limit() {
			full_pipeline = true
			continue
		}
		if p.conns[i].send_room() < frame_len {
			full_buffer = true
			continue
		}
		if d == 0 {
			return i // idle connection — optimal, take it now
		}
		if best < 0 || d < best_depth {
			best = i
			best_depth = d
		}
	}
	if best >= 0 {
		return best
	}
	if !fits && widest >= 0 {
		return p.conns[widest].frame_too_large
	}
	if full_buffer {
		return err_shed_send_buffer_full
	}
	if full_pipeline {
		return err_shed_pipeline_full
	}
	return err_shed_no_connection
}
