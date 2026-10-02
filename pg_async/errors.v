module pg_async

import strconv

// PgErrorKind tells a caller what an error means for its query and its
// connection — the part a retry decision needs, beyond the message.
pub enum PgErrorKind {
	// The server answered the statement with an ErrorResponse (severity
	// ERROR): it failed, so it had no effect, and the connection is fine.
	// sqlstate says why (40001 serialization failure, 23505 unique
	// violation, 57014 query canceled, ...).
	server = 1
	// The connection broke while the query was in flight, before its
	// ReadyForQuery: it may or may not have run. Never retry a non-idempotent
	// statement automatically on this. sqlstate is set when the server said
	// why it closed (57P01 administrator command, ...).
	unknown
	// Refused before anything was sent: the connection is broken (closed by
	// the server, reset, a FATAL, a protocol desync). The pool re-dials it;
	// retrying on another connection is safe.
	broken
	// Connecting, the startup handshake or authentication failed.
	connect
}

// PgError is pg_async's error: an IError with a machine-readable kind and
// SQLSTATE, so a caller can tell a 40001 (retry the transaction) from a 23505
// (don't) or a lost connection without parsing text:
//
//   poll := conn.async_on_readable() or {
//       if err is pg_async.PgError && err.sqlstate == '40001' { ... }
//   }
//
// LIFETIME: a connection owns its PgError records and reuses them — no
// allocation per error, so a steady stream of failing queries leaks nothing
// under -gc none. The error, and every string field of it, is valid until the
// next call on the same connection (the next submit, flush or poll).
// Copy what must outlive that (`err.msg().clone()`).
@[heap]
pub struct PgError {
	Error
pub mut:
	kind     PgErrorKind
	severity string // the non-localized severity (ERROR, FATAL, PANIC), when the server sent one
	sqlstate string // the five-character SQLSTATE, '' when there is none
	message  string // the server's primary message, or the client-side reason
	detail   string // the server's DETAIL field, '' when absent
mut:
	text     []u8 // what msg() returns, NUL-terminated (the same text the driver always produced)
	sev_buf  [8]u8
	state    [5]u8
	msg_buf  []u8
	det_buf  []u8
	recorded bool // a break reason is recorded: the first one wins...
	fatal    bool // ...except over a server's FATAL, which beats a generic EOF / errno
}

// msg is the error text: for a failed statement
// `pg: query failed: <message> (SQLSTATE <code>)`, as pg_async always
// reported it. A view into the connection's reused buffer (see LIFETIME).
pub fn (e &PgError) msg() string {
	return unsafe { tos(e.text.data, e.text.len) }
}

// code is int(kind): non-zero for every PgError.
pub fn (e &PgError) code() int {
	return int(e.kind)
}

fn new_pg_error() &PgError {
	return &PgError{
		text:    []u8{cap: 128}
		msg_buf: []u8{cap: 128}
		det_buf: []u8{cap: 64}
	}
}

// reset clears the record for reuse, keeping its buffers.
fn (mut e PgError) reset() {
	unsafe {
		e.text.len = 0
		e.msg_buf.len = 0
		e.det_buf.len = 0
	}
	e.severity = ''
	e.sqlstate = ''
	e.message = ''
	e.detail = ''
	e.recorded = false
	e.fatal = false
}

// set_fields copies an ErrorResponse's fields into the record's own buffers
// (the payload is the receive buffer, about to be reused). Returns whether
// the severity is FATAL or PANIC: the server ends the session after it.
@[direct_array_access]
fn (mut e PgError) set_fields(payload []u8) bool {
	e.reset()
	mut sev_v := -1 // the non-localized V field wins over the localized S
	mut pos := 0
	for pos < payload.len {
		ft := payload[pos]
		pos++
		if ft == 0 {
			break
		}
		start := pos
		for pos < payload.len && payload[pos] != 0 {
			pos++
		}
		n := pos - start
		if pos < payload.len {
			pos++ // the NUL
		}
		match ft {
			`V`, `S` {
				if ft == `V` || sev_v < 0 {
					m := if n > e.sev_buf.len { e.sev_buf.len } else { n }
					for i in 0 .. m {
						e.sev_buf[i] = payload[start + i]
					}
					e.severity = unsafe { tos(&e.sev_buf[0], m) }
					if ft == `V` {
						sev_v = 1
					}
				}
			}
			`C` {
				if n == 5 {
					for i in 0 .. 5 {
						e.state[i] = payload[start + i]
					}
					e.sqlstate = unsafe { tos(&e.state[0], 5) }
				}
			}
			`M` {
				unsafe { e.msg_buf.push_many(&payload[start], n) }
			}
			`D` {
				unsafe { e.det_buf.push_many(&payload[start], n) }
			}
			else {}
		}
	}
	e.message = unsafe { tos(e.msg_buf.data, e.msg_buf.len) }
	e.detail = unsafe { tos(e.det_buf.data, e.det_buf.len) }
	return e.severity == 'FATAL' || e.severity == 'PANIC'
}

// is_fatal reports whether an ErrorResponse's severity is FATAL or PANIC:
// the server ends the session right after it.
@[direct_array_access]
fn is_fatal(payload []u8) bool {
	mut pos := 0
	mut fatal := false
	for pos < payload.len {
		ft := payload[pos]
		pos++
		if ft == 0 {
			break
		}
		start := pos
		for pos < payload.len && payload[pos] != 0 {
			pos++
		}
		if ft == `V` || ft == `S` {
			n := pos - start
			fatal = (n == 5 && (unsafe { vmemcmp(&payload[start], c'FATAL', 5) } == 0
				|| unsafe { vmemcmp(&payload[start], c'PANIC', 5) } == 0))
			if ft == `V` {
				return fatal // the non-localized severity is authoritative
			}
		}
		if pos < payload.len {
			pos++
		}
	}
	return fatal
}

// record_server records a failed statement (ErrorResponse at ERROR severity).
fn (mut e PgError) record_server(payload []u8) {
	e.set_fields(payload)
	e.kind = .server
	e.put_text('pg: query failed: ')
	e.put_text(e.message)
	e.put_text(' (SQLSTATE ')
	e.put_text(e.sqlstate)
	e.put_text(')')
	e.finish_text()
}

// record_startup records an ErrorResponse received while connecting (a bad
// password, an unknown database, too many connections): kind connect.
fn (mut e PgError) record_startup(payload []u8) {
	e.set_fields(payload)
	e.kind = .connect
	e.put_text('pg: startup failed: ')
	e.put_text(e.message)
	e.put_text(' (SQLSTATE ')
	e.put_text(e.sqlstate)
	e.put_text(')')
	e.finish_text()
	e.recorded = true
}

// record_fatal records the FATAL/PANIC a server sent before closing the
// connection: the break reason every in-flight query then reports.
// It replaces a generic reason recorded first: the bytes and the close can
// arrive in the same read, and the close is seen before the FATAL is framed.
fn (mut e PgError) record_fatal(payload []u8) {
	if e.fatal {
		return
	}
	e.set_fields(payload)
	e.put_text('pg: connection closed by server: ')
	e.put_text(e.message)
	e.put_text(' (SQLSTATE ')
	e.put_text(e.sqlstate)
	e.put_text(')')
	e.finish_text()
	e.recorded = true
	e.fatal = true
}

// record_reason records a client-side break reason (`what`, plus an errno
// when non-zero), unless one is recorded already.
fn (mut e PgError) record_reason(what string, errno int) {
	if e.recorded {
		return
	}
	e.reset()
	e.put_text(what)
	if errno != 0 {
		e.put_text(' (errno ')
		e.put_int(errno)
		e.put_text(')')
	}
	e.finish_text()
	e.message = unsafe { tos(e.text.data, e.text.len) } // after finish_text: it may move the buffer
	e.recorded = true
}

@[inline]
fn (mut e PgError) put_text(s string) {
	unsafe { e.text.push_many(s.str, s.len) }
}

fn (mut e PgError) put_int(n int) {
	mut digits := [24]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { e.text.push_many(&digits[0], written) }
	}
}

// finish_text NUL-terminates the text (outside its length) so msg() is also
// a valid C string.
fn (mut e PgError) finish_text() {
	e.text << 0
	unsafe {
		e.text.len--
	}
}
