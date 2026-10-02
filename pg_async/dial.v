module pg_async

import encoding.binary
import time
import transport

// Connecting, as a NON-BLOCKING state machine: a non-blocking connect(), then
// the StartupMessage / SCRAM-SHA-256 exchange up to ReadyForQuery, one step
// at a time (dial_step). Two drivers share it, so the protocol logic exists
// once:
//   - PgConn.connect / PgPool.connect drive it blocking (poll(2) between
//     steps, bounded by connect_timeout_ms): bring-up, before serving;
//   - PgPool.maintain drives it from a timer, off the request path, with
//     zero-timeout polls only: re-dialing a broken pool slot never blocks the
//     worker (a blocking re-dial costs ~20 ms even on loopback, most of it
//     PBKDF2 — see ScramCache — and every network round trip on a LAN).

#include <poll.h>
#include <netdb.h>
#include "@VMODROOT/pg_async/pg_async_shim.h"

fn C.pg_async_wait(fd int, events int, timeout_ms int) int
fn C.pg_async_tune(fd int, nodelay int, ka_idle int, ka_intvl int, ka_cnt int, user_timeout_ms int)
fn C.pg_async_getsockopt_int(fd int, level int, name int) int
fn C.pg_async_gai_strerror(rc int) &char

// Addr is one resolved address of the server: a sockaddr, copied out of
// getaddrinfo's list so it can be reused for every re-dial.
struct Addr {
mut:
	family int
	len    u32
	data   [128]u8 // sizeof(struct sockaddr_storage)
}

// resolve returns every address getaddrinfo gives for host:port, in its order
// (dial tries them in turn). Blocking: DNS. Bring-up calls it directly; the
// pool re-resolves on a helper thread (see PgPool.maintain).
fn resolve(host string, port int) ![]Addr {
	mut hints := C.addrinfo{}
	unsafe { vmemset(&hints, 0, int(sizeof(hints))) }
	hints.ai_family = C.AF_UNSPEC
	hints.ai_socktype = C.SOCK_STREAM
	port_str := port.str()
	mut res := &C.addrinfo(unsafe { nil })
	rc := C.getaddrinfo(&char(host.str), &char(port_str.str), &hints, &res)
	if rc != 0 {
		reason := unsafe { cstring_to_vstring(C.pg_async_gai_strerror(rc)) }
		return error('pg: cannot resolve ${host}:${port}: ${reason}')
	}
	defer {
		C.freeaddrinfo(res)
	}
	mut out := []Addr{}
	mut ai := res
	for ai != unsafe { nil } {
		if ai.ai_addrlen > 0 && ai.ai_addrlen <= 128 {
			mut a := Addr{
				family: ai.ai_family
				len:    u32(ai.ai_addrlen)
			}
			unsafe { vmemcpy(&a.data[0], ai.ai_addr, ai.ai_addrlen) }
			out << a
		}
		ai = unsafe { &C.addrinfo(ai.ai_next) }
	}
	if out.len == 0 {
		return error('pg: no usable address for ${host}:${port}')
	}
	return out
}

// HsState is where a connection is in its startup.
enum HsState {
	idle       // no dial in progress: a ready connection, or a broken one
	connecting // a non-blocking connect() is in flight
	startup    // connected: StartupMessage and authentication, until ReadyForQuery
}

// DialWait is what a dial step needs next.
enum DialWait {
	done       // ReadyForQuery: the connection is ready
	want_read  // step again once the socket is readable (or on the next tick)
	want_write // step again once the socket is writable (or on the next tick)
}

// start_connect starts a non-blocking connect to `a` (transport.dial_addr)
// and tunes the socket: the connection is then dialing (connecting). The
// connection's buffers are reused.
fn (mut c PgConn) start_connect(a &Addr, cfg &ConnConfig, now u64) ! {
	c.reset_session()
	fd := transport.dial_addr(voidptr(&a.data[0]), a.len)
	if fd < 0 {
		return c.dial_fail('pg: connect failed', -fd)
	}
	C.pg_async_tune(fd, 1, cfg.tcp_keepalive_idle_s, cfg.tcp_keepalive_interval_s, cfg.tcp_keepalive_count,
		cfg.tcp_user_timeout_ms)
	c.fd = fd
	c.hs_deadline = now + u64(cfg.connect_timeout_ms) * 1_000_000
	c.hs = .connecting
}

// begin_startup queues the StartupMessage: the socket just connected.
fn (mut c PgConn) begin_startup(cfg &ConnConfig, now u64) {
	c.hs = .startup
	c.hs_deadline = now + u64(cfg.connect_timeout_ms) * 1_000_000
	c.scram_started = false
	unsafe {
		c.submit_scratch.len = 0
	}
	write_startup(mut c.submit_scratch, cfg.user, cfg.database)
	c.append_send(c.submit_scratch)
}

// dial_step advances the dial as far as it can without blocking. An error
// means this attempt failed: the caller closes the socket (abort_dial).
fn (mut c PgConn) dial_step(cfg &ConnConfig, mut cache ScramCache, now u64) !DialWait {
	if c.hs == .idle {
		return .done
	}
	if c.hs == .connecting {
		if C.pg_async_wait(c.fd, C.POLLOUT, 0) <= 0 {
			if now >= c.hs_deadline {
				return c.dial_fail('pg: connect timed out', 0)
			}
			return .want_write
		}
		so_error := transport.connect_error(c.fd)
		if so_error != 0 {
			return c.dial_fail('pg: connect failed', so_error)
		}
		c.begin_startup(cfg, now)
	}
	// .startup: send what is queued, read what arrived, answer it; repeat
	// until a step neither sends nor receives anything.
	for {
		if c.send_off < c.send_len {
			c.flush_nonblocking() or { return c.dial_fail('pg: send failed during startup', C.errno) }
			if c.send_off < c.send_len {
				if now >= c.hs_deadline {
					return c.dial_fail('pg: startup timed out', 0)
				}
				return .want_write
			}
		}
		got := c.fill_recv()
		if got == recv_eof {
			return c.dial_fail('pg: connection closed by server during startup', 0)
		}
		if got < 0 {
			return c.dial_fail('pg: recv failed during startup', -got)
		}
		if c.process_startup(cfg, mut cache)! {
			return .done
		}
		if c.send_off < c.send_len {
			continue // an answer was queued: send it now
		}
		if now >= c.hs_deadline {
			return c.dial_fail('pg: startup timed out', 0)
		}
		return .want_read
	}
	return .want_read
}

// process_startup handles every complete startup message buffered. true =
// ReadyForQuery arrived (the connection is ready).
@[direct_array_access]
fn (mut c PgConn) process_startup(cfg &ConnConfig, mut cache ScramCache) !bool {
	for {
		total := frame_at(c.recv_buf, c.recv_pos)
		if total == 0 {
			return false
		}
		if total < 0 {
			return c.dial_fail('pg: protocol desync during startup: bad message length', 0)
		}
		typ := c.recv_buf[c.recv_pos]
		payload := unsafe { (&u8(c.recv_buf.data) + c.recv_pos + 5).vbytes(total - 5) }
		c.recv_pos += total
		match typ {
			bt_authentication {
				c.handle_auth_step(payload, cfg, mut cache)!
			}
			bt_error_response {
				c.conn_err.record_startup(payload)
				return c.conn_err
			}
			bt_ready_for_query {
				// An exchange that started SCRAM must have ended with the
				// server's proof (SASLFinal): AuthenticationOk alone would let
				// a server that never knew the password skip it.
				if c.scram_started && !c.scram.is_done() {
					return c.dial_fail('pg: server skipped SCRAM verification', 0)
				}
				// Bytes after it (an asynchronous ParameterStatus or notice,
				// possibly partial) stay buffered: they belong to the stream.
				c.hs = .idle
				c.broken = false
				c.conn_err.reset()
				c.send_off = 0
				c.send_len = 0
				return true
			}
			bt_parameter_status, bt_backend_key_data, bt_notice_response {
				// Reported settings, the cancel key, notices: not used yet.
			}
			else {
				return c.dial_fail('pg: protocol desync during startup: unexpected message', 0)
			}
		}
	}
	return false
}

// handle_auth_step answers one Authentication message.
fn (mut c PgConn) handle_auth_step(payload []u8, cfg &ConnConfig, mut cache ScramCache) ! {
	sub := auth_subtype(payload)
	data := if payload.len > 4 {
		unsafe { (&u8(payload.data) + 4).vbytes(payload.len - 4) }
	} else {
		[]u8{}
	}
	match sub {
		0 {} // AuthenticationOk — ParameterStatus..ReadyForQuery follow
		10 {
			// AuthenticationSASL: the mechanisms offered, NUL-separated.
			if !sasl_offers(data, scram_sha_256) {
				return c.dial_fail('pg: server offers no SCRAM-SHA-256 (only SCRAM-SHA-256 is implemented)',
					0)
			}
			c.scram = ScramClient.new(cfg.user, '') or {
				return c.dial_fail('pg: no random bytes for the SCRAM nonce', 0)
			}
			c.scram_started = true
			unsafe {
				c.submit_scratch.len = 0
			}
			write_sasl_initial(mut c.submit_scratch, scram_sha_256, c.scram.client_first())
			c.append_send(c.submit_scratch)
		}
		11 {
			if !c.scram_started {
				return c.dial_fail('pg: SASLContinue before SASL', 0)
			}
			client_final := c.scram.reply_to_server_first(data, cfg.password, mut cache) or {
				return c.dial_fail('pg: SCRAM exchange failed', 0)
			}
			unsafe {
				c.submit_scratch.len = 0
			}
			write_sasl_response(mut c.submit_scratch, client_final)
			c.append_send(c.submit_scratch)
		}
		12 {
			if !c.scram_started {
				return c.dial_fail('pg: SASLFinal before SASL', 0)
			}
			c.scram.handle_server_final(data) or {
				return c.dial_fail('pg: SCRAM server signature rejected', 0)
			}
		}
		else {
			c.conn_err.reset()
			c.conn_err.put_text('pg: unsupported authentication method (code ')
			c.conn_err.put_int(int(sub))
			c.conn_err.put_text('); only SCRAM-SHA-256 is implemented')
			c.conn_err.finish_text()
			c.conn_err.message = c.conn_err.msg()
			c.conn_err.kind = .connect
			return c.conn_err
		}
	}
}

// sasl_offers reports whether a NUL-separated mechanism list names `mech`.
fn sasl_offers(list []u8, mech string) bool {
	mut start := 0
	for i in 0 .. list.len {
		if list[i] == 0 {
			if i - start == mech.len && unsafe { vmemcmp(&list[start], mech.str, mech.len) } == 0 {
				return true
			}
			start = i + 1
		}
	}
	return false
}

// dial_fail records a dial failure as the connection's error (kind connect).
fn (mut c PgConn) dial_fail(what string, errno int) IError {
	c.conn_err.recorded = false
	c.conn_err.record_reason(what, errno)
	c.conn_err.kind = .connect
	return c.conn_err
}

// abort_dial closes the socket of a failed dial: the connection is broken.
fn (mut c PgConn) abort_dial() {
	c.close_socket()
	c.hs = .idle
	c.broken = true
}

// dial_blocking connects to the first address of `addrs` that answers and
// runs the startup handshake, waiting in poll(2): bring-up. Each address
// gets connect_timeout_ms for the TCP connect and again for the handshake.
fn (mut c PgConn) dial_blocking(addrs []Addr, cfg &ConnConfig, mut cache ScramCache) ! {
	mut last := IError(error('pg: no address to connect to'))
	for a in addrs {
		c.start_connect(&a, cfg, time.sys_mono_now()) or {
			last = err
			continue
		}
		for {
			was_connecting := c.hs == .connecting
			w := c.dial_step(cfg, mut cache, time.sys_mono_now()) or {
				c.abort_dial()
				if was_connecting {
					last = err
					break // try the next address
				}
				return err // the server answered and refused: no other address will differ
			}
			if w == .done {
				return
			}
			left := (i64(c.hs_deadline) - i64(time.sys_mono_now())) / 1_000_000 + 1
			events := if w == .want_write { C.POLLOUT } else { C.POLLIN }
			C.pg_async_wait(c.fd, events, if left > 0 { int(left) } else { 0 })
		}
	}
	return last
}

// tcp_option reads an int TCP-level socket option of the connection (tests).
fn (c &PgConn) tcp_option(name int) int {
	return C.pg_async_getsockopt_int(c.fd, C.IPPROTO_TCP, name)
}

// socket_option reads an int SOL_SOCKET option of the connection (tests).
fn (c &PgConn) socket_option(name int) int {
	return C.pg_async_getsockopt_int(c.fd, C.SOL_SOCKET, name)
}

// frame_at is the total length (type byte + length) of the complete backend
// message at pos, 0 when it is not complete yet, -1 when its length field is
// impossible (under 4, or past max_message_len): a protocol desync.
@[direct_array_access; inline]
fn frame_at(buf []u8, pos int) int {
	if buf.len - pos < 5 {
		return 0
	}
	msg_len := i64(binary.big_endian_u32_at(buf, pos + 1))
	if msg_len < 4 || msg_len > max_message_len {
		return -1
	}
	total := int(msg_len) + 1
	if buf.len - pos < total {
		return 0
	}
	return total
}
