// sudo apt update && sudo apt upgrade -y linux-generic
// git clone git@github.com:axboe/liburing.git
// cd liburing
// ./configure
// make
// sudo make install

module io_uring

import http_server.core

#include <liburing.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#flag -luring

// ==================== C Function Declarations ====================

// Socket functions
fn C.socket(domain int, typ int, protocol int) int
fn C.setsockopt(sockfd int, level int, optname int, optval voidptr, optlen u32) int
fn C.bind(sockfd int, addr voidptr, addrlen u32) int
fn C.listen(sockfd int, backlog int) int
fn C.close(fd int) int

// Network byte order
fn C.htons(hostshort u16) u16
fn C.htonl(hostlong u32) u32

// File control
fn C.fcntl(fd int, cmd int, arg int) int

// Error handling
fn C.perror(s &char)

// ==================== Constants ====================

// Server configuration
pub const inaddr_any = u32(0)
pub const default_port = 8080
// SQ entries per worker ring. CQ defaults to 2x (= 32768 >= max_conn_per_worker)
// so completions never overflow even with one in-flight recv per connection.
pub const default_ring_entries = 16384

// Derived constants
pub const max_conn_per_worker = default_ring_entries * 2

// Persistent per-connection buffers (allocated on acquire, freed on release).
// read_buf accumulates request bytes across recvs — framing across TCP
// segments AND HTTP/1.1 pipelining; write_buf accumulates the batched responses.
pub const read_buf_cap = 8 * 1024
pub const write_buf_cap = 16 * 1024

// How many CQE pointers to copy out of the ring per peek_batch call. The drain
// loop submits queued SQEs between full batches, so the SQ (default_ring_entries)
// can never overflow no matter how many completions are ready at once.
pub const drain_batch = 256

// Operation types for user_data encoding
pub const op_accept = u8(1)
pub const op_read = u8(2)
pub const op_write = u8(3)
// op_poll: a oneshot IORING_OP_POLL_ADD on an EXTERNAL fd (a watched DB socket,
// timerfd, ...) armed by the watch runtime (Ctx.watch). Its user_data packs
// the WATCHED fd in the pointer bits — NOT a &Connection — because the reactor's
// watch table is fd-indexed and can be reallocated by growth (a packed pointer
// into it would dangle); the fd is stable and re-looked-up on completion.
pub const op_poll = u8(4)

// poll(2) event bits (asm-generic/poll.h; identical values to the epoll bits) for
// prepare_poll masks and for decoding a poll CQE's res (which carries the RETURNED
// EVENT MASK, not a byte count).
pub const pollin = u32(0x001)
pub const pollout = u32(0x004)
pub const pollerr = u32(0x008)
pub const pollhup = u32(0x010)

// IO uring CQE flags
pub const ioring_cqe_f_more = u32(1 << 1)

// io_uring setup flags (include/uapi/linux/io_uring.h). SQPOLL is deliberately
// NOT used: one kernel poll thread per worker oversubscribes the cores the
// workers need. The modern recommended combo is SINGLE_ISSUER | DEFER_TASKRUN
// — each worker owns and drives its own ring from a single thread — and we fall
// back to SINGLE_ISSUER | COOP_TASKRUN, then to plain flags, on older kernels.
pub const setup_coop_taskrun = u32(1 << 8)
pub const setup_single_issuer = u32(1 << 12)
pub const setup_defer_taskrun = u32(1 << 13)

// User data bit masks
const op_type_shift = 48
const ptr_mask = u64(0x0000FFFFFFFFFFFF)

// ==================== User Data Encoding ====================
// Encoding scheme: [63:48]=op type, [47:0]=pointer value
// This allows storing both operation type and connection pointer in a single u64

@[inline]
pub fn encode_user_data(op u8, ptr voidptr) u64 {
	return (u64(op) << op_type_shift) | u64(ptr)
}

@[inline]
pub fn decode_op_type(data u64) u8 {
	return u8(data >> op_type_shift)
}

@[inline]
pub fn decode_connection_ptr(data u64) voidptr {
	return voidptr(data & ptr_mask)
}

// decode_ext_fd recovers the watched fd an op_poll CQE was tagged with (see
// prepare_poll: the pointer bits carry the fd, not a &Connection).
@[inline]
pub fn decode_ext_fd(data u64) int {
	return int(data & ptr_mask)
}

// ==================== C Bindings ====================

// io_uring structures and functions
pub struct C.io_uring {
	mu            int
	cq            int
	sq            int
	ring_fd       int
	compat        int
	int_flags     u32
	pad           [1]u8
	enter_ring_fd int
}

pub struct C.io_uring_sqe {}

// Relative timeout for io_uring_submit_and_wait_timeout (kernel ABI struct).
pub struct C.__kernel_timespec {
pub mut:
	tv_sec  i64
	tv_nsec i64
}

pub struct C.io_uring_cqe {
	user_data u64
	res       i32
	flags     u32
}

// io_uring_params. Field access is by name against the real C struct (this is a
// `C.` type, so the kernel header in <liburing.h> defines the true layout); we
// only declare the fields we touch. `features` is filled by the kernel on init.
pub struct C.io_uring_params {
	flags          u32
	sq_thread_cpu  u32
	sq_thread_idle u32
	features       u32
}

pub struct C.cpu_set_t {
	val [16]u64
}

// C function bindings
fn C.io_uring_queue_init_params(entries u32, ring &C.io_uring, p &C.io_uring_params) int
fn C.io_uring_queue_exit(ring &C.io_uring)
fn C.io_uring_get_sqe(ring &C.io_uring) &C.io_uring_sqe
fn C.io_uring_prep_accept(sqe &C.io_uring_sqe, fd int, addr voidptr, addrlen voidptr, flags int)
fn C.io_uring_prep_multishot_accept(sqe &C.io_uring_sqe, fd int, addr voidptr, addrlen voidptr, flags int)
fn C.io_uring_sqe_set_data64(sqe &C.io_uring_sqe, data u64)
fn C.io_uring_prep_recv(sqe &C.io_uring_sqe, fd int, buf voidptr, nbytes usize, flags int)
fn C.io_uring_prep_send(sqe &C.io_uring_sqe, fd int, buf voidptr, nbytes usize, flags int)
fn C.io_uring_prep_poll_add(sqe &C.io_uring_sqe, fd int, poll_mask u32)
fn C.io_uring_submit(ring &C.io_uring) int

// One syscall per loop iteration: flush every SQE queued since the last call
// AND block until at least wait_nr completions are ready. With DEFER_TASKRUN
// this is also what runs the deferred task work, so the CQ is populated before
// we peek it.
fn C.io_uring_submit_and_wait(ring &C.io_uring, wait_nr u32) int

// Like submit_and_wait, but wakes after `ts` even with no completion (returns
// -ETIME). Used to drive a periodic connection-timeout sweep without a busy poll.
fn C.io_uring_submit_and_wait_timeout(ring &C.io_uring, cqe_ptr &&C.io_uring_cqe, wait_nr u32, ts &C.__kernel_timespec, sigmask voidptr) int
fn C.io_uring_wait_cqe(ring &C.io_uring, cqe_ptr &&C.io_uring_cqe) int
fn C.io_uring_peek_cqe(ring &C.io_uring, cqe_ptr &&C.io_uring_cqe) int

// Copy up to `count` ready CQE pointers out of the ring in one shot; returns how
// many were copied. Paired with a single cq_advance(n) — never cqe_seen per CQE.
fn C.io_uring_peek_batch_cqe(ring &C.io_uring, cqes &&C.io_uring_cqe, count u32) u32
fn C.io_uring_cqe_seen(ring &C.io_uring, cqe &C.io_uring_cqe)

// Acknowledge a whole batch of CQEs at once (advance the CQ head by nr).
fn C.io_uring_cq_advance(ring &C.io_uring, nr u32)
fn C.io_uring_cqe_get_data64(cqe &C.io_uring_cqe) u64

// Register the ring fd so io_uring_enter skips the per-call fget/fput.
fn C.io_uring_register_ring_fd(ring &C.io_uring) int

// htonl function converts a u_long from host to TCP/IP network byte order (which is big-endian).
// htonl() function converts the unsigned long integer hostlong from host byte order to network byte order.
fn C.htonl(hostlong u32) u32

@[typedef]
pub struct C.pthread_t {
	data u64
}

@[typedef]
pub struct C.sigaction {
	sa_handler  voidptr
	sa_mask     u64
	sa_flags    int
	sa_restorer voidptr
}

// ==================== Connection Structure ====================

// Represents a client connection with request/response state. The buffers are
// persistent: allocated once on acquire, reused across every request on the
// connection, and freed on release. read_buf accumulates request bytes across
// recvs (TCP-segment reassembly + HTTP/1.1 pipelining); response_buffer holds
// every response produced this burst, flushed in one batched send.
pub struct Connection {
pub mut:
	// Socket file descriptor
	fd int
	// Backpointer to owning worker (for pool management)
	owner &Worker = unsafe { nil }

	// Request state: bytes buffered = read_buf.len; recv appends into spare cap.
	read_buf []u8

	// Response state: [bytes_sent..response_buffer.len) is still pending.
	response_buffer []u8
	bytes_sent      int

	// Monotonic-ns deadlines, >0 while the corresponding direction is mid-transfer:
	// read_deadline while a partial request is mid-read (read_timeout), write_deadline
	// while a response batch has not finished sending (write_timeout). The timeout
	// sweep half-closes (shutdown) past-deadline connections; the in-flight recv/send
	// then completes with an error and the normal path frees the slot.
	read_deadline  u64
	write_deadline u64

	// Set when the pending batch ends a malformed/oversized request: once it has
	// been sent, release the connection instead of posting the next recv.
	close_after_send bool

	// >0 while a large upload body is being STREAMED: the head was already answered
	// (its response held in response_buffer) and the remaining `body_drain` body
	// bytes are recv'd into read_buf's base buffer and DISCARDED — keeping a
	// multi-MB upload at O(read_buf_cap) memory instead of buffering the whole body.
	// recv is length-clamped to this remainder so the drain never reads past the
	// body into the next pipelined request. Once it hits 0 the held response is sent.
	body_drain i64

	// Borrowed-buffer send (queue_buf): when send_buf != nil the whole response is
	// a single borrowed, immutable, process-lifetime buffer (a preloaded static
	// asset) sent DIRECTLY rather than copied through response_buffer — keeping
	// response_buffer at its base cap (no per-request grow/realloc churn, no
	// per-conn balloon). [bytes_sent..send_total) is still pending. The buffer is
	// borrowed: never freed or modified here, and guaranteed to outlive the send.
	send_buf   voidptr
	send_total int

	// >= 0 while a request on this connection is PARKED on the async runtime
	// (Ctx.watch returned .suspend awaiting this external fd). A parked
	// connection has NO client-side op in flight — no recv (so the slot cannot be
	// freed under a stale CQE) and no send (responses buffered before/at the park
	// are HELD in response_buffer until resume: an in-flight send's captured data
	// pointer would dangle if a resume appended to, and thereby reallocated, the
	// buffer). The op_poll CQE on awaiting_fd is what eventually resumes it.
	awaiting_fd int = -1
}

// ==================== Worker Structure ====================

pub struct Worker {
pub mut:
	ring          C.io_uring
	cpu_id        int
	tid           C.pthread_t
	socket_fd     int
	use_multishot bool
	verbose       bool
	conns         []Connection
	free_stack    []int
	free_top      int
	// Graceful-shutdown plumbing (set in io_uring_worker_main):
	//   inflight — this worker's own in-flight-response counter; Server.shutdown()
	//     sums all workers' counters to drain precisely. nil ⇒ not tracked.
	//   draining — shared flag set by Server.shutdown(); the accept handler stops
	//     re-arming once it is non-zero, so the worker quits accepting. nil ⇒ off.
	inflight &core.Counter = unsafe { nil }
	draining &core.Counter = unsafe { nil }
}

// ==================== Connection Pool ====================

// Initialize connection pool for a worker
pub fn pool_init(mut w Worker) {
	// Pre-allocate all connections
	w.conns = []Connection{len: max_conn_per_worker, init: Connection{}}
	w.free_stack = []int{len: max_conn_per_worker}
	w.free_top = 0

	// Initialize free list (all slots available)
	for i in 0 .. max_conn_per_worker {
		w.free_stack[w.free_top] = i
		w.free_top++
	}
}

// Check if pool has available connections
@[inline]
fn pool_has_capacity(w &Worker) bool {
	return w.free_top > 0
}

@[manualfree]
pub fn pool_acquire(mut w Worker, fd int) &Connection {
	if w.free_top == 0 {
		return unsafe { nil }
	}
	w.free_top--
	idx := w.free_stack[w.free_top]
	mut c := &w.conns[idx]
	c.fd = fd
	unsafe {
		c.owner = &w
	}
	c.bytes_sent = 0
	c.close_after_send = false
	c.read_deadline = 0
	c.write_deadline = 0
	c.body_drain = 0
	c.send_buf = unsafe { nil }
	c.send_total = 0
	c.awaiting_fd = -1
	// Lock-free buffer REUSE: the per-worker pool is single-issuer (only this
	// worker thread ever touches w.conns/free_stack), so a slot's buffers persist
	// across connections with zero atomics. Reuse the pooled buffer (reset len,
	// keep capacity); allocate only on a slot's first-ever use or after a release
	// dropped an oversized buffer. This removes the per-connection 8K+16K
	// malloc/free that showed up as 2 malloc + 2 free per connection under churn
	// (the limited-conn tax), mirroring the epoll backend's free_conns pooling.
	// Lazy (not pre-allocated in pool_init): pooled memory tracks the per-worker
	// high-water concurrency, not max_conn_per_worker (which would be 768 MiB).
	if unsafe { c.read_buf.data == nil } {
		c.read_buf = []u8{len: 0, cap: read_buf_cap}
	} else {
		unsafe {
			c.read_buf.len = 0
		}
	}
	if unsafe { c.response_buffer.data == nil } {
		c.response_buffer = []u8{len: 0, cap: write_buf_cap}
	} else {
		unsafe {
			c.response_buffer.len = 0
		}
	}
	// No manual `.noscan_data` here, on purpose. read_buf/response_buffer are `[]u8`
	// (pointer-free), so under the default GC the compiler picks the no-scan array
	// constructor (`__new_array_with_default_noscan`, gated on `gcboehm_opt`, which
	// `-prod`/`-gc boehm` enable by default), which sets `.noscan_data`; the flag is
	// preserved across `grow_cap`, so the buffers are no-scan automatically and stay
	// no-scan as they grow to hold a large response/upload (since vlang/v 23d47695e,
	// 2026-04). A manual `flags.set(.noscan_data)` would be a no-op in EVERY mode: with
	// `gcboehm_opt` on the constructor already set it; with it off `alloc_array_data_like`
	// gates its no-scan branch behind `$if gcboehm_opt ?` and ignores the flag entirely;
	// under `-gc none` there is no GC. (PR #59's default-on flag — supposedly fixing the
	// io_uring static/upload high-conn collapse — was therefore inert; that collapse is
	// not GC scanning and is still under investigation. PR #60 removed it.)
	return c
}

// pool_release closes the fd, frees the connection's buffers and returns its
// slot to the free stack. It is IDEMPOTENT: clearing `owner` makes a second
// call a no-op, so a connection can never be double-freed (which would hand the
// same slot to two future accepts).
@[manualfree]
pub fn pool_release(mut w Worker, mut c Connection) {
	if unsafe { c.owner == nil } {
		return
	}
	C.close(c.fd)
	// Keep base-sized buffers attached to the slot for lock-free reuse by the next
	// connection that lands on it (see pool_acquire). Only release a buffer that
	// GREW past its base capacity (a large upload/response grew it via grow_cap) so
	// a one-off big request can't pin multi-MB on an otherwise idle pooled slot —
	// pooled idle memory stays bounded at base (8K+16K) per high-water slot.
	if c.read_buf.cap > read_buf_cap {
		unsafe { c.read_buf.free() }
		c.read_buf = []u8{}
	} else {
		unsafe {
			c.read_buf.len = 0
		}
	}
	if c.response_buffer.cap > write_buf_cap {
		unsafe { c.response_buffer.free() }
		c.response_buffer = []u8{}
	} else {
		unsafe {
			c.response_buffer.len = 0
		}
	}
	c.bytes_sent = 0
	c.close_after_send = false
	c.read_deadline = 0
	c.write_deadline = 0
	c.body_drain = 0
	c.send_buf = unsafe { nil }
	c.send_total = 0
	c.awaiting_fd = -1
	c.owner = unsafe { nil }
	unsafe {
		idx := int(u64(&c) - u64(&w.conns[0])) / int(sizeof(Connection))
		if w.free_top < max_conn_per_worker {
			w.free_stack[w.free_top] = idx
			w.free_top++
		}
	}
}

// Wrapper functions that work with const pointers
pub fn pool_acquire_from_ptr(worker &Worker, fd int) &Connection {
	mut w := unsafe { &Worker(worker) }
	return pool_acquire(mut w, fd)
}

pub fn pool_release_from_ptr(worker &Worker, mut c Connection) {
	mut w := unsafe { &Worker(worker) }
	pool_release(mut w, mut c)
}

// ==================== IO Uring Operations ====================

// Prepare accept operation (multishot when supported)
// Returns true if SQE was successfully obtained, false otherwise
pub fn prepare_accept(ring &C.io_uring, socket_fd int, multishot bool) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	if multishot {
		C.io_uring_prep_multishot_accept(sqe, socket_fd, unsafe { nil }, unsafe { nil },
			C.SOCK_NONBLOCK)
	} else {
		C.io_uring_prep_accept(sqe, socket_fd, unsafe { nil }, unsafe { nil }, 0)
	}
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_accept, unsafe { nil }))
	return true
}

// prepare_recv posts a recv that APPENDS into read_buf's spare capacity (so a
// request split across TCP segments, or pipelined behind another, accumulates
// rather than overwriting). The buffer doubles when full. The data pointer is
// captured now and the connection has exactly one op in flight at a time, so it
// stays valid for the recv's whole duration. Returns false if the SQ is full.
@[direct_array_access]
pub fn prepare_recv(ring &C.io_uring, mut c Connection) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	if c.read_buf.len == c.read_buf.cap {
		unsafe { c.read_buf.grow_cap(c.read_buf.cap) }
	}
	spare := c.read_buf.cap - c.read_buf.len
	C.io_uring_prep_recv(sqe, c.fd, unsafe { &u8(c.read_buf.data) + c.read_buf.len }, usize(spare),
		0)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_read, &c))
	return true
}

// prepare_recv_n posts a recv of at most `n` bytes into read_buf's BASE buffer
// (offset 0), used by the large-body drain to consume and DISCARD the body. It
// never grows read_buf and never appends: read_buf.len stays 0 throughout the
// drain (the bytes are thrown away), so the same 8 KiB buffer is reused for the
// whole upload. `n` is the body remainder, clamped to the buffer capacity, so a
// recv never reads past the body into the next pipelined request. Returns false
// if the SQ is full.
@[direct_array_access]
pub fn prepare_recv_n(ring &C.io_uring, mut c Connection, n usize) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	mut want := n
	if want > usize(c.read_buf.cap) {
		want = usize(c.read_buf.cap)
	}
	C.io_uring_prep_recv(sqe, c.fd, c.read_buf.data, want, 0)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_read, &c))
	return true
}

// prepare_send posts a send for [data, data+data_len). MSG_NOSIGNAL stops a
// write to a dead peer from raising SIGPIPE (matches the epoll backend).
pub fn prepare_send(ring &C.io_uring, mut c Connection, data &u8, data_len usize) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	C.io_uring_prep_send(sqe, c.fd, unsafe { data }, data_len, C.MSG_NOSIGNAL)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_write, &c))
	return true
}

// prepare_poll posts a ONESHOT IORING_OP_POLL_ADD on an external fd (a watched DB
// socket / timerfd) for the async runtime. Oneshot on purpose: it fires exactly one
// CQE and is gone — the continuation re-arms per park (mirrors the epoll runtime's
// consume-then-re-arm), so there is never a dangling poll on a pooled fd to cancel
// at release time. POLL_ADD reports CURRENT readiness at submit, so an fd that is
// already readable completes immediately (no lost wakeup). The CQE's res carries
// the returned poll mask (or a negative errno). user_data packs the fd itself, not
// a pointer (see op_poll). Returns false if the SQ is full.
pub fn prepare_poll(ring &C.io_uring, fd int, poll_mask u32) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	C.io_uring_prep_poll_add(sqe, fd, poll_mask)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_poll, voidptr(usize(fd))))
	return true
}

// ==================== Type Definitions ====================

pub type WorkerFn = fn (&Worker) voidptr
