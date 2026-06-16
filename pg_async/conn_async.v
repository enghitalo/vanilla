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

// is_busy reports whether a query is in flight on this connection.
pub fn (c &PgConn) is_busy() bool {
	return c.q_active
}

// async_submit serializes one extended-protocol query (binary results) into the
// send buffer and marks a query in flight. Pair with async_flush (on writable)
// and async_on_readable (on readable). One in-flight query per connection.
pub fn (mut c PgConn) async_submit(query_text string, params []?[]u8) {
	c.send_buf = []u8{cap: 256}
	write_parse(mut c.send_buf, '', query_text)
	write_bind(mut c.send_buf, '', '', params)
	write_describe_portal(mut c.send_buf, '')
	write_execute(mut c.send_buf, '', 0)
	write_sync(mut c.send_buf)
	c.send_off = 0
	c.q_frames = []u8{cap: 8 * 1024}
	c.q_error = ''
	c.q_sqlstate = ''
	c.q_rows_affected = 0
	c.q_active = true
}

// async_wants_write reports whether request bytes are still pending (so the
// reactor should keep writable interest armed).
pub fn (c &PgConn) async_wants_write() bool {
	return c.send_off < c.send_buf.len
}

// async_flush sends as much of the pending request as the socket will take.
// Returns true once the whole request is sent; false on EAGAIN (leave writable
// interest armed and call again when writable).
pub fn (mut c PgConn) async_flush() !bool {
	for c.send_off < c.send_buf.len {
		n := C.send(c.fd, unsafe { &u8(c.send_buf.data) + c.send_off },
			usize(c.send_buf.len - c.send_off), C.MSG_NOSIGNAL)
		if n > 0 {
			c.send_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return false
		}
		return error('pg: async send failed (errno ${C.errno})')
	}
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

// async_on_readable drains the socket to EAGAIN, frames complete backend
// messages, and returns a ready QueryPoll once ReadyForQuery arrives — at which
// point the connection is idle again and reusable. Returns a not-ready poll if
// more data is needed (stay parked). A server ErrorResponse is surfaced as an
// error AFTER the stream is drained through ReadyForQuery, so the connection
// stays in sync for reuse.
pub fn (mut c PgConn) async_on_readable() !QueryPoll {
	for {
		mut tmp := []u8{len: 16 * 1024}
		n := C.recv(c.fd, tmp.data, usize(tmp.len), 0)
		if n > 0 {
			c.recv_buf << tmp[..n]
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
	for {
		hdr := next_message(c.recv_buf) or { break }
		typ := c.recv_buf[0]
		payload := c.recv_buf[5..hdr.total]
		match typ {
			bt_command_complete {
				c.q_rows_affected = parse_command_complete(payload)
			}
			bt_error_response {
				info := parse_error_response(payload)
				c.q_error = info.message.bytestr()
				c.q_sqlstate = info.code.bytestr()
			}
			else {}
		}

		c.q_frames << c.recv_buf[..hdr.total]
		is_ready := typ == bt_ready_for_query
		c.recv_buf.delete_many(0, hdr.total)
		if is_ready {
			c.q_active = false
			if c.q_error != '' {
				return error('pg: query failed: ${c.q_error} (SQLSTATE ${c.q_sqlstate})')
			}
			return QueryPoll{
				ready:  true
				result: Result{
					frames:        c.q_frames.clone()
					rows_affected: c.q_rows_affected
				}
			}
		}
	}
	return QueryPoll{} // not ready — need more bytes
}
