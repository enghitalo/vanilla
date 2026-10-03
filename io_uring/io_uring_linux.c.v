module io_uring

import core
// For C.atomic_load_u32 / C.atomic_store_u32 on the ring indices the kernel
// shares with us (see peek_batch_cqe, cq_advance, cq_needs_flush).
import sync.stdatomic as _

#include <netinet/tcp.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>

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
// timerfd, ...) armed by the watch runtime (Worker.watch). Its user_data packs
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
// Tried first by queue_init on every ring (see there).
const setup_no_sqarray = u32(1 << 16)

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

// ==================== Kernel ring (no liburing) ====================
//
// The ring is driven straight through the three io_uring syscalls
// (io_uring_setup / io_uring_enter / io_uring_register) and the SQ/CQ rings
// they mmap, so a binary that imports `server` needs neither liburing's headers
// to build nor liburing.so to start (#189). The structs are the kernel ABI from
// include/uapi/linux/io_uring.h, declared here rather than taken from
// <linux/io_uring.h> so the build does not depend on the kernel-header version;
// io_uring_abi_linux_test.v checks every size, offset and constant against the
// header. Function names and semantics follow liburing's (2.x), which this
// replaces, for the subset vanilla uses. SQPOLL is never set, so the kernel
// touches the SQ only inside io_uring_enter, on the ring's own thread.

// Sqe is struct io_uring_sqe (64 bytes). Each kernel union is flattened to the
// member vanilla writes; the comment lists the members it overlays. prepare_*
// assign a whole Sqe literal, so every field not named there is zeroed.
pub struct Sqe {
pub mut:
	opcode      u8
	flags       u8
	ioprio      u16
	fd          i32
	off         u64 // off | addr2
	addr        u64 // addr | splice_off_in
	len         u32
	op_flags    u32 // rw_flags | msg_flags | accept_flags | poll32_events | timeout_flags | ...
	user_data   u64
	buf_index   u16 // buf_index | buf_group
	personality u16
	file_index  u32 // splice_fd_in | file_index | optlen | addr_len
	addr3       u64
	pad2        u64
}

// Cqe is struct io_uring_cqe (16 bytes; vanilla never sets CQE32).
pub struct Cqe {
pub:
	user_data u64
	res       i32
	flags     u32
}

// Relative timeout for submit_and_wait_timeout (struct __kernel_timespec).
pub struct KernelTimespec {
pub mut:
	tv_sec  i64
	tv_nsec i64
}

// struct io_sqring_offsets / io_cqring_offsets: where each ring field lives in
// the mmap'd ring, filled by io_uring_setup.
struct SqringOffsets {
	head         u32
	tail         u32
	ring_mask    u32
	ring_entries u32
	flags        u32
	dropped      u32
	array        u32
	resv1        u32
	user_addr    u64
}

struct CqringOffsets {
	head         u32
	tail         u32
	ring_mask    u32
	ring_entries u32
	overflow     u32
	cqes         u32
	flags        u32
	resv1        u32
	user_addr    u64
}

// struct io_uring_params: `flags` goes in, the kernel fills the rest.
struct Params {
	sq_entries     u32
	cq_entries     u32
	flags          u32
	sq_thread_cpu  u32
	sq_thread_idle u32
	features       u32
	wq_fd          u32
	resv           [3]u32
	sq_off         SqringOffsets
	cq_off         CqringOffsets
}

// struct io_uring_getevents_arg, the IORING_ENTER_EXT_ARG argument.
struct GeteventsArg {
	sigmask       u64
	sigmask_sz    u32
	min_wait_usec u32
	ts            u64
}

// struct io_uring_rsrc_update, the IORING_(UN)REGISTER_RING_FDS argument.
struct RsrcUpdate {
mut:
	offset u32
	resv   u32
	data   u64
}

// Kernel ABI constants (include/uapi/linux/io_uring.h).
const ioring_op_poll_add = u8(6)
const ioring_op_timeout = u8(11)
const ioring_op_accept = u8(13)
const ioring_op_send = u8(26)
const ioring_op_recv = u8(27)
const ioring_accept_multishot = u16(1 << 0)
const ioring_off_sq_ring = isize(0)
const ioring_off_cq_ring = isize(0x8000000)
const ioring_off_sqes = isize(0x10000000)
const ioring_feat_single_mmap = u32(1 << 0)
const ioring_feat_ext_arg = u32(1 << 8)
const ioring_enter_getevents = u32(1 << 0)
const ioring_enter_ext_arg = u32(1 << 3)
const ioring_enter_registered_ring = u32(1 << 4)
const ioring_register_ring_fds = 20
const ioring_unregister_ring_fds = 21
const ioring_sq_cq_overflow = u32(1 << 1)
const ioring_sq_taskrun = u32(1 << 2)
// sizeof(sigset_t) as the kernel sees it (_NSIG / 8), as liburing passes it.
const sigset_size = u32(8)

// user_data of the IORING_OP_TIMEOUT SQE that submit_and_wait_timeout queues on
// kernels without IORING_FEAT_EXT_ARG (liburing's LIBURING_UDATA_TIMEOUT). Its op
// bits decode to no op_* type, so the CQE dispatcher ignores it.
pub const timeout_user_data = u64(0xFFFF_FFFF_FFFF_FFFF)

// Ring is one io_uring instance: the ring fd plus the SQ/CQ the kernel shares
// through mmap (liburing's struct io_uring). Only the worker thread that owns
// it touches it.
pub struct Ring {
mut:
	sq_khead    &u32 = unsafe { nil }
	sq_ktail    &u32 = unsafe { nil }
	sq_kflags   &u32 = unsafe { nil }
	sqes        &Sqe = unsafe { nil }
	sq_mask     u32
	sq_entries  u32
	sqe_head    u32 // [sqe_head, sqe_tail) are filled but not yet published to the kernel
	sqe_tail    u32
	cq_khead    &u32 = unsafe { nil }
	cq_ktail    &u32 = unsafe { nil }
	cqes        &Cqe = unsafe { nil }
	cq_mask     u32
	sq_ring     voidptr
	sq_ring_sz  usize
	cq_ring     voidptr // == sq_ring when the kernel maps both rings at once
	cq_ring_sz  usize
	features    u32
	ring_fd     int = -1
	enter_fd    int = -1 // ring_fd, or its registered index after register_ring_fd
	enter_flags u32 // IORING_ENTER_REGISTERED_RING once registered
}

// queue_init sets `ring` up with `entries` SQ slots and the IORING_SETUP_*
// `flags` (liburing's io_uring_queue_init_params). Like liburing it first asks
// for IORING_SETUP_NO_SQARRAY (kernel 6.6+: the kernel reads SQEs in ring order,
// with no index array) and retries without it if the kernel rejects that.
// Returns 0, or -errno with `ring` untouched.
pub fn queue_init(entries u32, ring &Ring, flags u32) int {
	ret := setup_ring(entries, ring, flags | setup_no_sqarray)
	if ret != -C.EINVAL {
		return ret
	}
	return setup_ring(entries, ring, flags)
}

fn setup_ring(entries u32, ring &Ring, flags u32) int {
	p := Params{
		flags: flags
	}
	fd := unsafe { C.syscall(C.SYS_io_uring_setup, entries, &p) }
	if fd < 0 {
		return -C.errno
	}
	mut sq_ring_sz := usize(p.sq_off.array) + usize(p.sq_entries) * sizeof(u32)
	mut cq_ring_sz := usize(p.cq_off.cqes) + usize(p.cq_entries) * sizeof(Cqe)
	single_mmap := p.features & ioring_feat_single_mmap != 0
	if single_mmap {
		if cq_ring_sz > sq_ring_sz {
			sq_ring_sz = cq_ring_sz
		}
		cq_ring_sz = sq_ring_sz
	}
	sq_ring := map_ring(fd, sq_ring_sz, ioring_off_sq_ring)
	if sq_ring == unsafe { nil } {
		err := -C.errno
		C.close(fd)
		return err
	}
	mut cq_ring := sq_ring
	if !single_mmap {
		cq_ring = map_ring(fd, cq_ring_sz, ioring_off_cq_ring)
		if cq_ring == unsafe { nil } {
			err := -C.errno
			unsafe { C.munmap(sq_ring, sq_ring_sz) }
			C.close(fd)
			return err
		}
	}
	sqes := map_ring(fd, usize(p.sq_entries) * sizeof(Sqe), ioring_off_sqes)
	if sqes == unsafe { nil } {
		err := -C.errno
		unsafe {
			if !single_mmap {
				C.munmap(cq_ring, cq_ring_sz)
			}
			C.munmap(sq_ring, sq_ring_sz)
		}
		C.close(fd)
		return err
	}
	mut r := unsafe { &Ring(ring) }
	unsafe {
		sq := &u8(sq_ring)
		cq := &u8(cq_ring)
		r.sq_khead = &u32(sq + p.sq_off.head)
		r.sq_ktail = &u32(sq + p.sq_off.tail)
		r.sq_kflags = &u32(sq + p.sq_off.flags)
		r.sq_mask = *&u32(sq + p.sq_off.ring_mask)
		r.sq_entries = *&u32(sq + p.sq_off.ring_entries)
		r.cq_khead = &u32(cq + p.cq_off.head)
		r.cq_ktail = &u32(cq + p.cq_off.tail)
		r.cq_mask = *&u32(cq + p.cq_off.ring_mask)
		r.cqes = &Cqe(cq + p.cq_off.cqes)
		r.sqes = &Sqe(sqes)
		if flags & setup_no_sqarray == 0 {
			// The kernel reads SQ slot i through array[i]: point slot i at SQE i, once.
			array := &u32(sq + p.sq_off.array)
			for i in u32(0) .. r.sq_entries {
				array[i] = i
			}
		}
	}
	r.sqe_head = 0
	r.sqe_tail = 0
	r.sq_ring = sq_ring
	r.sq_ring_sz = sq_ring_sz
	r.cq_ring = cq_ring
	r.cq_ring_sz = cq_ring_sz
	r.features = p.features
	r.ring_fd = fd
	r.enter_fd = fd
	r.enter_flags = 0
	return 0
}

// map_ring maps one region of a new ring; nil on failure, with errno set.
fn map_ring(fd int, size usize, offset isize) voidptr {
	ptr := unsafe {
		C.mmap(nil, size, C.PROT_READ | C.PROT_WRITE, C.MAP_SHARED | C.MAP_POPULATE, fd, offset)
	}
	if isize(ptr) == -1 { // MAP_FAILED
		return unsafe { nil }
	}
	return ptr
}

// queue_exit unmaps and closes a ring set up by queue_init (io_uring_queue_exit).
pub fn queue_exit(ring &Ring) {
	mut r := unsafe { &Ring(ring) }
	if r.ring_fd < 0 {
		return
	}
	if r.enter_flags & ioring_enter_registered_ring != 0 {
		up := RsrcUpdate{
			offset: u32(r.enter_fd)
		}
		unsafe { C.syscall(C.SYS_io_uring_register, r.ring_fd, ioring_unregister_ring_fds, &up, 1) }
	}
	unsafe {
		C.munmap(r.sqes, usize(r.sq_entries) * sizeof(Sqe))
		if r.cq_ring != r.sq_ring {
			C.munmap(r.cq_ring, r.cq_ring_sz)
		}
		C.munmap(r.sq_ring, r.sq_ring_sz)
	}
	C.close(r.ring_fd)
	unsafe {
		*r = Ring{}
	}
}

// register_ring_fd registers the ring fd so each io_uring_enter skips the
// fget/fput on it (io_uring_register_ring_fd, kernel 5.18+). Returns 1 on
// success, else -errno; the ring keeps working unregistered.
pub fn register_ring_fd(ring &Ring) int {
	mut r := unsafe { &Ring(ring) }
	if r.enter_flags & ioring_enter_registered_ring != 0 {
		return -C.EEXIST
	}
	up := RsrcUpdate{
		offset: u32(0xFFFF_FFFF) // -1: the kernel picks the slot and writes it back
		data:   u64(r.ring_fd)
	}
	ret := unsafe { C.syscall(C.SYS_io_uring_register, r.ring_fd, ioring_register_ring_fds, &up, 1) }
	if ret < 0 {
		return -C.errno
	}
	if ret == 1 {
		r.enter_fd = int(up.offset)
		r.enter_flags = ioring_enter_registered_ring
	}
	return ret
}

// get_sqe returns the next free SQE, or nil when the SQ is full
// (io_uring_get_sqe). The caller assigns the whole SQE (prepare_*). The kernel
// advances the SQ head only inside our own io_uring_enter, so a plain load is
// enough here.
@[inline]
fn get_sqe(ring &Ring) &Sqe {
	mut r := unsafe { &Ring(ring) }
	tail := r.sqe_tail
	if tail - unsafe { *r.sq_khead } >= r.sq_entries {
		return unsafe { nil }
	}
	r.sqe_tail = tail + 1
	return unsafe { &r.sqes[tail & r.sq_mask] }
}

// flush_sq publishes the SQEs filled since the last flush and returns how many
// the kernel has not consumed yet (liburing's __io_uring_flush_sq). The kernel
// reads the tail only inside io_uring_enter, which orders this plain store.
@[inline]
fn flush_sq(mut r Ring) u32 {
	tail := r.sqe_tail
	if r.sqe_head != tail {
		r.sqe_head = tail
		unsafe {
			*r.sq_ktail = tail
		}
	}
	return tail - unsafe { *r.sq_khead }
}

// cq_needs_flush reports whether the kernel holds completions back (a CQ
// overflow backlog, or task work flagged by COOP_TASKRUN) that only an
// io_uring_enter(GETEVENTS) posts (liburing's cq_ring_needs_flush).
@[inline]
fn cq_needs_flush(r &Ring) bool {
	return C.atomic_load_u32(r.sq_kflags) & (ioring_sq_cq_overflow | ioring_sq_taskrun) != 0
}

// enter calls io_uring_enter on the ring, through its registered index once
// register_ring_fd succeeded. Returns the syscall result, or -errno.
fn enter(r &Ring, to_submit u32, min_complete u32, flags u32, arg voidptr, argsz usize) int {
	ret := unsafe {
		C.syscall(C.SYS_io_uring_enter, r.enter_fd, to_submit, min_complete, flags | r.enter_flags,
			arg, argsz)
	}
	if ret < 0 {
		return -C.errno
	}
	return ret
}

// submit hands the queued SQEs to the kernel (io_uring_submit). Returns how many
// were submitted, or -errno; makes no syscall when there is nothing to do.
pub fn submit(ring &Ring) int {
	mut r := unsafe { &Ring(ring) }
	to_submit := flush_sq(mut r)
	flush_cq := cq_needs_flush(r)
	if to_submit == 0 && !flush_cq {
		return 0
	}
	return enter(r, to_submit, 0, if flush_cq { ioring_enter_getevents } else { u32(0) },
		unsafe { nil }, 0)
}

// submit_and_wait hands the queued SQEs to the kernel and blocks until at least
// `wait_nr` (>= 1) completions are ready, in one io_uring_enter
// (io_uring_submit_and_wait). With DEFER_TASKRUN this is also what runs the
// deferred task work, so the CQ is populated before it is peeked. Returns how
// many SQEs were submitted, or -errno.
pub fn submit_and_wait(ring &Ring, wait_nr u32) int {
	mut r := unsafe { &Ring(ring) }
	return enter(r, flush_sq(mut r), wait_nr, ioring_enter_getevents, unsafe { nil }, 0)
}

// submit_and_wait_timeout is submit_and_wait that also returns once `ts` has
// elapsed with no completion; that is -ETIME when nothing was submitted
// (io_uring_submit_and_wait_timeout). Kernels before 5.11 lack
// IORING_FEAT_EXT_ARG: there, as in liburing, the timeout goes in as an
// IORING_OP_TIMEOUT SQE (user_data timeout_user_data, which the dispatcher
// ignores), and `ts` must stay valid until its CQE arrives.
pub fn submit_and_wait_timeout(ring &Ring, wait_nr u32, ts &KernelTimespec) int {
	mut r := unsafe { &Ring(ring) }
	if r.features & ioring_feat_ext_arg != 0 {
		arg := GeteventsArg{
			sigmask_sz: sigset_size
			ts:         u64(voidptr(ts))
		}
		return enter(r, flush_sq(mut r), wait_nr, ioring_enter_getevents | ioring_enter_ext_arg,
			&arg, sizeof(GeteventsArg))
	}
	mut sqe := get_sqe(r)
	if sqe == unsafe { nil } {
		ret := submit(r)
		if ret < 0 {
			return ret
		}
		sqe = get_sqe(r)
		if sqe == unsafe { nil } {
			return -C.EAGAIN
		}
	}
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_timeout
			fd:        -1
			off:       u64(wait_nr)
			addr:      u64(voidptr(ts))
			len:       1
			user_data: timeout_user_data
		}
	}
	return submit_and_wait(r, wait_nr)
}

// peek_batch_cqe stores pointers to up to `count` ready CQEs in `cqes` and
// returns how many (io_uring_peek_batch_cqe). It does not consume them: pair it
// with one cq_advance(n) once the batch is dispatched. When the CQ is empty but
// the kernel holds completions back (see cq_needs_flush), one
// io_uring_enter(GETEVENTS) posts them first.
pub fn peek_batch_cqe(ring &Ring, cqes &&Cqe, count u32) u32 {
	mut flushed := false
	for {
		head := unsafe { *ring.cq_khead }
		// The kernel publishes CQEs by advancing the tail: load it before reading them.
		ready := C.atomic_load_u32(ring.cq_ktail) - head
		if ready > 0 {
			n := if ready < count { ready } else { count }
			for i in u32(0) .. n {
				unsafe {
					cqes[i] = &ring.cqes[(head + i) & ring.cq_mask]
				}
			}
			return n
		}
		if flushed || !cq_needs_flush(ring) {
			return 0
		}
		enter(ring, 0, 0, ioring_enter_getevents, unsafe { nil }, 0)
		flushed = true
	}
	return 0
}

// cq_advance hands `nr` consumed CQEs back to the kernel (io_uring_cq_advance).
// The atomic store orders every read of those CQEs before the kernel can reuse
// their slots.
@[inline]
pub fn cq_advance(ring &Ring, nr u32) {
	if nr > 0 {
		C.atomic_store_u32(ring.cq_khead, unsafe { *ring.cq_khead } + nr)
	}
}

// htonl function converts a u_long from host to TCP/IP network byte order (which is big-endian).
// htonl() function converts the unsigned long integer hostlong from host byte order to network byte order.
fn C.htonl(hostlong u32) u32

@[typedef]
pub struct C.pthread_t {
	data u64
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

	// Monotonic-ns deadlines, >0 while armed. read_deadline bounds the waits for
	// request bytes that a Limits timeout covers: from accept for the first
	// request (read_timeout), from the first byte for a later one that arrives
	// partial (read_timeout), and, while `idle` is set, the keep-alive wait for
	// the next request's first byte (idle budget). write_deadline runs while a response batch has not finished sending
	// (write_timeout). The timeout sweep half-closes (shutdown) past-deadline
	// connections; the in-flight recv/send then completes with an error and the
	// normal path frees the slot.
	read_deadline  u64
	write_deadline u64

	// Set when the pending batch ends a malformed/oversized request: once it has
	// been sent, release the connection instead of posting the next recv.
	close_after_send bool
	// True while read_deadline is an IDLE deadline: a recv is in flight, read_buf
	// is empty and no byte of the next request has arrived. The first byte clears
	// it together with the deadline.
	idle bool

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
	// (Worker.watch returned .suspend awaiting this external fd). A parked
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
	ring          Ring
	cpu_id        int
	tid           C.pthread_t
	socket_fd     int
	use_multishot bool
	verbose       bool
	conns         []Connection
	free_stack    []int
	free_top      int
	// Lowest conns index ever handed out. pool_acquire hands slots out top-down
	// and reuses released ones first, so only [used_lo, conns.len) can be live —
	// the deadline sweep scans just that range (it tracks peak concurrency, not
	// max_conn_per_worker).
	used_lo int
	// Keep-alive idle budget in ns, resolved once at worker start from
	// Limits.idle_ms(); 0 ⇒ no idle deadlines.
	idle_ns u64
	// Graceful-shutdown plumbing (set in io_uring_worker_main):
	//   inflight — this worker's own in-flight counter (requests being handled,
	//     posted response sends, connections parked on a watch); Server.shutdown()
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
	w.used_lo = max_conn_per_worker

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
	if idx < w.used_lo {
		w.used_lo = idx
	}
	mut c := &w.conns[idx]
	c.fd = fd
	unsafe {
		c.owner = &w
	}
	c.bytes_sent = 0
	c.close_after_send = false
	c.idle = false
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
	c.idle = false
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
pub fn prepare_accept(ring &Ring, socket_fd int, multishot bool) bool {
	sqe := get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_accept
			ioprio:    if multishot { ioring_accept_multishot } else { u16(0) }
			fd:        socket_fd
			op_flags:  if multishot { u32(C.SOCK_NONBLOCK) } else { u32(0) }
			user_data: encode_user_data(op_accept, nil)
		}
	}
	return true
}

// prepare_recv posts a recv that APPENDS into read_buf's spare capacity (so a
// request split across TCP segments, or pipelined behind another, accumulates
// rather than overwriting). The buffer doubles when full. The data pointer is
// captured now and the connection has exactly one op in flight at a time, so it
// stays valid for the recv's whole duration. Returns false if the SQ is full.
@[direct_array_access]
pub fn prepare_recv(ring &Ring, mut c Connection) bool {
	sqe := get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	if c.read_buf.len == c.read_buf.cap {
		unsafe { c.read_buf.grow_cap(c.read_buf.cap) }
	}
	spare := c.read_buf.cap - c.read_buf.len
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_recv
			fd:        c.fd
			addr:      u64(&u8(c.read_buf.data) + c.read_buf.len)
			len:       u32(spare)
			user_data: encode_user_data(op_read, &c)
		}
	}
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
pub fn prepare_recv_n(ring &Ring, mut c Connection, n usize) bool {
	sqe := get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	mut want := n
	if want > usize(c.read_buf.cap) {
		want = usize(c.read_buf.cap)
	}
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_recv
			fd:        c.fd
			addr:      u64(c.read_buf.data)
			len:       u32(want)
			user_data: encode_user_data(op_read, &c)
		}
	}
	return true
}

// prepare_send posts a send for [data, data+data_len). MSG_NOSIGNAL stops a
// write to a dead peer from raising SIGPIPE (matches the epoll backend).
pub fn prepare_send(ring &Ring, mut c Connection, data &u8, data_len usize) bool {
	sqe := get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_send
			fd:        c.fd
			addr:      u64(data)
			len:       u32(data_len)
			op_flags:  u32(C.MSG_NOSIGNAL)
			user_data: encode_user_data(op_write, &c)
		}
	}
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
pub fn prepare_poll(ring &Ring, fd int, poll_mask u32) bool {
	sqe := get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	mut mask := poll_mask
	$if big_endian {
		// poll32_events is word-reversed on big-endian (liburing's __io_uring_prep_poll_mask).
		mask = (mask << 16) | (mask >> 16)
	}
	unsafe {
		*sqe = Sqe{
			opcode:    ioring_op_poll_add
			fd:        fd
			op_flags:  mask
			user_data: encode_user_data(op_poll, voidptr(usize(fd)))
		}
	}
	return true
}

// io_uring_available reports whether this process can actually set up an io_uring
// instance RIGHT NOW — see io_uring_available_for. Callers that will run the full
// backend should prefer io_uring_available_for(n_workers).
pub fn io_uring_available() bool {
	return io_uring_available_for(1)
}

// io_uring_available_for reports whether this process can set up `workers`
// io_uring instances CONCURRENTLY, right now, each at the smallest ring size the
// worker init ladder accepts (256 entries, default flags — the ladder's last
// resort, so success here means every worker will negotiate at least that). It
// holds all probe rings at once before tearing them down because the failure
// modes are cumulative, not per-ring: a false positive from a one-ring probe is
// exactly how a constrained host (tight memlock/memcg, or a sandbox that allows
// io_uring_setup but caps it — GitHub hosted runners started doing this) lets
// worker 0 up but kills worker N mid-startup. Returns false when the kernel is
// too old, the syscall is sandbox-blocked, or the host can't hold all rings.
// Costs a handful of syscalls and leaks nothing; off the hot path.
pub fn io_uring_available_for(workers int) bool {
	n := if workers < 1 { 1 } else { workers }
	mut rings := []Ring{len: n}
	mut ok := 0
	for i in 0 .. n {
		if queue_init(min_probe_ring_entries, unsafe { &rings[i] }, 0) != 0 {
			break
		}
		ok++
	}
	for i in 0 .. ok {
		queue_exit(unsafe { &rings[i] })
	}
	return ok == n
}

// min_probe_ring_entries mirrors the smallest candidate in the backend's
// iou_init_ring fallback ladder (server_io_uring_linux.c.v).
pub const min_probe_ring_entries = u32(256)

// ==================== Type Definitions ====================

pub type WorkerFn = fn (&Worker) voidptr
