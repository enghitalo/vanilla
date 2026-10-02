module pg_async

// PgConn is a single PostgreSQL connection: the TCP socket plus the v3 startup /
// SCRAM-SHA-256 handshake and extended-query execution.
//
// This is the BLOCKING form. It is used for pool bring-up (connecting + auth
// happen once, before the worker starts serving) and to validate the protocol
// and SCRAM layers against a live server. The non-blocking, reactor-driven
// query path that the async worker uses is built on the same wire encoding
// (protocol.v) — only the I/O pump differs.

// pg_async deliberately does NOT import V's `net`: `net` declares `C.socket`
// with TYPED enum params on some V versions, and V merges C declarations
// globally — so importing `net` clashes with the plain-`int` `C.socket` that
// the socket module declares and breaks the build (e.g. on the V 0.5.1
// tag). The connection is opened with libc directly, using the same signatures
// server.socket uses. C.recv/C.send/C.fcntl live in conn_async.v.
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

fn C.socket(domain int, typ int, protocol int) int
fn C.connect(sockfd int, addr voidptr, addrlen u32) int
fn C.close(fd int) int
fn C.getaddrinfo(node &char, service &char, hints &C.addrinfo, res &&C.addrinfo) int
fn C.freeaddrinfo(res &C.addrinfo)

// dial resolves host:port (getaddrinfo) and opens a TCP connection. Blocking,
// unless `nonblocking`: then the socket is O_NONBLOCK before connect(), which
// may still be in flight on return (EINPROGRESS) — the re-dial path (redial.v)
// finishes it without waiting on the network.
fn dial(host string, port int, nonblocking bool) !int {
	mut hints := C.addrinfo{}
	unsafe { vmemset(&hints, 0, int(sizeof(hints))) }
	hints.ai_family = C.AF_UNSPEC
	hints.ai_socktype = C.SOCK_STREAM
	port_str := port.str()
	mut res := &C.addrinfo(unsafe { nil })
	if C.getaddrinfo(&char(host.str), &char(port_str.str), &hints, &res) != 0 {
		return error('pg: getaddrinfo failed for ${host}:${port}')
	}
	defer {
		C.freeaddrinfo(res)
	}
	fd := C.socket(res.ai_family, res.ai_socktype, res.ai_protocol)
	if fd < 0 {
		return error('pg: socket() failed')
	}
	if nonblocking {
		flags := C.fcntl(fd, C.F_GETFL, 0)
		if flags < 0 || C.fcntl(fd, C.F_SETFL, flags | int(C.O_NONBLOCK)) < 0 {
			C.close(fd)
			return error('pg: fcntl(O_NONBLOCK) failed')
		}
	}
	if C.connect(fd, res.ai_addr, u32(res.ai_addrlen)) != 0
		&& !(nonblocking && C.errno == C.EINPROGRESS) {
		C.close(fd)
		return error('pg: connect to ${host}:${port} failed')
	}
	return fd
}

pub struct ConnConfig {
pub:
	host     string = 'localhost'
	port     int    = 5432
	user     string
	password string
	database string
}

// LinkState is a connection's health. A live connection is .ready. It turns
// .broken the moment it is known lost: EOF, a socket error, a FATAL/PANIC
// ErrorResponse, or an exclusive borrower releasing it with a query still in
// flight (its reply stream can no longer be matched to queries). A broken
// connection takes no new query and fails what is still in flight — after
// delivering every reply already buffered — and its pool then re-dials it
// through .connecting and .starting back to .ready, without blocking
// (redial.v).
enum LinkState {
	ready
	broken
	connecting // re-dial: non-blocking connect() in flight
	starting   // re-dial: StartupMessage sent, authenticating until ReadyForQuery
}

pub struct PgConn {
mut:
	fd       int = -1 // the raw socket fd
	state    LinkState
	fatal    PgError // the FATAL/PANIC that ended the session (sqlstate '' if none)
	loss     string  // why the connection was lost, as seen from this side
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
	// Re-dial bookkeeping (redial.v), touched only while the connection is not
	// .ready: the SCRAM exchange in progress, the earliest next attempt after a
	// failed one, and the deadline of the attempt in flight (monotonic ns).
	scram         ScramClient
	retry_at      u64
	dial_deadline u64
}

struct Msg {
	typ     u8
	payload []u8
}

// PgConn.connect opens a TCP connection and runs the startup + SCRAM-SHA-256
// handshake, returning once the server reports ReadyForQuery.
pub fn PgConn.connect(cfg ConnConfig) !PgConn {
	fd := dial(cfg.host, cfg.port, false)!
	mut c := PgConn{
		fd:       fd
		recv_buf: []u8{cap: 16 * 1024}
	}
	c.handshake(cfg) or {
		C.close(fd)
		return err
	}
	return c
}

// close sends a best-effort Terminate and closes the socket.
pub fn (mut c PgConn) close() {
	if c.fd < 0 {
		return // lost and not re-dialed: no socket left
	}
	if c.state == .ready {
		mut out := []u8{}
		write_terminate(mut out)
		c.send(out) or {}
	}
	C.close(c.fd)
	c.fd = -1
	c.state = .broken
}

// is_broken reports whether the connection is unusable: lost (EOF, socket
// error, a FATAL/PANIC from the server) or still being re-dialed by its pool.
// After a query error it tells a lost connection — retry on another one; the
// pool re-dials this one — from a statement error on a healthy connection
// (see PgError for the SQLSTATE).
pub fn (c &PgConn) is_broken() bool {
	return c.state != .ready
}

// lose marks a live connection broken, recording why. The first cause wins:
// a later symptom (the EOF after a FATAL) does not overwrite it.
fn (mut c PgConn) lose(reason string) {
	if c.state == .ready {
		c.state = .broken
		c.loss = reason
	}
}

// loss_error is the error a lost connection reports for a query that cannot
// complete: the FATAL the server ended the session with, when it sent one.
fn (c &PgConn) loss_error() IError {
	if c.fatal.sqlstate != '' {
		return c.fatal
	}
	return error('pg: ${c.loss}')
}

fn (mut c PgConn) send(data []u8) ! {
	mut sent := 0
	for sent < data.len {
		n := C.send(c.fd, unsafe { &u8(data.data) + sent }, usize(data.len - sent), C.MSG_NOSIGNAL)
		if n <= 0 {
			return error('pg: send failed')
		}
		sent += n
	}
}

// read_msg blocks until one complete backend message is buffered, returns it,
// and consumes it from the receive buffer.
fn (mut c PgConn) read_msg() !Msg {
	for {
		if hdr := next_message(c.recv_buf) {
			typ := c.recv_buf[0]
			payload := c.recv_buf[5..hdr.total].clone()
			c.recv_buf.delete_many(0, hdr.total)
			return Msg{
				typ:     typ
				payload: payload
			}
		}
		mut tmp := []u8{len: 16 * 1024}
		n := C.recv(c.fd, tmp.data, usize(tmp.len), 0)
		if n <= 0 {
			return error('pg: connection closed by server')
		}
		c.recv_buf << tmp[..n]
	}
	return error('pg: unreachable')
}

fn (mut c PgConn) handshake(cfg ConnConfig) ! {
	mut startup := []u8{}
	write_startup(mut startup, cfg.user, cfg.database)
	c.send(startup)!

	mut scram := ScramClient.new(cfg.user, cfg.password)!
	for {
		msg := c.read_msg()!
		if c.on_startup_msg(msg.typ, msg.payload, mut scram)! {
			return
		}
	}
}

// on_startup_msg handles one backend message of the startup / authentication
// exchange, answering the SCRAM steps; true once ReadyForQuery arrives. Shared
// by the blocking handshake and the non-blocking re-dial (redial.v).
fn (mut c PgConn) on_startup_msg(typ u8, payload []u8, mut scram ScramClient) !bool {
	match typ {
		bt_authentication {
			c.handle_auth(payload, mut scram)!
		}
		bt_error_response {
			info := parse_error_response(payload)
			return error('pg: startup failed: ${info.message.bytestr()} (SQLSTATE ${info.code.bytestr()})')
		}
		bt_ready_for_query {
			return true
		}
		else {
			// ParameterStatus / BackendKeyData / NoticeResponse — ignored.
		}
	}
	return false
}

fn (mut c PgConn) handle_auth(payload []u8, mut scram ScramClient) ! {
	sub := auth_subtype(payload)
	data := if payload.len > 4 { payload[4..] } else { []u8{} }
	match sub {
		0 {
			// AuthenticationOk — ReadyForQuery follows.
		}
		10 {
			// AuthenticationSASL — offer SCRAM-SHA-256, send the client-first message.
			mut m := []u8{}
			write_sasl_initial(mut m, scram_sha_256, scram.client_first())
			c.send(m)!
		}
		11 {
			// AuthenticationSASLContinue — server-first → client-final.
			client_final := scram.handle_server_first(data)!
			mut m := []u8{}
			write_sasl_response(mut m, client_final)
			c.send(m)!
		}
		12 {
			// AuthenticationSASLFinal — verify the server signature.
			scram.handle_server_final(data)!
		}
		else {
			return error('pg: unsupported authentication method (code ${sub}); only SCRAM-SHA-256 is implemented')
		}
	}
}

// query runs one extended-protocol query (Parse/Bind/Describe/Execute/Sync,
// binary results) and returns the collected Result. Blocking. Parameters are
// text-format and bind to $1, $2, … (a null option element is SQL NULL).
pub fn (mut c PgConn) query(query_text string, params []?[]u8) !Result {
	mut out := []u8{}
	write_parse(mut out, '', query_text)
	write_bind(mut out, '', '', params)
	write_describe_portal(mut out, '')
	write_execute(mut out, '', 0)
	write_sync(mut out)
	c.send(out)!

	mut frames := []u8{}
	mut rows_affected := u64(0)
	mut server_error := PgError{}
	mut failed := false
	for {
		msg := c.read_msg() or {
			c.lose('connection closed by server')
			if failed {
				return server_error // the statement's own error came before the close
			}
			return err
		}
		match msg.typ {
			bt_ready_for_query {
				break
			}
			bt_command_complete {
				rows_affected = parse_command_complete(msg.payload)
			}
			bt_error_response {
				info := parse_error_response(msg.payload)
				server_error = PgError{
					severity: info.severity.bytestr()
					sqlstate: info.code.bytestr()
					message:  info.message.bytestr()
				}
				failed = true
				if ends_session(info.severity) {
					c.fatal = server_error
					c.lose('connection closed by server')
					return server_error // no ReadyForQuery follows a FATAL/PANIC
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
		return server_error
	}
	return Result{
		frames:        frames
		rows_affected: rows_affected
	}
}
