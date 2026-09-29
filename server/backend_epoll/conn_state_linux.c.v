module backend_epoll

// Plain (non-TLS) per-connection state for the epoll worker: the persistent
// buffers, the batched flush/EPOLLOUT machinery, sendfile streaming and the
// timeout sweep. The request-serving loop that drives it lives in
// async_linux.c.v (handle_readable / drain_requests / serve_conn).
//
// Shared-nothing hot path modeled on the fastest HTTP/1.1 servers
// (see docs/PERF_GAP_ANALYSIS.md):
//   • persistent per-connection buffers — every connection owns a reused read
//     buffer (8 KiB) and write buffer (16 KiB) for its whole lifetime; no
//     per-event allocation, no per-request free;
//   • flat fd-indexed state table — O(1) lookup, no hashing;
//   • HTTP/1.1 pipelining — one EPOLLIN burst may carry many requests; every
//     complete request is parsed and answered into the write buffer, leftover
//     partial bytes are compacted to the front, and the whole batch goes out
//     in ONE send;
//   • backpressure — a batch that can't be sent in one go is parked and
//     drained on EPOLLOUT (write_timeout guarded), never truncated; a peer
//     that pipelines requests without reading responses is closed once its
//     pending batch exceeds sm_max_pending_write.
import core
import epoll
import http1_1.response
import sync.stdatomic
import time

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <unistd.h>

// recv/send were inherited from server.c.v while this lived in that module;
// now in backend_epoll they must be declared here.
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.memmove(__dest voidptr, __src voidptr, __n usize) voidptr

// sendfile(2): copy bytes from a file fd straight to the socket inside the
// kernel (no userspace bounce). With a non-NULL offset the kernel advances it
// and leaves the file's own position untouched, so ONE shared fd is safe to
// send from many connections/threads at once. pread is the userspace fallback
// used when a pipelined response must follow the file body in byte order.
fn C.sendfile(out_fd int, in_fd int, offset &i64, count usize) isize
fn C.pread(fd int, buf voidptr, count usize, offset i64) isize

const sm_max_request_bytes = 8 * 1024 * 1024
// Bound a single sendfile(2) call so one connection can't monopolize the worker;
// the remainder streams on the next writable edge.
const sm_sendfile_chunk = 1024 * 1024
// Write-side cap: close a connection whose peer pipelines requests but never
// drains responses (otherwise write_buf would grow without bound).
const sm_max_pending_write = 8 * 1024 * 1024
const read_buf_cap = 8 * 1024
const write_buf_cap = 16 * 1024
const conn_table_min = 1024

// buf_view returns a non-owning []u8 window over `buf[start..start+length]` WITHOUT
// going through `array.slice()`. V's slice() does unconditional slice-aliasing
// bookkeeping per call — `mark_buffer_has_slices()` (computes the malloc header,
// sets a flag) plus the flag/`data_header` churn — which a profile shows is ~20% of
// the plaintext hot path's instructions, yet is pure waste here: read_buf is
// manually managed (grown via grow_cap, compacted via memmove, len reset — never
// `array.delete`d with a live slice), so nothing ever consults `has_slices`. The
// window shares read_buf's backing and is read-only and short-lived (the parser /
// the request handler consume it before the next recv can move read_buf). Clearing
// `.managed` makes it non-owning: it is never freed, and a sub-slice taken from it
// by a handler also skips the marking. Compiles to a struct-copy + 3 field stores
// (no allocation, no clone) — verified in the emitted C.
@[inline]
fn buf_view(buf []u8, start int, length int) []u8 {
	mut v := unsafe { buf }
	unsafe {
		v.data = &u8(buf.data) + start
		v.len = length
		v.cap = length
		v.flags.clear(.managed)
	}
	return v
}

// A request whose framed size exceeds this is STREAMED, not buffered: the head
// is answered and the body is drained (recv'd into the fixed buffer and
// discarded) instead of growing read_buf into a multi-MB scanned block — the
// difference between buffering a 20 MiB upload and handling it in O(buffer)
// memory. Realistic request bodies (JSON, form posts) stay well under this and
// take the normal buffered path; only large uploads drain, and their handlers
// answer by Content-Length (request_parser.HttpRequest.content_length).
const sm_stream_body_above = 1024 * 1024

// ConnState is allocated once per connection (on its first event) and reused
// until the connection closes. The buffers keep their capacity across
// requests: read_buf accumulates request bytes across edges, write_buf
// accumulates response bytes until they are flushed in one send.
struct ConnState {
mut:
	read_buf       []u8 // persistent request buffer; len = bytes buffered
	write_buf      []u8 // persistent response buffer; [write_off..len) pending
	write_off      int
	read_deadline  u64 // monotonic ns; >0 while a request is mid-read (read_timeout) — from accept for the first one
	write_deadline u64 // monotonic ns; >0 while a batch is parked (write_timeout)
	// Deferred file body to stream with sendfile(2) AFTER write_buf drains (a
	// handler appended its headers to write_buf and handed the body off via
	// core.queue_file). file_fd is BORROWED (the asset table owns it) and is
	// never closed here; file_off is advanced by the kernel as bytes go out.
	file_fd        int = -1
	file_off       i64
	file_remaining i64
	// >0 while a large request body is being streamed (drained + discarded): the
	// head was already answered, this many body bytes are still to be consumed
	// off the socket before the connection is ready for its next request.
	body_drain i64
	// The external fd this connection is parked on while awaiting a watch
	// (-1 = not parked). Lets the worker tear the watch down if the client
	// closes mid-await.
	awaiting_fd int = -1
	// Set when the client half-closed its write side (recv → 0 / EOF) while a
	// response was still pending: the request half is done, but we still owe the
	// already-computed reply on the open write half (RFC 9112 §9.6). The flush
	// paths close the connection once the buffer drains instead of keeping it
	// alive — a half-closed peer will never send another request. See issue #103.
	close_after_flush bool
	// Set once a 100 Continue interim response has been sent for the request
	// currently mid-read, so a peer that sends `Expect: 100-continue` and dribbles
	// its body across edges is prompted exactly once (RFC 9110 §10.1.1). It refers
	// to the request at the head of read_buf: cleared when that request completes
	// (drain_requests consumed it, or its streamed body finished), so the next
	// Expect request on a keep-alive connection gets its own 100.
	sent_100 bool
	// The conn-mode seam (issue #136): nil (the default) means the HTTP/1.1
	// state machine drives this connection — the hot path pays exactly one
	// predictable nil-check in handle_readable. Set (via core.queue_takeover
	// from an upgrade handler, e.g. RFC 6455 `Upgrade: websocket`) it is the
	// ConnHandler every subsequent readable burst is fed to instead; the read
	// buffer, batched flush, EPOLLOUT backpressure and timeout machinery are
	// all reused unchanged. takeover_state is the caller's per-connection
	// protocol state, handed back on every call, never inspected here.
	takeover       core.ConnHandler = unsafe { nil }
	takeover_state voidptr
	// The reaping fields below sit after the hot ones and leave the per-burst
	// layout alone: with idle_timeout_ms off the request path never reads
	// them (the per-recv idle check is gated on the worker's idle budget).
	// monotonic ns; >0 while the connection waits for the first byte of a
	// request: a keep-alive connection at rest after a response, or a new one
	// when read_timeout_ms is 0. Expiry closes silently.
	idle_deadline u64
	// While body_drain > 0: where the output held for the streamed request
	// starts in write_buf (start_body_drain). Everything before it answers
	// earlier requests.
	drain_off int
}

// PlainState is the per-worker connection table. `parked` counts armed
// deadlines (read, write and idle), so a worker with nothing armed never
// wakes for a sweep. With a read or idle timeout set, every open connection
// normally carries one (from accept on), except while it is parked on a watch
// or taken over; the sweep itself is rate-limited to sweep_interval_ms().
pub struct PlainState {
mut:
	conns []&ConnState
	// free_conns is a per-worker free-list of retired ConnStates, each keeping its
	// 8K read_buf + 16K write_buf. close_conn resets a connection and pushes it
	// here instead of freeing; state_for pops from here instead of allocating.
	// Under -gc none, freeing + re-allocating those buffers on every reconnect
	// (load generators churn tens of thousands of connections per run) leaves
	// retained allocator arena that grows RSS run-over-run — pooling bounds memory
	// to the worker's peak concurrent connection count. Per-worker: no locking.
	free_conns []&ConnState
	parked     int
	// Resolved once per worker from Limits (0 = off): the accept-time read
	// budget and the keep-alive idle budget (Limits.idle_ms()), in ns.
	read_ns u64
	idle_ns u64
	// The batch clock: read once per worker loop iteration, and only when a
	// timeout is configured. Every deadline armed or checked in that batch
	// uses it, so the request path never reads the clock itself.
	now        u64
	next_sweep u64 // monotonic ns; the sweep scans the table only once now >= this
	// The listener's local address, set once at startup: an untagged
	// leftover fd is detached only if it is not a socket accepted on it
	// (leftover_fd). listen_port is its TCP port; listen_uds is set for an
	// AF_UNIX listener instead.
	listen_port int
	listen_uds  bool
	// The worker's watch reactor, so close_conn can tear a parked connection's
	// watch down on every close path (see close_conn).
	reactor &Reactor = unsafe { nil }
	// close_seq counts this worker's closes; closed_at[fd] is its value at
	// fd's last close (sized with conns), and batch_seq its value when the
	// current batch of events began (closed_in_batch). The birth queue's
	// entries carry it too (drain_births).
	close_seq u64
	batch_seq u64
	closed_at []u64
	// Accept-time births are on (a read or idle timeout is set): the close
	// stamps below are kept, and accepted connections are handed over by the
	// accept thread through births_q (see BirthQueue).
	births   bool
	births_q &BirthQueue = unsafe { nil }
}

// birth_queue_cap is the capacity of a worker's BirthQueue (a power of two).
// When it is full the accept thread falls back to an EPOLLOUT registration.
const birth_queue_cap = 4096

// BirthQueue hands accepted connections from the accept thread to one plain
// worker when accept-time births are on (a read or idle timeout is set), so
// the worker learns about a connection that never sends a byte — and arms its
// accept-time deadline — without an epoll event of its own. (Registering the
// fd for EPOLLOUT does that too, but a new socket is writable at once, so the
// edge wakes a sleeping worker a second time for every connection.) Single
// producer (the accept thread), single consumer (the worker, at the start of
// each loop iteration, so a connection queued before that pass is born with
// its accept time before its first event is handled). A worker with nothing
// armed first waits one bounded sweep interval; only when that runs out with
// no event, no birth and no signal does it announce a sleep with no timeout,
// and only then does a push wake it through its eventfd — so connection churn
// does not pay that wake.
// Each entry also carries the worker's close_seq as the
// accept thread read it BEFORE registering the fd: a close of that connection
// can only come later and stamps a larger value, so the worker can tell an
// entry whose connection it has already closed — its number possibly reused
// by another connection or fd — from a live one.
@[heap]
struct BirthQueue {
mut:
	head      u64 // next entry the worker reads (written by the worker)
	pad0      [56]u8
	tail      u64 // next entry the accept thread writes (written by the accept thread)
	pad1      [56]u8
	close_seq u64 // the worker's close_seq, published for the accept thread
	pad2      [56]u8
	sleeping  u64 // 1 while the worker is about to block with no timeout (written by the worker)
	pad3      [56]u8
	wake_fd   int = -1 // an eventfd in the worker's epoll: the accept thread writes it to wake a sleeping worker
	fds       [birth_queue_cap]int
	seqs      [birth_queue_cap]u64
	accepted  [birth_queue_cap]u64 // monotonic ns of the accept: the connection's clock starts there
}

// has_room is called by the accept thread (the only producer, so the room can
// only grow until its push).
@[inline]
fn (q &BirthQueue) has_room() bool {
	return stdatomic.load_u64(&q.tail) - stdatomic.load_u64(&q.head) < birth_queue_cap
}

// push appends fd (accept thread; after has_room). seq is the worker's
// close_seq read before fd was registered in its epoll, accepted_ns the
// accept time. A worker that announced it is about to sleep with no timeout
// is woken through its eventfd: it stores `sleeping` and then re-checks the
// tail, while this stores the tail and then checks `sleeping` (both seq_cst),
// so at least one of them sees the other and the entry is never stranded.
@[direct_array_access; inline]
fn (mut q BirthQueue) push(fd int, seq u64, accepted_ns u64) {
	t := stdatomic.load_u64(&q.tail)
	i := int(t & (birth_queue_cap - 1))
	q.fds[i] = fd
	q.seqs[i] = seq
	q.accepted[i] = accepted_ns
	stdatomic.store_u64(&q.tail, t + 1) // publishes the entry
	if stdatomic.load_u64(&q.sleeping) != 0 {
		one := u64(1)
		C.write(q.wake_fd, &one, 8)
	}
}

// drain_births gives a birth (state + accept-time deadline) to every queued
// connection that is still unborn: not closed since it was queued (its close
// would have stamped a larger close_seq) and without state yet (a connection
// that sent something first was already born by its first event). No syscall.
@[direct_array_access]
fn drain_births(mut st PlainState) int {
	mut q := st.births_q
	h := q.head // only this worker writes head
	t := stdatomic.load_u64(&q.tail)
	if h == t {
		return 0
	}
	mut born := 0
	for n := h; n < t; n++ {
		i := int(n & (birth_queue_cap - 1))
		fd := q.fds[i]
		if fd < st.closed_at.len && st.closed_at[fd] > q.seqs[i] {
			continue // closed since queued: stale
		}
		if fd < st.conns.len && unsafe { st.conns[fd] != nil } {
			continue // already born
		}
		conn_birth(fd, q.accepted[i], mut st) // the clock started at accept
		born++
	}
	stdatomic.store_u64(&q.head, t)
	return born
}

// birth_queue_pending is the worker's last look before an unbounded wait:
// it announces the sleep, then re-checks for entries (see push).
@[inline]
fn birth_queue_pending(mut q BirthQueue) bool {
	stdatomic.store_u64(&q.sleeping, 1)
	if stdatomic.load_u64(&q.tail) != q.head {
		stdatomic.store_u64(&q.sleeping, 0)
		return true
	}
	return false
}

// tick reads the batch clock (see PlainState.now).
@[inline]
fn (mut st PlainState) tick() {
	st.now = time.sys_mono_now()
}

pub fn new_plain_state() PlainState {
	return PlainState{
		conns: []&ConnState{len: conn_table_min, init: unsafe { nil }}
		// closed_at is allocated by the worker only when births are on.
	}
}

// closed_in_batch reports whether fd was closed during the current batch of
// events (close_conn stamps it): any later event for it in the same batch is
// stale — it describes the registration that close removed.
@[direct_array_access; inline]
fn (st &PlainState) closed_in_batch(fd int) bool {
	return fd < st.closed_at.len && st.closed_at[fd] > st.batch_seq
}

// state_for returns the connection state for fd, creating it (with its
// persistent buffers) on first use. The table grows by doubling, so fd
// indexing stays O(1) with no hashing.
// state_for returns the connection state for fd, creating it on first use.
// The lookup is the hot path (every event of an established connection) and
// stays small enough to inline at both callers; creating one is not
// (state_create).
@[direct_array_access; inline]
fn state_for(mut st PlainState, fd int) &ConnState {
	if fd < st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs != nil } {
			return cs
		}
	}
	return state_create(mut st, fd)
}

// state_create is state_for's slow path: it grows the table (and the
// close stamps with it) and takes a pooled ConnState or allocates one. Kept
// out of line so the event loop's hot code stays compact.
@[direct_array_access; noinline]
fn state_create(mut st PlainState, fd int) &ConnState {
	if fd >= st.conns.len {
		mut new_len := st.conns.len
		for new_len <= fd {
			new_len *= 2
		}
		mut grown := []&ConnState{len: new_len, init: unsafe { nil }}
		for i in 0 .. st.conns.len {
			grown[i] = st.conns[i]
		}
		st.conns = grown
		if st.births {
			mut stamps := []u64{len: new_len}
			for i in 0 .. st.closed_at.len {
				stamps[i] = st.closed_at[i]
			}
			st.closed_at = stamps
		}
	}
	if unsafe { st.conns[fd] == nil } {
		// Reuse a retired ConnState (buffers retained, fields reset by close_conn)
		// before allocating — see PlainState.free_conns.
		if st.free_conns.len > 0 {
			st.conns[fd] = st.free_conns.pop()
			return st.conns[fd]
		}
		mut cs := &ConnState{
			read_buf:  []u8{len: 0, cap: read_buf_cap}
			write_buf: []u8{len: 0, cap: write_buf_cap}
		}
		// Keep both buffers in a no-scan GC block ACROSS growth. A large response
		// grows write_buf past write_buf_cap; without this flag grow_cap reallocates
		// as a *scanned* block, and thousands of big per-conn buffers at high
		// keep-alive conn counts turn GC scanning + stop-the-world into the
		// bottleneck (the "static cliff"). The flag survives resize.
		//
		// `.noscan_data` only exists on V after the 0.5.1 release, so it is gated
		// behind `-d vanilla_noscan` to keep the library buildable on the 0.5.1
		// release. (`$if flag ? {}` is comptime-eliminated when the flag is unset,
		// so the enum value is never type-checked there.) Enable it once a V
		// release ships `.noscan_data` without the unrelated codegen slowdown that
		// currently makes post-0.5.1 master far slower (vlang/v#27468).
		$if vanilla_noscan ? {
			unsafe {
				cs.read_buf.flags.set(.noscan_data)
				cs.write_buf.flags.set(.noscan_data)
			}
		}
		st.conns[fd] = cs
	}
	return st.conns[fd]
}

// park_write arms the write deadline (once) and subscribes the fd to EPOLLOUT so
// a batch that couldn't fully drain is resumed on the next writable edge.
@[inline]
fn park_write(epoll_fd int, fd int, limits core.Limits, mut st PlainState, mut cs ConnState) {
	if limits.write_timeout_ms > 0 && cs.write_deadline == 0 {
		cs.write_deadline = st.now + u64(limits.write_timeout_ms) * 1_000_000
		st.parked++
	}
	epoll.mod_fd_in_epoll(epoll_fd, fd, (u32(C.EPOLLIN) | u32(C.EPOLLOUT) | u32(C.EPOLLET)))
}

// append_file_region reads [off, off+len) from a borrowed file fd into `buf`.
// Used to materialize a deferred sendfile body into the response buffer when a
// pipelined response must follow it in order, and as the userspace fallback on
// backends/OSes that can't sendfile.
@[manualfree]
fn append_file_region(mut buf []u8, file_fd int, off i64, length i64) {
	if length <= 0 {
		return
	}
	start := buf.len
	unsafe { buf.grow_len(int(length)) }
	mut got := i64(0)
	for got < length {
		n := C.pread(file_fd, unsafe { &u8(buf.data) + start + int(got) }, usize(length - got),

			off + got)
		if n <= 0 {
			break // short read (file truncated mid-flight) — send what we got
		}
		got += i64(n)
	}
	if got < length {
		unsafe {
			buf.len = start + int(got)
		}
	}
}

// drain_file streams the connection's deferred file body to the socket with
// sendfile(2), advancing file_off/file_remaining. Returns:
//   1  fully sent (file_remaining == 0)
//   0  partial — EAGAIN, more to send on the next writable edge
//  -1  hard error — caller must close the connection
@[inline]
fn drain_file(fd int, mut cs ConnState) int {
	for cs.file_remaining > 0 {
		want := if cs.file_remaining > sm_sendfile_chunk {
			usize(sm_sendfile_chunk)
		} else {
			usize(cs.file_remaining)
		}
		sent := C.sendfile(fd, cs.file_fd, &cs.file_off, want)
		if sent > 0 {
			cs.file_remaining -= i64(sent)
			continue
		}
		if sent < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return 0
		}
		return -1 // sent == 0 (unexpected EOF) or a hard error
	}
	return 1
}

// flush_batch writes all pending response bytes then streams any deferred file
// body with sendfile(2), or parks the remainder for EPOLLOUT. The write buffer
// is reset (capacity kept) once everything is sent. Returns false if the
// connection was closed (callers must not touch it).
@[manualfree]
fn flush_batch(epoll_fd int, fd int, limits core.Limits, active_conns &core.Counter, mut st PlainState, mut cs ConnState) bool {
	// Phase 1: the buffered response bytes (status line, headers, small bodies).
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			park_write(epoll_fd, fd, limits, mut st, mut cs)
			return true // parked, still alive
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return false
	}
	// Phase 2: stream the deferred file body straight from the page cache.
	if cs.file_remaining > 0 {
		match drain_file(fd, mut cs) {
			0 {
				park_write(epoll_fd, fd, limits, mut st, mut cs)
				return true // parked mid-file, still alive
			}
			-1 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return false
			}
			else {}
		}
	}
	cs.write_buf.clear() // len = 0, capacity kept for the next batch
	cs.write_off = 0
	cs.file_fd = -1 // borrowed — never closed here
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	return true
}

// conn_birth creates the state of a connection that has none yet and arms
// its accept-time deadline from `start`: READ when read_timeout_ms is set (it
// bounds the silence and the whole first request), otherwise IDLE (a
// connection that has sent nothing is idle). Two callers: drain_births, with
// the accept time the accept thread recorded, and the worker loop, with the
// batch clock, for a tagged first event of a connection the drain has not
// born: queued after this pass's drain, or not queued at all (the EPOLLOUT
// registration a full queue falls back to). Neither can fail or
// needs a syscall; a fallback registration's EPOLLOUT is dropped later, by
// the spurious-wake path of the connection's next event.
@[inline]
fn conn_birth(fd int, start u64, mut st PlainState) {
	mut cs := state_for(mut st, fd)
	if st.read_ns > 0 {
		cs.read_deadline = start + st.read_ns
	} else {
		cs.idle_deadline = start + st.idle_ns
	}
	st.parked++
}

// leftover_fd reports whether fd, which has an event but no state and no
// accept tag, is an app's fd left registered in this epoll (a finished watch's
// pooled connection, timerfd, pipe or dialed socket) that the worker should
// detach. Not when the fd is closed (EBADF: the kernel already dropped its
// registration, and a DEL could only hit a number accept reused meanwhile),
// and not for a socket accepted on this server's listener (its local address
// is the listener's: accept reused the number, and its tagged birth event
// follows). One getsockname, only on this rare path.
@[direct_array_access; inline]
fn (st &PlainState) leftover_fd(fd int) bool {
	family, port, named := sock_local(fd)
	if family == -1 {
		return C.errno != C.EBADF // not a socket (a timerfd, pipe…) but open
	}
	if st.listen_uds {
		return !(family == C.AF_UNIX && named)
	}
	return !((family == C.AF_INET || family == C.AF_INET6) && port == st.listen_port)
}

// sock_local reads fd's local address (getsockname): its family (-1 when fd
// is not an open socket), its port for AF_INET/AF_INET6, and for AF_UNIX
// whether it is bound to a path. The port sits at the same offset in
// sockaddr_in and sockaddr_in6, and sun_path right after the family.
@[direct_array_access]
fn sock_local(fd int) (int, int, bool) {
	mut a := [128]u8{} // sizeof(struct sockaddr_storage)
	mut l := u32(128)
	if C.getsockname(fd, voidptr(&a[0]), &l) != 0 || l < 2 {
		return -1, 0, false
	}
	family := int(unsafe { *(&u16(&a[0])) }) // sa_family_t, host order
	return family, int((u32(a[2]) << 8) | u32(a[3])), l > 2 && a[2] != 0 // port: network order
}

// arm_idle_deadline starts the keep-alive idle clock at a request boundary:
// the response is fully handed to the kernel and the connection is back to
// waiting for a new request. Anything else keeps its own clock or none —
// bytes of the next request buffered or a read deadline still armed (the read
// deadline governs: the accept-time one of a connection that has sent nothing
// yet, woken by an event that read nothing), a streamed body still draining,
// parked on a watch, taken over, closing, or a write still pending (the write
// deadline governs). Arms only when unarmed, never refreshes: a burst that
// read nothing cannot extend the idle wait, and a served request always
// re-arms fresh because its first byte cleared it.
//
// Called from the serve_conn tail and the handle_writable_plain drain, never
// from flush_batch: the SSE flush in on_watch_ready runs flush_batch BEFORE it
// re-parks the connection (awaiting_fd is still -1 there).
@[inline]
fn arm_idle_deadline(mut st PlainState, mut cs ConnState) {
	if st.idle_ns == 0 || cs.idle_deadline != 0 || cs.read_buf.len != 0 || cs.body_drain != 0
		|| cs.read_deadline != 0 || cs.awaiting_fd >= 0 || cs.takeover != unsafe { nil }
		|| cs.close_after_flush || cs.write_off < cs.write_buf.len || cs.file_remaining > 0 {
		return
	}
	cs.idle_deadline = st.now + st.idle_ns
	st.parked++
}

// handle_writable_plain drains a parked batch when the socket is writable.
// Returns false if the connection was closed (the worker must then skip any
// further events for this fd in the current batch).
@[direct_array_access; manualfree]
fn handle_writable_plain(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) bool {
	if fd >= st.conns.len {
		return false
	}
	mut cs := st.conns[fd]
	if unsafe { cs == nil } {
		// EPOLLOUT is only armed after state exists (an accept-time birth is
		// handled by the worker loop); nil means a close raced this event in
		// the same batch.
		return false
	}
	if cs.body_drain > 0 {
		// A streamed upload's response is buffered in write_buf but MUST stay held
		// until the body is fully drained (drain-then-respond). If an earlier batch
		// parked on EPOLLOUT and then this connection began draining a large upload,
		// flushing here would send the upload's held head-response mid-body and desync
		// the client — exactly what the drain gate prevents. Stay parked; the body is
		// still arriving on EPOLLIN edges and the body_drain==0 end-of-burst flush in
		// handle_readable_plain sends everything once the body completes.
		return true
	}
	if cs.write_off >= cs.write_buf.len && cs.file_remaining <= 0 {
		// Spurious wake — nothing parked; stop watching writability.
		epoll.mod_fd_in_epoll(epoll_fd, fd, (u32(C.EPOLLIN) | u32(C.EPOLLET)))
		return true
	}
	// Phase 1: finish the buffered bytes.
	for cs.write_off < cs.write_buf.len {
		n := C.send(fd, unsafe { &u8(cs.write_buf.data) + cs.write_off },
			usize(cs.write_buf.len - cs.write_off), C.MSG_NOSIGNAL)
		if n > 0 {
			cs.write_off += n
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return true // still parked
		}
		close_conn(epoll_fd, fd, active_conns, mut st)
		return false
	}
	// Phase 2: finish the deferred file body.
	if cs.file_remaining > 0 {
		match drain_file(fd, mut cs) {
			0 {
				return true
			} // still parked mid-file
			-1 {
				close_conn(epoll_fd, fd, active_conns, mut st)
				return false
			}
			else {}
		}
	}
	cs.write_buf.clear()
	cs.write_off = 0
	cs.file_fd = -1 // borrowed — never closed here
	if cs.write_deadline != 0 {
		cs.write_deadline = 0
		st.parked--
	}
	// The client half-closed (issue #103) and this was the last, backpressured
	// chunk of its reply — the response is now fully out, so close instead of
	// keeping the connection alive for a request that can never come.
	if cs.close_after_flush {
		close_conn(epoll_fd, fd, active_conns, mut st)
		return false
	}
	epoll.mod_fd_in_epoll(epoll_fd, fd, (u32(C.EPOLLIN) | u32(C.EPOLLET))) // stop watching writability
	// The parked reply is fully out: back at a request boundary.
	arm_idle_deadline(mut st, mut cs)
	return true
}

// sweep_timeouts closes connections whose read/write/idle deadline has passed
// (as of the batch clock st.now). The worker calls it only when a deadline is
// armed, and at most once per sweep_interval_ms() — never after every batch.
@[direct_array_access; manualfree]
fn sweep_timeouts(epoll_fd int, active_conns &core.Counter, mut st PlainState) {
	now := st.now
	for fd in 0 .. st.conns.len {
		cs := st.conns[fd]
		if unsafe { cs == nil } {
			continue
		}
		if cs.read_deadline > 0 && now > cs.read_deadline {
			// 408 only when part of a request arrived — a peer that never spoke
			// (the accept-time deadline) gets a silent close. A taken-over
			// connection no longer speaks HTTP — the 408 bytes would be protocol
			// garbage to its peer; just close. And only at a response boundary:
			// the 408 goes straight to the socket, so it must not land inside a
			// response still pending (parked mid-send), nor ahead of one owed to
			// an earlier request. That is nothing left to write or, for a
			// streamed body, every earlier response out and the upload's own
			// output (its held reply, after a 100 Continue not sent yet) not
			// started: that request was never answered, and the 408 replaces
			// its reply.
			at_boundary := if cs.body_drain > 0 {
				cs.write_off == cs.drain_off
			} else {
				cs.write_off >= cs.write_buf.len
			}
			if cs.takeover == unsafe { nil } && (cs.read_buf.len > 0 || cs.body_drain > 0)
				&& at_boundary && cs.file_remaining <= 0 {
				response.send_status_408_response(fd) // couldn't finish the request in time
			}
			close_conn(epoll_fd, fd, active_conns, mut st)
		} else if cs.write_deadline > 0 && now > cs.write_deadline {
			close_conn(epoll_fd, fd, active_conns, mut st)
		} else if cs.idle_deadline > 0 && now > cs.idle_deadline {
			close_conn(epoll_fd, fd, active_conns, mut st) // idle keep-alive: silent
		}
	}
}

// close_conn resets the connection's state, returns it to the per-worker pool
// (buffers kept, see PlainState.free_conns), clears its table slot and
// releases the fd. NOT idempotent (release_conn always runs): every close
// site must make sure it is the only one closing — the bool returns of
// flush_batch / drain_requests / handle_writable_plain exist exactly for that.
@[direct_array_access; manualfree]
fn close_conn(epoll_fd int, fd int, active_conns &core.Counter, mut st PlainState) {
	if fd < st.conns.len {
		mut cs := st.conns[fd]
		if unsafe { cs != nil } {
			// A connection closed while parked on a watch by a write-side path
			// (write timeout, pending-write cap, a failed flush) must not leave
			// that watch behind: it would fire against whatever connection reuses
			// this fd (vanilla#100 hazard 2), and its request-owned fd would leak.
			// Same teardown as close_client (which clears awaiting_fd first). Never
			// the connection's own socket: release_conn below closes that.
			if cs.awaiting_fd == fd {
				// Parked on its own socket's writability: only the watch goes (an
				// active entry would swallow the birth event of the next
				// connection on this number); release_conn closes the socket.
				st.reactor.reactor_clear(fd)
			} else if cs.awaiting_fd >= 0 {
				detach_rejected_watch(mut st.reactor, epoll_fd, cs.awaiting_fd, fd)
			}
			if cs.read_deadline != 0 {
				st.parked--
			}
			if cs.write_deadline != 0 {
				st.parked--
			}
			if cs.idle_deadline != 0 {
				st.parked--
			}
			// Reuse instead of free: reset to a pristine state and return to the
			// per-worker pool, KEEPING the read/write buffers (just length-zeroed,
			// capacity retained). Freeing + re-allocating them per reconnect leaks
			// allocator arena under -gc none — see PlainState.free_conns. Every
			// field a fresh ConnState would have must be reset here so no stale
			// state (deadlines, sendfile offsets, body_drain, awaiting_fd) bleeds
			// into the next connection that reuses this slot.
			unsafe {
				cs.read_buf.len = 0
				cs.write_buf.len = 0
			}
			cs.write_off = 0
			cs.read_deadline = 0
			cs.write_deadline = 0
			cs.idle_deadline = 0
			cs.file_fd = -1
			cs.file_off = 0
			cs.file_remaining = 0
			cs.body_drain = 0
			cs.drain_off = 0
			cs.awaiting_fd = -1
			cs.close_after_flush = false
			cs.sent_100 = false
			cs.takeover = unsafe { nil }
			cs.takeover_state = unsafe { nil }
			st.conns[fd] = unsafe { nil }
			st.free_conns << cs
		}
	}
	if st.births && fd < st.closed_at.len {
		// Later events for fd in this batch, and birth-queue entries queued
		// before this close, are stale (closed_in_batch, drain_births). A plain
		// store: an indexed assignment compiles to a generic element copy.
		st.close_seq++
		unsafe {
			*(&u64(st.closed_at.data) + fd) = st.close_seq
		}
		if st.births_q != unsafe { nil } {
			// Before the close below frees the number: the accept thread reads
			// it after accept() returns that number again (drain_births).
			stdatomic.store_u64(&st.births_q.close_seq, st.close_seq)
		}
	}
	release_conn(epoll_fd, fd, active_conns)
}
