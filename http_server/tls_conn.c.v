module http_server

// TLS connection handling (epoll worker side). The plaintext path is untouched
// and uses a separate closure — this code only runs for HTTPS connections, so
// it adds zero cost to the plain hot path.
//
// Per-fd state (the TLS session + a handshake-done flag) lives in a per-worker
// map; the worker is single-threaded, so no locking. The handshake is driven
// across epoll readiness events (WANT → resume on the next EPOLLIN). Once
// established, the request is framed over TLS exactly like the plain path
// (shared `frame_request_length_lim`), reading via `session.read_into`.

import http1_1.request_parser
import http_server.tls
import sync.stdatomic

const tls_max_request_bytes = 8 * 1024 * 1024

struct TlsConn {
mut:
	sess        tls.Session
	established bool
}

@[manualfree]
fn handle_readable_fd_tls(request_handler fn ([]u8, int) ![]u8, epoll_fd int, fd int, limits Limits, counter &Counter, active_conns &Counter, cfg &tls.Config, mut sessions map[int]&TlsConn) {
	stdatomic.add_i64(&counter.n, 1)
	defer {
		stdatomic.add_i64(&counter.n, -1)
	}

	mut conn := sessions[fd] or {
		s := cfg.new_session(fd) or {
			release_conn(epoll_fd, fd, active_conns)
			return
		}
		nc := &TlsConn{
			sess:        s
			established: false
		}
		sessions[fd] = nc
		nc
	}

	// 1) Drive the handshake (spans multiple readiness events).
	if !conn.established {
		r := conn.sess.handshake()
		if r == tls.want {
			return // need more handshake bytes; resume on the next EPOLLIN
		}
		if r == tls.closed {
			close_tls(epoll_fd, fd, active_conns, mut sessions)
			return
		}
		conn.established = true
		// fall through: the request may already be buffered by the TLS layer
	}

	// 2) Read one complete request over TLS.
	req := read_request_tls(conn.sess, limits) or {
		if err.code() == 1 {
			return // would-block with nothing yet — keep the connection, wait
		}
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return
	}
	defer {
		unsafe { req.free() }
	}

	// 3) Run the handler.
	resp := request_handler(req, fd) or {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
		return
	}
	defer {
		unsafe { resp.free() }
	}

	// 4) Write the response over TLS. Keep-alive: the session stays in the map.
	if !write_all_tls(conn.sess, resp) {
		close_tls(epoll_fd, fd, active_conns, mut sessions)
	}
}

fn close_tls(epoll_fd int, fd int, active_conns &Counter, mut sessions map[int]&TlsConn) {
	if c := sessions[fd] {
		c.sess.free()
		sessions.delete(fd)
	}
	release_conn(epoll_fd, fd, active_conns)
}

// read_request_tls mirrors the plain read loop but over a TLS session. Error
// codes: 1 = would-block with nothing read (keep the connection); 413 = too
// large; 0 = malformed/closed (close). Reads into the buffer's spare capacity.
@[manualfree]
fn read_request_tls(sess tls.Session, limits Limits) ![]u8 {
	mut buf := []u8{len: 0, cap: 256}
	for {
		if buf.len == buf.cap {
			unsafe { buf.grow_cap(buf.cap) }
		}
		spare := buf.cap - buf.len
		n := sess.read_into(unsafe { &u8(buf.data) + buf.len }, spare)
		if n == tls.want {
			code := if buf.len == 0 { 1 } else { 0 }
			unsafe { buf.free() }
			return error_with_code('tls would block', code)
		}
		if n <= 0 { // closed / error
			unsafe { buf.free() }
			return error_with_code('tls connection closed', 0)
		}
		unsafe { buf.len += n }
		if buf.len > tls_max_request_bytes {
			unsafe { buf.free() }
			return error_with_code('request too large', 413)
		}
		total := request_parser.frame_request_length_lim(buf, limits.max_header_bytes,
			limits.max_body_bytes) or {
			unsafe { buf.free() }
			return err
		}
		if total >= 0 {
			if buf.len > total {
				buf.trim(total)
			}
			return buf
		}
	}
	return error('unreachable')
}

// write_all_tls encrypts and sends the whole response. Returns false on
// would-block or error (v1 has no EPOLLOUT parking for TLS writes — close).
fn write_all_tls(sess tls.Session, buf []u8) bool {
	mut sent := 0
	for sent < buf.len {
		n := sess.write_from(unsafe { &u8(buf.data) + sent }, buf.len - sent)
		if n > 0 {
			sent += n
			continue
		}
		return false
	}
	return true
}
