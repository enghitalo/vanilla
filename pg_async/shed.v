module pg_async

// The backpressure contract (vanilla#51). A pipelined query can be refused
// for three different reasons, and the caller answers each differently:
//
//   Shed           the pool or the connection is momentarily full: every
//                  pipeline is at max_inflight, or no send buffer has room
//                  for the frame now, or no connection is free. Nothing was
//                  sent. Answer 503 with Retry-After (never a 200 for a write
//                  that did not happen, nor a 4xx: the request was fine).
//   FrameTooLarge  the query's wire frame is larger than a connection's send
//                  buffer (max_frame_len): it can never be sent, on any
//                  connection, now or later. A bug or an input to bound:
//                  answer 500 (or 413 when the size comes from the request).
//   ConnBroken     the connection chosen is lost (PgConn.is_broken). The pool
//                  re-dials it on its own; acquire_pipelined_for never
//                  returns one, so this reaches only a caller that submits on
//                  a connection it took some other way.
//
// Test with `err is Shed`, `err is FrameTooLarge`, `err is ConnBroken`. The
// Shed errors are constants: shedding allocates nothing, which matters under
// -gc none, where the shed path is the hot path of an overload.

// max_frame_len is the largest wire frame (a query or a batch, as
// query_frame_len and batch_frame_len count it) that a connection can ever
// send: the size of its fixed send buffer.
pub const max_frame_len = send_buf_cap

// max_inflight_limit bounds ConnConfig.max_inflight. Each pipeline slot
// keeps a reply accumulator of frame_buf_cap bytes (16 KiB) for the life of
// the connection, so the limit bounds that memory: 1024 slots are 16 MiB per
// connection.
pub const max_inflight_limit = 1024

// ShedReason says what was full when a query was shed.
pub enum ShedReason {
	no_connection    // no connection could take a pipelined query: each is held by acquire(), in a transaction, rolling back, or broken
	pipeline_full    // every candidate connection has max_inflight queries in flight
	send_buffer_full // a connection had a pipeline slot, but no send buffer had room for the frame now
}

// Shed is the error for a query refused because the pool or the connection
// is momentarily full. Nothing was sent; the same query can succeed later.
pub struct Shed {
	Error
pub:
	reason ShedReason
}

// msg says what was full.
pub fn (e Shed) msg() string {
	return match e.reason {
		.no_connection { 'pg: shed: no connection can take a pipelined query now' }
		.pipeline_full { 'pg: shed: every pipeline is at max_inflight' }
		.send_buffer_full { 'pg: shed: no send buffer has room for the frame now' }
	}
}

// FrameTooLarge is the error for a query or batch whose wire frame (`len`
// bytes) is larger than a connection's send buffer (`cap`, max_frame_len):
// it can never be sent, on any connection.
pub struct FrameTooLarge {
	Error
pub:
	len int
	cap int
}

// msg gives the frame's size and the send buffer's.
pub fn (e FrameTooLarge) msg() string {
	return 'pg: the query frame (${e.len} bytes) is larger than the send buffer (${e.cap} bytes) and can never be sent'
}

// ConnBroken is the error for a query submitted on a lost connection
// (PgConn.is_broken). `reason` is why it was lost, as seen from this side.
pub struct ConnBroken {
	Error
pub:
	reason string
}

// msg says why the connection was lost.
pub fn (e ConnBroken) msg() string {
	return 'pg: connection lost: ${e.reason}'
}

const err_shed_no_connection = IError(Shed{
	reason: .no_connection
})
const err_shed_pipeline_full = IError(Shed{
	reason: .pipeline_full
})
const err_shed_send_buffer_full = IError(Shed{
	reason: .send_buffer_full
})

// Wire sizes of the extended-protocol messages async_submit writes, with the
// unnamed statement and portal: type byte + length + body.
const parse_overhead = 1 + 4 + 1 + 1 + 2 // name '' + NUL, SQL NUL, 0 type oids
const bind_overhead = 1 + 4 + 1 + 1 + 2 + 2 + 2 + 2 // portal, statement, format counts, result formats
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

// send_room is how many more frame bytes the send buffer can take now: its
// capacity less what is written and not yet sent.
@[inline]
fn (c &PgConn) send_room() int {
	return send_buf_cap - (c.send_len - c.send_off)
}

// check_max_inflight refuses a ConnConfig.max_inflight out of 1..max_inflight_limit.
fn check_max_inflight(n int) ! {
	if n < 1 || n > max_inflight_limit {
		return error('pg: max_inflight must be in 1..${max_inflight_limit}, got ${n}')
	}
}

// submit is async_submit with the reason for a refusal: it serializes the
// query, appends it to the send buffer and pushes it onto the in-flight FIFO,
// or returns why it did not, submitting nothing:
//   - FrameTooLarge when the frame is larger than the send buffer (checked
//     first, so it is the same answer on every connection);
//   - ConnBroken when the connection is lost;
//   - Shed (.pipeline_full) when max_inflight queries are already in flight;
//   - Shed (.send_buffer_full) when the send buffer has no room for it now.
// Pair with async_flush and async_on_readable, as async_submit.
pub fn (mut c PgConn) submit(query_text string, params []?[]u8) ! {
	c.reset_scratch()
	write_parse(mut c.submit_scratch, '', query_text)
	write_bind(mut c.submit_scratch, '', '', params)
	write_describe_portal(mut c.submit_scratch, '')
	write_execute(mut c.submit_scratch, '', 0)
	write_sync(mut c.submit_scratch)
	return c.submit_scratch_frame()
}

// submit_batch is async_submit_batch with the reason for a refusal, as
// submit gives it. An empty batch is an error too.
pub fn (mut c PgConn) submit_batch(stmts []Stmt) ! {
	if stmts.len == 0 {
		return err_batch_empty
	}
	c.reset_scratch()
	for s in stmts {
		write_parse(mut c.submit_scratch, '', s.sql)
		write_bind(mut c.submit_scratch, '', '', s.params)
		write_describe_portal(mut c.submit_scratch, '')
		write_execute(mut c.submit_scratch, '', 0)
	}
	write_sync(mut c.submit_scratch)
	return c.submit_scratch_frame()
}

// submit_scratch_frame queues the frame serialized in submit_scratch, or
// says why it cannot: the shared tail of submit and submit_batch.
fn (mut c PgConn) submit_scratch_frame() ! {
	if c.submit_scratch.len > send_buf_cap {
		return FrameTooLarge{
			len: c.submit_scratch.len
			cap: send_buf_cap
		}
	}
	if c.state != .ready {
		return ConnBroken{
			reason: c.loss
		}
	}
	if c.inflight.len >= c.inflight_limit() {
		return err_shed_pipeline_full
	}
	if !c.append_send(c.submit_scratch) {
		return err_shed_send_buffer_full
	}
	c.push_inflight()
}

// acquire_pipelined_for is acquire_pipelined for a frame of `frame_len`
// bytes (query_frame_len, batch_frame_len): it returns the connection with
// the shortest pipeline among those whose send buffer can take the frame
// now, so a submit of that frame on it succeeds. It shares a connection the
// same way acquire_pipelined does, and skips the same ones (held by
// acquire(), in a transaction, rolling back, or broken).
//
// The error says why there is none:
//   - Shed: no connection can take the frame now (see ShedReason). The caller
//     answers 503 with Retry-After. A retry on "another connection" is
//     already what this call did: every connection was looked at.
//   - FrameTooLarge: frame_len is larger than max_frame_len, so no
//     connection will ever take it.
// Shedding allocates nothing.
pub fn (mut p PgPool) acquire_pipelined_for(frame_len int) !int {
	if frame_len > send_buf_cap {
		return FrameTooLarge{
			len: frame_len
			cap: send_buf_cap
		}
	}
	mut best := -1
	mut best_depth := 0
	mut full_buffer := false // a connection had a pipeline slot but no room for the frame
	mut full_pipeline := false // a live candidate was at its max_inflight
	for i in 0 .. p.conns.len {
		if !p.idle[i] && (p.conns[i].rollback_deadline == 0 || !p.finish_rollback(i)) {
			continue // held by acquire() (its borrower may be mid-transaction), or rolling back
		}
		if p.conns[i].state != .ready && !p.conns[i].redial(p.cfg) {
			continue
		}
		if p.conns[i].ready_status != tx_idle {
			continue // in a transaction: whatever is pipelined here would run inside it
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
	if full_buffer {
		return err_shed_send_buffer_full
	}
	if full_pipeline {
		return err_shed_pipeline_full
	}
	return err_shed_no_connection
}
