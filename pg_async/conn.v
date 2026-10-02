module pg_async

// PgConn is a single PostgreSQL connection: the TCP socket plus the v3 startup /
// SCRAM-SHA-256 handshake and extended-query execution.
//
// Connecting runs the non-blocking dialer (dial.v): blocking here, for pool
// bring-up and tests, and off the request path for a pool's re-dials. query()
// is the BLOCKING query form, used to validate the protocol and SCRAM layers
// against a live server; the non-blocking, reactor-driven query path the async
// worker uses (conn_async.v) is built on the same wire encoding (protocol.v) —
// only the I/O pump differs.

// pg_async deliberately does NOT import V's `net`: `net` declares `C.socket`
// with TYPED enum params on some V versions, and V merges C declarations
// globally — so importing `net` clashes with the plain-`int` `C.socket` that
// the socket module declares and breaks the build (e.g. on the V 0.5.1
// tag). Names are resolved with libc's getaddrinfo, and the socket is opened
// by transport.dial_addr (dial.v). C.recv/C.send/C.fcntl live in conn_async.v.
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>

// Full addrinfo layout (matches V's net module) so sizeof is correct and every
// field is zeroed — a partial decl leaves ai_flags as stack garbage and
// getaddrinfo fails.
struct C.addrinfo {
mut:
	ai_family    int
	ai_socktype  int
	ai_flags     int
	ai_protocol  int
	ai_addrlen   int
	ai_addr      voidptr
	ai_canonname voidptr
	ai_next      voidptr
}

fn C.close(fd int) int
fn C.getaddrinfo(node &char, service &char, hints &C.addrinfo, res &&C.addrinfo) int
fn C.freeaddrinfo(res &C.addrinfo)

// max_message_len bounds a backend message's length field: PostgreSQL's own
// limit (MaxAllocSize, 1 GiB). A larger one is a protocol desync.
const max_message_len = i64(0x4000_0000)

pub struct ConnConfig {
pub:
	host     string = 'localhost'
	port     int    = 5432
	user     string
	password string
	database string
	// connect_timeout_ms bounds the TCP connect to each address, and then the
	// startup handshake (authentication up to ReadyForQuery).
	connect_timeout_ms int = 5000
	// TCP keepalive: probes after this many idle seconds, every
	// tcp_keepalive_interval_s, tcp_keepalive_count of them unanswered close
	// the connection. 0 = off (the OS default: no keepalive).
	tcp_keepalive_idle_s     int = 30
	tcp_keepalive_interval_s int = 10
	tcp_keepalive_count      int = 3
	// tcp_user_timeout_ms (Linux): how long sent data may stay unacknowledged
	// before the kernel drops the connection — a peer that vanished without a
	// RST is then detected in seconds, not after the default ~15 minutes of
	// retransmissions. 0 = the OS default.
	tcp_user_timeout_ms int = 30_000
	// Re-dialing a broken pool connection (PgPool.maintain): the first attempt
	// is immediate; after a failure, exponential backoff with jitter from
	// redial_backoff_ms up to redial_backoff_max_ms.
	redial_backoff_ms     int = 100
	redial_backoff_max_ms int = 5000
}

pub struct PgConn {
mut:
	fd       int = -1 // the raw socket fd
	recv_buf []u8
	recv_pos int // async read cursor: [recv_pos, recv_buf.len) is received-but-unframed
	// In-flight non-blocking query state. The connection pipelines up to
	// max_inflight queries: async_submit appends each query's wire bytes to the
	// fixed send buffer and pushes a PendingQuery onto the FIFO; async_on_readable
	// frames replies (Postgres returns them in submit order) into the front
	// PendingQuery and pops it at ReadyForQuery. One query in flight is just the
	// degenerate N=1 case.
	send_buf []u8 // fixed-capacity (send_buf_cap), allocated once, never realloc'd
	send_off int  // [0, send_off) already sent
	send_len int  // [send_off, send_len) written, still to send
	inflight []PendingQuery
	// Per-connection reply-accumulator pool: max_inflight buffers (frame_buf_cap each)
	// allocated ONCE and reused round-robin via frame_ring, so a pipelined query never
	// allocates its accumulator per submit — essential under `-gc none`, where a
	// per-query allocation would leak. async_on_readable writes the (possibly grown)
	// buffer back to its slot on completion so growth is preserved across reuse.
	frame_pool [][]u8
	frame_ring int
	// Per-connection reusable wire-frame scratch for async_submit: one query's
	// Parse+Bind+Describe+Execute+Sync is serialized here, then copied into send_buf.
	// Allocated once (lazy), reset to len 0 each submit, grows to a high-water mark —
	// so a submit never allocates a throwaway frame (which would leak under -gc none).
	submit_scratch []u8
	// broken: the connection cannot carry another query — the server closed it
	// (EOF, a FATAL), it reset, or the byte stream desynced. A broken
	// connection refuses submit (PgErrorKind.broken), reports every query
	// still in flight once each (PgErrorKind.unknown, or .server for one the
	// server already failed), and a pool re-dials it once those are drained.
	broken bool
	// The connection's two error records, allocated once, reused across
	// queries and re-dials (see PgError, LIFETIME): err for the statement the
	// server failed, conn_err for why the connection broke or did not connect.
	err      &PgError = unsafe { nil }
	conn_err &PgError = unsafe { nil }
	// The dial in progress (dial.v).
	hs            HsState
	hs_deadline   u64 // monotonic ns: the current dial phase's deadline
	scram         ScramClient
	scram_started bool
	// kick_fd: the pool's maintenance timer (start_maintenance), pulled in
	// when this connection breaks; -1 without one.
	kick_fd int = -1
}

struct Msg {
	typ     u8
	payload []u8
}

// new_conn is a connection with its buffers and error records, not connected.
fn new_conn() PgConn {
	return PgConn{
		broken:   true // until its first ReadyForQuery
		recv_buf: []u8{cap: 16 * 1024}
		err:      new_pg_error()
		conn_err: new_pg_error()
	}
}

// PgConn.connect opens a TCP connection (to each address of host in turn,
// connect_timeout_ms each) and runs the startup + SCRAM-SHA-256 handshake,
// returning once the server reports ReadyForQuery. Errors are PgError
// (kind connect). The socket is left non-blocking.
pub fn PgConn.connect(cfg ConnConfig) !PgConn {
	mut c := new_conn()
	addrs := resolve(cfg.host, cfg.port) or { return c.dial_fail(err.msg(), 0) }
	mut cache := ScramCache{}
	c.dial_blocking(addrs, &cfg, mut cache)!
	return c
}

// reset_session forgets everything about the previous session of this
// connection (queries in flight, buffered bytes, errors), keeping every
// buffer: a re-dial reuses them.
fn (mut c PgConn) reset_session() {
	c.drop_inflight()
	unsafe {
		c.recv_buf.len = 0
		c.submit_scratch.len = 0
	}
	c.recv_pos = 0
	c.send_off = 0
	c.send_len = 0
	c.frame_ring = 0
	c.err.reset()
	c.conn_err.reset()
	c.scram_started = false
}

// close_socket closes the socket exactly once (fd reuse makes a second close
// a race in a multi-threaded process).
fn (mut c PgConn) close_socket() {
	if c.fd >= 0 {
		C.close(c.fd)
		c.fd = -1
	}
}

// close sends a best-effort Terminate (unless the connection is broken) and
// closes the socket. Calling it twice is harmless.
pub fn (mut c PgConn) close() {
	if c.fd < 0 {
		return
	}
	if !c.broken && c.hs == .idle {
		mut out := []u8{}
		write_terminate(mut out)
		C.send(c.fd, out.data, usize(out.len), C.MSG_NOSIGNAL)
	}
	c.close_socket()
	c.hs = .idle
	c.broken = true
}

fn (mut c PgConn) send(data []u8) ! {
	mut sent := 0
	for sent < data.len {
		n := C.send(c.fd, unsafe { &u8(data.data) + sent }, usize(data.len - sent), C.MSG_NOSIGNAL)
		if n <= 0 {
			if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
				C.pg_async_wait(c.fd, C.POLLOUT, -1)
				continue
			}
			c.mark_broken_errno('pg: send failed', C.errno)
			return c.conn_err
		}
		sent += n
	}
}

// read_msg blocks until one complete backend message is buffered, returns it,
// and consumes it from the receive buffer (the same cursor the async pump
// uses, so the two can be mixed on one connection).
fn (mut c PgConn) read_msg() !Msg {
	for {
		total := frame_at(c.recv_buf, c.recv_pos)
		if total < 0 {
			c.mark_desync('pg: protocol desync: bad message length')
			return c.conn_err
		}
		if total > 0 {
			typ := c.recv_buf[c.recv_pos]
			payload := c.recv_buf[c.recv_pos + 5..c.recv_pos + total].clone()
			c.recv_pos += total
			return Msg{
				typ:     typ
				payload: payload
			}
		}
		before := c.recv_buf.len - c.recv_pos
		got := c.fill_recv()
		if got == recv_eof {
			c.mark_broken_reason('pg: connection closed by server')
			return c.conn_err
		}
		if got < 0 {
			c.mark_broken_errno('pg: recv failed', -got)
			return c.conn_err
		}
		if c.recv_buf.len - c.recv_pos == before {
			C.pg_async_wait(c.fd, C.POLLIN, -1) // nothing new: block until there is
		}
	}
	return error('pg: unreachable')
}

// query runs one extended-protocol query (Parse/Bind/Describe/Execute/Sync,
// binary results) and returns the collected Result. Blocking. Parameters are
// text-format and bind to $1, $2, … (a null option element is SQL NULL).
// Errors are PgError: kind server for a failed statement (the connection
// stays usable), unknown when the connection broke before ReadyForQuery.
pub fn (mut c PgConn) query(query_text string, params []?[]u8) !Result {
	if c.broken {
		c.conn_err.kind = .broken
		return c.conn_err
	}
	mut out := []u8{}
	write_parse(mut out, '', query_text)
	write_bind(mut out, '', '', params)
	write_describe_portal(mut out, '')
	write_execute(mut out, '', 0)
	write_sync(mut out)
	c.send(out)!

	mut frames := []u8{}
	mut rows_affected := u64(0)
	mut failed := false
	for {
		msg := c.read_msg() or {
			if failed {
				return c.err // the statement failed; then the connection died
			}
			c.conn_err.kind = .unknown
			return c.conn_err
		}
		match msg.typ {
			bt_ready_for_query {
				break
			}
			bt_command_complete {
				rows_affected = parse_command_complete(msg.payload)
			}
			bt_error_response {
				if is_fatal(msg.payload) {
					c.conn_err.record_fatal(msg.payload)
					c.mark_broken_reason('pg: connection closed by server')
				} else {
					c.err.record_server(msg.payload)
					failed = true
				}
			}
			else {}
		}

		// Re-frame the message into the result region so Result.rows()
		// (FrameIter) can walk the DataRows.
		mut framed := [msg.typ]
		put_u32(mut framed, u32(4 + msg.payload.len))
		framed << msg.payload
		frames << framed
	}
	if failed {
		return c.err
	}
	return Result{
		frames:        frames
		rows_affected: rows_affected
	}
}
