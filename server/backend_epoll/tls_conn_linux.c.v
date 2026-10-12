module backend_epoll

// TLS on the epoll worker. An HTTPS connection is served by the same worker,
// connection state and reactor as a plain one (conn_state_linux.c.v,
// async_linux.c.v): pipelining, .suspend and park deadlines, takeover, server
// push, file bodies, flush-then-close, timeouts. What TLS adds lives here:
//   • the handshake (tls_handshake_step), driven across epoll edges before
//     anything is served: WANT_READ waits on EPOLLIN, WANT_WRITE arms
//     EPOLLOUT (a flight can fill the send buffer). Its deadline is the one
//     the connection got at accept: the read deadline, or the idle one,
//     which runs until the first decrypted byte;
//   • record crypto: after the handshake it moves into the kernel (kTLS)
//     when the host has the `tls` module. The connection then reads and
//     writes plaintext with recv/send and sends file bodies with sendfile(2)
//     (tls_kernel). Otherwise Mbed TLS encrypts and decrypts in userspace
//     (tls_user), and conn_recv / conn_send go through the session;
//   • file bodies: a handler hands a file region off with core.queue_file
//     whatever the connection. A kTLS one sends it with sendfile(2), which
//     the kernel encrypts like any send, the headers ahead of it sent with
//     MSG_MORE so they share its first record. sendfile(2) cannot reach a
//     userspace-TLS connection (it would write plaintext), nor a kTLS socket
//     that refuses it: their regions go out as bytes, the first chunk behind
//     the headers (tls_file_lead), the rest a chunk at a time
//     (tls_file_chunk);
//   • the order around a file: the plain path keeps it by reading a region
//     still pending into write_buf before the next answer is appended
//     (materialise_file), but whole, and a large one would trip the 8 MiB
//     pending-write cap (core.max_pending_write_bytes). A TLS connection
//     sends the file first instead (send_file_first) ahead of the next
//     pipelined request, and when the socket cannot take it all it is
//     held: nothing more is read or answered until it drains
//     (ConnState.held), as the old TLS worker did. A 100 Continue waits for
//     the file on both paths (a plain connection goes on reading meanwhile).
//     (Two rare paths still read the file whole, as the plain path does: a
//     request too large to buffer, answered 413, or a streamed upload
//     pipelined behind the file.)
//   • a parked request's client: its bytes are records, so a raw peek cannot
//     tell a close_notify from data; they go through the session
//     (tls_while_parked);
//   • the session is freed with the connection (close_conn); a userspace
//     one sends its close_notify first.
// A plain-HTTP connection never runs any of it: cs.tls stays tls_plain, a
// predictable branch at each readable edge and each recv/send.
import core
import epoll
import tls

#include <sys/epoll.h>

// ConnState.tls: how the connection's bytes move. Ordered so that each hot
// check is one compare: the readable edge and recv/send look for
// != tls_plain, the writable edge for >= tls_handshake.
const tls_plain = u8(0) // plain HTTP: recv/send on the socket
const tls_kernel = u8(1) // kTLS: recv/send of plaintext, the kernel does the record crypto
const tls_user = u8(2) // records through Mbed TLS in userspace
const tls_handshake = u8(3) // handshake running, waiting to read
const tls_handshake_out = u8(4) // handshake running, waiting to write (EPOLLOUT armed)

fn C.__errno_location() &i32

// set_errno sets errno, so that tls_recv and tls_send fail the way recv(2) and
// send(2) do. Not `C.errno = e`: with V master as of 2026-10-11, assigning the
// undeclared C.errno makes the compiler crash at random while it builds a
// program that imports this module (CI: tests/pg_async_maintenance_test.v).
// __errno_location() is what glibc and musl expand errno to; errno is a C
// int, so i32 (V's int is 64-bit on 64-bit targets).
@[inline]
fn set_errno(e i32) {
	unsafe {
		p := C.__errno_location()
		*p = e
	}
}

// tls_recv is conn_recv for a TLS connection, with recv(2)'s contract.
// Userspace: the session decrypts (Session.read_into); the peer's close,
// with or without a close_notify, is the end of the stream, and stays so on
// every later read, as after a FIN; any other failure is an error. A
// want_write lands there too: a TLS 1.3 server's read writes only an alert
// ahead of a fatal error. kTLS: recv(2) of plaintext, which fails with EIO on
// a record that is not application data (and keeps failing: the record stays
// queued). For this request/response profile that is the peer's close_notify
// (or an alert): the end of the stream as well, so the answers already owed
// still go out before the close (a client may pipeline, then close).
@[noinline]
fn tls_recv(mut cs ConnState, fd int, ptr &u8, len int) int {
	if cs.tls == tls_kernel {
		n := C.recv(fd, ptr, usize(len), 0)
		if n < 0 && C.errno == C.EIO {
			return 0
		}
		return n
	}
	if cs.sess.peer_closed() {
		return 0
	}
	n := cs.sess.read_into(ptr, len)
	if n > 0 {
		return n
	}
	if n == tls.want {
		set_errno(C.EAGAIN)
		return -1
	}
	if cs.sess.peer_closed() {
		return 0
	}
	set_errno(C.ECONNRESET)
	return -1
}

// tls_send is conn_send for a TLS connection, with send(2)'s contract. kTLS:
// send(2) of plaintext, with MSG_MORE while a file region follows, so the
// kernel keeps the record open for the first bytes sendfile(2) adds instead
// of closing it around the headers. Userspace: the session encrypts (Session.write_from),
// at most one record per call. A record that cannot go out yet (WANT_WRITE)
// stays inside Mbed TLS, which must then be called again with the same
// length: tls_pend keeps it, because the caller's next call may pass more
// (responses appended to write_buf meanwhile), and Mbed TLS would report
// that many bytes sent while it only flushed the record it held.
@[noinline]
fn tls_send(mut cs ConnState, fd int, ptr &u8, len int) int {
	if cs.tls == tls_kernel {
		flags := if cs.file_remaining > 0 { C.MSG_NOSIGNAL | C.MSG_MORE } else { C.MSG_NOSIGNAL }
		return C.send(fd, ptr, usize(len), flags)
	}
	n := if cs.tls_pend > 0 { cs.tls_pend } else { len }
	r := cs.sess.write_from(ptr, n)
	if r > 0 {
		cs.tls_pend = 0
		return r
	}
	if r == tls.want_write || r == tls.want {
		cs.tls_pend = n
		set_errno(C.EAGAIN)
		return -1
	}
	cs.tls_pend = 0
	set_errno(C.EPIPE)
	return -1
}

// tls_on_readable runs first on a TLS connection's readable edge. Userspace:
// it tells the session that its socket may hold new bytes
// (Session.mark_readable): after a short read the session answers "drained"
// from its own state, until the next edge says otherwise. Handshaking: the
// handshake's next step. Returns true when the caller goes on to serve the
// connection (established, maybe with a request already waiting), false
// while the handshake waits, after it failed and closed the connection, or
// while the connection is held behind a file (send_file_first): what the
// client sent then waits until the file is out.
@[noinline]
fn tls_on_readable(epoll_fd int, fd int, mut cs ConnState, active_conns &core.Counter, mut st PlainState) bool {
	if cs.tls < tls_handshake {
		if cs.tls == tls_user {
			cs.sess.mark_readable()
		}
		return !cs.held
	}
	return tls_handshake_step(epoll_fd, fd, mut cs, active_conns, mut st) == 1
}

// tls_while_parked takes what the client of a TLS connection parked on a
// watch sends (handle_readable). The plain path peeks at the socket to notice
// a client that leaves, but a TLS client's bytes are records: a close_notify
// ahead of the FIN reads as data, and the parked request would outlive its
// client until its watch fired, holding its fds and its slot. So the bytes go
// through the session into the spare room of read_buf (pipelined requests,
// served when the park ends), and:
//   • the end of the stream with nothing buffered: the client is gone, close
//     it, tearing its watch down (close_client);
//   • the end of the stream behind buffered requests: keep them, as the plain
//     path keeps bytes still in the socket; serving them later meets the same
//     end (it is sticky, see tls_recv) and closes once they are answered;
//   • a full read_buf: the rest waits in the socket until the park ends.
@[noinline]
fn tls_while_parked(mut reactor Reactor, epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState, mut cs ConnState) {
	for cs.read_buf.len < cs.read_buf.cap {
		n := conn_recv(mut cs, fd, unsafe { &u8(cs.read_buf.data) + cs.read_buf.len }, cs.read_buf.cap - cs.read_buf.len)
		if n > 0 {
			unsafe {
				cs.read_buf.len += n
			}
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		if n == 0 && cs.read_buf.len > 0 {
			return
		}
		close_client(mut reactor, epoll_fd, fd, active_conns, mut st)
		return
	}
}

// tls_on_writable is a handshaking connection's writable edge (from
// handle_writable_plain). Waiting to write (tls_handshake_out), the handshake
// goes on. Otherwise it is the EPOLLOUT an accept-time registration starts
// with (accept_events), or one left from it, and the handshake waits on
// EPOLLIN: stop watching writability. Returns false when the connection was
// closed, true when the caller may run the EPOLLIN half of the event (a
// handshake that just finished re-arms EPOLLIN, which reports a request
// already waiting).
@[noinline]
fn tls_on_writable(epoll_fd int, fd int, mut cs ConnState, active_conns &core.Counter, mut st PlainState) bool {
	if cs.tls != tls_handshake_out {
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN) | u32(C.EPOLLET))
		return true
	}
	return tls_handshake_step(epoll_fd, fd, mut cs, active_conns, mut st) >= 0
}

// tls_handshake_step advances the handshake of a connection in tls_handshake
// or tls_handshake_out, creating its session on its first event (a new
// session starts out readable: the ClientHello may have come with the
// connect). Returns 1 once established (cs.tls is then tls_kernel or
// tls_user), 0 while it waits, and -1 when it failed and the connection was
// closed.
fn tls_handshake_step(epoll_fd int, fd int, mut cs ConnState, active_conns &core.Counter, mut st PlainState) int {
	if cs.sess.active() {
		cs.sess.mark_readable()
	} else {
		cs.sess = st.tls_cfg.new_session(fd) or {
			close_conn(epoll_fd, fd, active_conns, mut st)
			return -1
		}
	}
	r := cs.sess.handshake()
	if r == tls.want || r == tls.want_write {
		next := if r == tls.want_write { tls_handshake_out } else { tls_handshake }
		if next != cs.tls {
			events := if next == tls_handshake_out {
				u32(C.EPOLLIN) | u32(C.EPOLLOUT) | u32(C.EPOLLET)
			} else {
				u32(C.EPOLLIN) | u32(C.EPOLLET)
			}
			epoll.mod_fd_in_epoll(epoll_fd, fd, events)
			cs.tls = next
		}
		return 0
	}
	if r == tls.closed {
		close_conn(epoll_fd, fd, active_conns, mut st)
		return -1
	}
	// Established. Hand record crypto to the kernel when it can take it
	// (Session.enable_ktls): the right moment, before any application data.
	// A failure after the kernel took the socket half over leaves it
	// unusable for userspace: close.
	ktls := cs.sess.enable_ktls(fd)
	if !ktls && cs.sess.ktls_failed() {
		close_conn(epoll_fd, fd, active_conns, mut st)
		return -1
	}
	if cs.tls == tls_handshake_out {
		// Back to reading. The MOD reports EPOLLIN again if a request is
		// already waiting: the handshake read nothing past its Finished.
		epoll.mod_fd_in_epoll(epoll_fd, fd, u32(C.EPOLLIN) | u32(C.EPOLLET))
	}
	if ktls {
		cs.tls = tls_kernel
	} else {
		cs.tls = tls_user
		cs.no_sendfile = true // sendfile(2) would write plaintext: files go out as bytes
	}
	return 1
}

// tls_file_chunk_bytes is how much of a file region tls_file_lead and
// tls_file_chunk read at a time: four full TLS records. write_buf grows to it
// once and keeps it.
const tls_file_chunk_bytes = 64 * 1024

// First capacities of an HTTPS connection's read and write buffers
// (state_create): smaller than the plain ones (read_buf_cap, write_buf_cap),
// since its Mbed TLS session already takes ~37 KiB; they grow as needed and
// keep what they grew to.
const tls_read_buf_cap = 4096
const tls_write_buf_cap = 4096

// tls_file_lead appends the first chunk of a file region a handler just
// queued on a connection that sendfile(2) cannot reach (drain_requests),
// behind the headers it appended, so they leave together instead of the
// headers in a record of their own; a body that fits one chunk leaves no
// region at all. Returns false when the file came up short (it shrank under
// the Content-Length in those headers): the caller sends what is there, then
// closes.
@[noinline]
fn tls_file_lead(mut cs ConnState) bool {
	want := if cs.file_remaining > tls_file_chunk_bytes {
		i64(tls_file_chunk_bytes)
	} else {
		cs.file_remaining
	}
	got := core.append_file_region(mut cs.write_buf, cs.file_fd, cs.file_off, want)
	if got < want {
		cs.file_fd = -1 // borrowed — never closed here
		cs.file_remaining = 0
		return false
	}
	cs.file_off += got
	cs.file_remaining -= got
	if cs.file_remaining == 0 {
		cs.file_fd = -1
	}
	return true
}

// tls_file_chunk sends a file region as bytes, one chunk per call, for a
// connection sendfile(2) cannot reach (no_sendfile; drain_file calls it).
// The chunk goes into write_buf, which drain_file's callers have sent in
// full (phase 1 runs first), and the return is 2: send it, then drain again.
// A short read (the file shrank under a Content-Length already sent) returns
// 3: what it had goes out, then the connection closes, as when sendfile(2)
// meets the end of the file.
@[noinline]
fn tls_file_chunk(mut cs ConnState) int {
	unsafe {
		cs.write_buf.len = 0
	}
	cs.write_off = 0
	want := if cs.file_remaining > tls_file_chunk_bytes {
		i64(tls_file_chunk_bytes)
	} else {
		cs.file_remaining
	}
	got := core.append_file_region(mut cs.write_buf, cs.file_fd, cs.file_off, want)
	if got < want {
		cs.file_fd = -1 // borrowed — never closed here
		cs.file_remaining = 0
		return 3
	}
	cs.file_off += got
	cs.file_remaining -= got
	if cs.file_remaining == 0 {
		cs.file_fd = -1
	}
	return 2
}

// tls_file_failed handles a sendfile(2) that failed on a kTLS connection
// (drain_file has handled EAGAIN). A socket that refuses sendfile(2) (EINVAL,
// EOPNOTSUPP, ENOSYS: a kernel that cannot splice into kTLS) sends the file
// as bytes from now on: no_sendfile, and this region's next chunk
// (tls_file_chunk). Any other failure, or an EOF (the file shrank under a
// Content-Length already sent): -1, the caller closes. A fatal alert goes
// first (Session.ktls_abort): sendfile(2) can leave a record open in the
// kernel, waiting for more, and the close would discard it with the bytes
// already in it.
@[noinline]
fn tls_file_failed(mut cs ConnState, sent isize) int {
	if sent < 0 && (C.errno == C.EINVAL || C.errno == C.EOPNOTSUPP || C.errno == C.ENOSYS) {
		cs.no_sendfile = true
		return tls_file_chunk(mut cs)
	}
	cs.sess.ktls_abort()
	return -1
}

// tls_close frees the connection's session (close_conn, before the fd is
// closed). A userspace session sends its close_notify first; a kTLS one does
// not (the kernel frames the records).
@[noinline]
fn tls_close(mut cs ConnState) {
	cs.sess.free()
	cs.sess = tls.Session{}
}
