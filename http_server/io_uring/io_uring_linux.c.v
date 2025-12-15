module io_uring

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

// File control
fn C.fcntl(fd int, cmd int, arg int) int

// Error handling
fn C.perror(s &char)

// ==================== Constants ====================

// Server configuration
pub const default_port = 8080
pub const default_backlog = 65535
pub const default_ring_entries = 16384
pub const default_buffer_size = 4096

// Derived constants
pub const max_conn_per_worker = default_ring_entries * 2

// Operation types for user_data encoding
pub const op_accept = u8(1)
pub const op_read = u8(2)
pub const op_write = u8(3)

// IO uring CQE flags
const ioring_cqe_f_more = u32(1 << 1)

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

// Legacy aliases for backward compatibility
pub fn pack(op u8, ptr voidptr) u64 {
	return encode_user_data(op, ptr)
}

pub fn unpack_op(data u64) u8 {
	return decode_op_type(data)
}

pub fn unpack_ptr(data u64) voidptr {
	return decode_connection_ptr(data)
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

pub struct C.io_uring_cqe {
	user_data u64
	res       i32
	flags     u32
}

// Simplified - we just need to zero-initialize
pub struct C.io_uring_params {}

pub struct C.cpu_set_t {
	val [16]u64
}

// C function bindings
fn C.io_uring_queue_init_params(entries u32, ring &C.io_uring, p &C.io_uring_params) int

// fn C.io_uring_queue_exit(ring &C.io_uring)
fn C.io_uring_get_sqe(ring &C.io_uring) &C.io_uring_sqe
fn C.io_uring_prep_multishot_accept(sqe &C.io_uring_sqe, fd int, addr &C.sockaddr_in, addrlen &u32, flags int)
fn C.io_uring_sqe_set_data64(sqe &C.io_uring_sqe, data u64)
fn C.io_uring_prep_recv(sqe &C.io_uring_sqe, fd int, buf voidptr, nbytes usize, flags int)
fn C.io_uring_prep_send(sqe &C.io_uring_sqe, fd int, buf voidptr, nbytes usize, flags int)
fn C.io_uring_submit(ring &C.io_uring) int
fn C.io_uring_wait_cqe(ring &C.io_uring, cqe_ptr &&C.io_uring_cqe) int
fn C.io_uring_peek_cqe(ring &C.io_uring, cqe_ptr &&C.io_uring_cqe) int
fn C.io_uring_cqe_seen(ring &C.io_uring, cqe &C.io_uring_cqe)
fn C.io_uring_cqe_get_data64(cqe &C.io_uring_cqe) u64

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

// Represents a client connection with request/response state
pub struct Connection {
pub mut:
	// Socket file descriptor
	fd int
	// Backpointer to owning worker (for pool management)
	owner &Worker = unsafe { nil }

	// Request state
	buf        [default_buffer_size]u8
	bytes_read int

	// Response state
	response_buffer []u8
	bytes_sent      int

	// Processing flag
	processing bool
}

// ==================== Worker Structure ====================

pub struct Worker {
pub mut:
	ring       C.io_uring
	cpu_id     int
	tid        C.pthread_t
	listen_fd  int
	conns      []Connection
	free_stack []int
	free_top   int
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
	c.bytes_read = 0
	c.bytes_sent = 0
	c.processing = false
	unsafe { c.response_buffer.free() }
	c.response_buffer = []u8{}
	return c
}

pub fn pool_release(mut w Worker, mut c Connection) {
	if unsafe { c.owner == nil } {
		return
	}
	C.close(c.fd)
	unsafe { c.response_buffer.free() }
	c.response_buffer = []u8{}
	c.bytes_read = 0
	c.bytes_sent = 0
	c.processing = false
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

// ==================== Socket Configuration ====================

pub fn tune_socket(fd int) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK)

	one := 1
	C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(int))

	sndbuf := 524288 // 512KB
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_SNDBUF, &sndbuf, sizeof(int))

	rcvbuf := 262144 // 256KB
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_RCVBUF, &rcvbuf, sizeof(int))
}

// ==================== IO Uring Operations ====================

// Prepare multishot accept operation
// Returns true if SQE was successfully obtained, false otherwise
pub fn prepare_accept(ring &C.io_uring, listen_fd int) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	C.io_uring_prep_multishot_accept(sqe, listen_fd, unsafe { nil }, unsafe { nil }, C.SOCK_NONBLOCK)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_accept, unsafe { nil }))
	return true
}

// Prepare receive operation for a connection
pub fn prepare_recv(ring &C.io_uring, mut c Connection) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	C.io_uring_prep_recv(sqe, c.fd, unsafe { &c.buf[0] }, default_buffer_size, 0)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_read, &c))
	return true
}

// Prepare send operation for a connection
pub fn prepare_send(ring &C.io_uring, mut c Connection, data &u8, data_len usize) bool {
	sqe := C.io_uring_get_sqe(ring)
	if unsafe { sqe == nil } {
		return false
	}
	C.io_uring_prep_send(sqe, c.fd, unsafe { data }, data_len, 0)
	C.io_uring_sqe_set_data64(sqe, encode_user_data(op_write, &c))
	return true
}

// Legacy aliases
pub fn prep_accept(ring &C.io_uring, listen_fd int) {
	prepare_accept(ring, listen_fd)
}

pub fn prep_read(ring &C.io_uring, mut c Connection) {
	prepare_recv(ring, mut c)
}

pub fn prep_write(ring &C.io_uring, mut c Connection, resp &u8, resp_len usize) {
	prepare_send(ring, mut c, resp, resp_len)
}

// ==================== Server Setup ====================

pub fn create_listener(port_num int) int {
	lfd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if lfd < 0 {
		C.perror(c'socket')
		return -1
	}

	one := 1
	C.setsockopt(lfd, C.SOL_SOCKET, C.SO_REUSEADDR, &one, sizeof(int))
	C.setsockopt(lfd, C.SOL_SOCKET, C.SO_REUSEPORT, &one, sizeof(int))
	C.setsockopt(lfd, C.IPPROTO_TCP, C.TCP_DEFER_ACCEPT, &one, sizeof(int))

	// Use raw sockaddr_in struct inline with C interop
	mut addr := [16]u8{}
	unsafe {
		// sin_family (u16) at offset 0
		*(&u16(&addr[0])) = u16(C.AF_INET)
		// sin_port (u16) at offset 2
		*(&u16(&addr[2])) = C.htons(u16(port_num))
		// sin_addr.s_addr (u32) at offset 4
		*(&u32(&addr[4])) = C.htonl(C.INADDR_ANY)
	}
	if C.bind(lfd, voidptr(&addr[0]), u32(16)) < 0 {
		C.perror(c'bind')
		C.close(lfd)
		return -1
	}

	if C.listen(lfd, default_backlog) < 0 {
		C.perror(c'listen')
		C.close(lfd)
		return -1
	}

	flags := C.fcntl(lfd, C.F_GETFL, 0)
	C.fcntl(lfd, C.F_SETFL, flags | C.O_NONBLOCK)

	return lfd
}

// ==================== Type Definitions ====================

pub type WorkerFn = fn (&Worker) voidptr
