module pg_async

import net

// PgConn is a single PostgreSQL connection: the TCP socket plus the v3 startup /
// SCRAM-SHA-256 handshake and extended-query execution.
//
// This is the BLOCKING form. It is used for pool bring-up (connecting + auth
// happen once, before the worker starts serving) and to validate the protocol
// and SCRAM layers against a live server. The non-blocking, reactor-driven
// query path that the async worker uses is built on the same wire encoding
// (protocol.v) — only the I/O pump differs.

pub struct ConnConfig {
pub:
	host     string = 'localhost'
	port     int    = 5432
	user     string
	password string
	database string
}

pub struct PgConn {
mut:
	sock     &net.TcpConn = unsafe { nil }
	recv_buf []u8
}

struct Msg {
	typ     u8
	payload []u8
}

// PgConn.connect opens a TCP connection and runs the startup + SCRAM-SHA-256
// handshake, returning once the server reports ReadyForQuery.
pub fn PgConn.connect(cfg ConnConfig) !PgConn {
	mut sock := net.dial_tcp('${cfg.host}:${cfg.port}')!
	mut c := PgConn{
		sock:     sock
		recv_buf: []u8{cap: 16 * 1024}
	}
	c.handshake(cfg)!
	return c
}

// close sends a best-effort Terminate and closes the socket.
pub fn (mut c PgConn) close() {
	mut out := []u8{}
	write_terminate(mut out)
	c.send(out) or {}
	c.sock.close() or {}
}

fn (mut c PgConn) send(data []u8) ! {
	mut sent := 0
	for sent < data.len {
		n := c.sock.write(data[sent..])!
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
		n := c.sock.read(mut tmp)!
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
		match msg.typ {
			bt_authentication {
				c.handle_auth(msg.payload, mut scram)!
			}
			bt_error_response {
				info := parse_error_response(msg.payload)
				return error('pg: startup failed: ${info.message.bytestr()} (SQLSTATE ${info.code.bytestr()})')
			}
			bt_ready_for_query {
				return
			}
			else {
				// ParameterStatus / BackendKeyData / NoticeResponse — ignored.
			}
		}
	}
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
	mut server_error := ''
	mut sqlstate := ''
	for {
		msg := c.read_msg()!
		match msg.typ {
			bt_ready_for_query {
				break
			}
			bt_command_complete {
				rows_affected = parse_command_complete(msg.payload)
			}
			bt_error_response {
				info := parse_error_response(msg.payload)
				server_error = info.message.bytestr()
				sqlstate = info.code.bytestr()
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
	if server_error != '' {
		return error('pg: query failed: ${server_error} (SQLSTATE ${sqlstate})')
	}
	return Result{
		frames:        frames
		rows_affected: rows_affected
	}
}
