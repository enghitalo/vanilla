module io_uring

// The kernel ABI this module declares by hand (Sqe, Cqe, Params, ...) checked
// against <linux/io_uring.h>, then a real ring driven through every entry point
// the server uses. The header is included HERE only: the module itself must
// build without it (#189).
import os
import time

#include <linux/io_uring.h>

struct C.io_uring_sqe {
	opcode        u8
	flags         u8
	ioprio        u16
	fd            i32
	off           u64
	addr          u64
	len           u32
	msg_flags     u32
	accept_flags  u32
	poll32_events u32
	timeout_flags u32
	user_data     u64
	buf_index     u16
	personality   u16
	file_index    u32
	addr3         u64
}

struct C.io_uring_cqe {
	user_data u64
	res       i32
	flags     u32
}

struct C.io_sqring_offsets {
	head         u32
	tail         u32
	ring_mask    u32
	ring_entries u32
	flags        u32
	dropped      u32
	array        u32
}

struct C.io_cqring_offsets {
	head         u32
	tail         u32
	ring_mask    u32
	ring_entries u32
	overflow     u32
	cqes         u32
	flags        u32
}

struct C.io_uring_params {
	sq_entries u32
	cq_entries u32
	flags      u32
	features   u32
	sq_off     C.io_sqring_offsets
	cq_off     C.io_cqring_offsets
}

struct C.io_uring_getevents_arg {
	sigmask    u64
	sigmask_sz u32
	ts         u64
}

struct C.io_uring_rsrc_update {
	offset u32
	data   u64
}

struct C.__kernel_timespec {}

fn test_abi_sizes_match_the_kernel_header() {
	assert sizeof(Sqe) == sizeof(C.io_uring_sqe)
	assert sizeof(Cqe) == sizeof(C.io_uring_cqe)
	assert sizeof(Params) == sizeof(C.io_uring_params)
	assert sizeof(SqringOffsets) == sizeof(C.io_sqring_offsets)
	assert sizeof(CqringOffsets) == sizeof(C.io_cqring_offsets)
	assert sizeof(GeteventsArg) == sizeof(C.io_uring_getevents_arg)
	assert sizeof(RsrcUpdate) == sizeof(C.io_uring_rsrc_update)
	assert sizeof(KernelTimespec) == sizeof(C.__kernel_timespec)
}

fn test_abi_offsets_match_the_kernel_header() {
	assert __offsetof(Sqe, opcode) == __offsetof(C.io_uring_sqe, opcode)
	assert __offsetof(Sqe, flags) == __offsetof(C.io_uring_sqe, flags)
	assert __offsetof(Sqe, ioprio) == __offsetof(C.io_uring_sqe, ioprio)
	assert __offsetof(Sqe, fd) == __offsetof(C.io_uring_sqe, fd)
	assert __offsetof(Sqe, off) == __offsetof(C.io_uring_sqe, off)
	assert __offsetof(Sqe, addr) == __offsetof(C.io_uring_sqe, addr)
	assert __offsetof(Sqe, len) == __offsetof(C.io_uring_sqe, len)
	assert __offsetof(Sqe, op_flags) == __offsetof(C.io_uring_sqe, msg_flags)
	assert __offsetof(Sqe, op_flags) == __offsetof(C.io_uring_sqe, accept_flags)
	assert __offsetof(Sqe, op_flags) == __offsetof(C.io_uring_sqe, poll32_events)
	assert __offsetof(Sqe, op_flags) == __offsetof(C.io_uring_sqe, timeout_flags)
	assert __offsetof(Sqe, user_data) == __offsetof(C.io_uring_sqe, user_data)
	assert __offsetof(Sqe, buf_index) == __offsetof(C.io_uring_sqe, buf_index)
	assert __offsetof(Sqe, personality) == __offsetof(C.io_uring_sqe, personality)
	assert __offsetof(Sqe, file_index) == __offsetof(C.io_uring_sqe, file_index)
	assert __offsetof(Sqe, addr3) == __offsetof(C.io_uring_sqe, addr3)

	assert __offsetof(Cqe, user_data) == __offsetof(C.io_uring_cqe, user_data)
	assert __offsetof(Cqe, res) == __offsetof(C.io_uring_cqe, res)
	assert __offsetof(Cqe, flags) == __offsetof(C.io_uring_cqe, flags)

	assert __offsetof(Params, sq_entries) == __offsetof(C.io_uring_params, sq_entries)
	assert __offsetof(Params, cq_entries) == __offsetof(C.io_uring_params, cq_entries)
	assert __offsetof(Params, flags) == __offsetof(C.io_uring_params, flags)
	assert __offsetof(Params, features) == __offsetof(C.io_uring_params, features)
	assert __offsetof(Params, sq_off) == __offsetof(C.io_uring_params, sq_off)
	assert __offsetof(Params, cq_off) == __offsetof(C.io_uring_params, cq_off)

	assert __offsetof(SqringOffsets, head) == __offsetof(C.io_sqring_offsets, head)
	assert __offsetof(SqringOffsets, tail) == __offsetof(C.io_sqring_offsets, tail)
	assert __offsetof(SqringOffsets, ring_mask) == __offsetof(C.io_sqring_offsets, ring_mask)
	assert __offsetof(SqringOffsets, ring_entries) == __offsetof(C.io_sqring_offsets, ring_entries)
	assert __offsetof(SqringOffsets, flags) == __offsetof(C.io_sqring_offsets, flags)
	assert __offsetof(SqringOffsets, dropped) == __offsetof(C.io_sqring_offsets, dropped)
	assert __offsetof(SqringOffsets, array) == __offsetof(C.io_sqring_offsets, array)

	assert __offsetof(CqringOffsets, head) == __offsetof(C.io_cqring_offsets, head)
	assert __offsetof(CqringOffsets, tail) == __offsetof(C.io_cqring_offsets, tail)
	assert __offsetof(CqringOffsets, ring_mask) == __offsetof(C.io_cqring_offsets, ring_mask)
	assert __offsetof(CqringOffsets, ring_entries) == __offsetof(C.io_cqring_offsets, ring_entries)
	assert __offsetof(CqringOffsets, overflow) == __offsetof(C.io_cqring_offsets, overflow)
	assert __offsetof(CqringOffsets, cqes) == __offsetof(C.io_cqring_offsets, cqes)
	assert __offsetof(CqringOffsets, flags) == __offsetof(C.io_cqring_offsets, flags)

	assert __offsetof(GeteventsArg, sigmask) == __offsetof(C.io_uring_getevents_arg, sigmask)
	assert __offsetof(GeteventsArg, sigmask_sz) == __offsetof(C.io_uring_getevents_arg, sigmask_sz)
	assert __offsetof(GeteventsArg, ts) == __offsetof(C.io_uring_getevents_arg, ts)
	assert __offsetof(RsrcUpdate, offset) == __offsetof(C.io_uring_rsrc_update, offset)
	assert __offsetof(RsrcUpdate, data) == __offsetof(C.io_uring_rsrc_update, data)
}

fn test_abi_constants_match_the_kernel_header() {
	assert ioring_op_poll_add == u8(C.IORING_OP_POLL_ADD)
	assert ioring_op_timeout == u8(C.IORING_OP_TIMEOUT)
	assert ioring_op_accept == u8(C.IORING_OP_ACCEPT)
	assert ioring_op_send == u8(C.IORING_OP_SEND)
	assert ioring_op_recv == u8(C.IORING_OP_RECV)
	assert ioring_accept_multishot == u16(C.IORING_ACCEPT_MULTISHOT)
	assert ioring_off_sq_ring == isize(C.IORING_OFF_SQ_RING)
	assert ioring_off_cq_ring == isize(C.IORING_OFF_CQ_RING)
	assert ioring_off_sqes == isize(C.IORING_OFF_SQES)
	assert ioring_feat_single_mmap == u32(C.IORING_FEAT_SINGLE_MMAP)
	assert ioring_feat_ext_arg == u32(C.IORING_FEAT_EXT_ARG)
	assert ioring_enter_getevents == u32(C.IORING_ENTER_GETEVENTS)
	assert ioring_enter_ext_arg == u32(C.IORING_ENTER_EXT_ARG)
	assert ioring_enter_registered_ring == u32(C.IORING_ENTER_REGISTERED_RING)
	assert ioring_register_ring_fds == int(C.IORING_REGISTER_RING_FDS)
	assert ioring_unregister_ring_fds == int(C.IORING_UNREGISTER_RING_FDS)
	assert ioring_sq_cq_overflow == u32(C.IORING_SQ_CQ_OVERFLOW)
	assert ioring_sq_taskrun == u32(C.IORING_SQ_TASKRUN)
	assert setup_coop_taskrun == u32(C.IORING_SETUP_COOP_TASKRUN)
	assert setup_single_issuer == u32(C.IORING_SETUP_SINGLE_ISSUER)
	assert setup_defer_taskrun == u32(C.IORING_SETUP_DEFER_TASKRUN)
	assert setup_no_sqarray == u32(C.IORING_SETUP_NO_SQARRAY)
	assert ioring_cqe_f_more == u32(C.IORING_CQE_F_MORE)
}

// The setup flag combinations the server's init ladder asks for (iou_init_ring).
const setup_flag_sets = [setup_single_issuer | setup_defer_taskrun,
	setup_single_issuer | setup_coop_taskrun, u32(0)]

// new_test_ring sets a small ring up, or returns none (saying why) where
// io_uring is unavailable: a sandboxed runner, a kernel without that flag
// combination, or the VANILLA_NO_IOURING kill-switch CI sets on hosted runners.
// with_sq_array skips queue_init's IORING_SETUP_NO_SQARRAY attempt, so the
// SQ index array path runs on kernels that support both.
fn new_test_ring(flags u32, with_sq_array bool) ?Ring {
	if os.getenv('VANILLA_NO_IOURING') != '' {
		eprintln('skip: VANILLA_NO_IOURING is set')
		return none
	}
	mut r := Ring{}
	ret := if with_sq_array { setup_ring(8, &r, flags) } else { queue_init(8, &r, flags) }
	if ret != 0 {
		eprintln('skip: io_uring_setup(flags=0x${flags:x}) failed: ${ret}')
		return none
	}
	return r
}

fn test_nop_batches_wrap_both_rings() {
	for flags in setup_flag_sets {
		for with_sq_array in [false, true] {
			mut r := new_test_ring(flags, with_sq_array) or { continue }
			mut next := u64(0)
			mut seen := u64(0)
			mut cqes := unsafe { [3]&Cqe{} }
			// 5 rounds of a full SQ wrap both rings' indices more than once.
			for _ in 0 .. 5 {
				for {
					sqe := get_sqe(&r)
					if sqe == unsafe { nil } {
						break
					}
					unsafe {
						*sqe = Sqe{
							user_data: next // opcode 0 = IORING_OP_NOP
						}
					}
					next++
				}
				assert submit_and_wait(&r, r.sq_entries) == int(r.sq_entries)
				// Drain in batches smaller than the CQ, in completion order.
				for {
					n := peek_batch_cqe(&r, &cqes[0], 3)
					if n == 0 {
						break
					}
					for i in 0 .. int(n) {
						assert cqes[i].user_data == seen
						assert cqes[i].res == 0
						seen++
					}
					cq_advance(&r, n)
				}
			}
			assert next == 5 * u64(r.sq_entries)
			assert seen == next
			queue_exit(&r)
		}
	}
}

fn test_poll_completes_only_once_the_fd_is_ready() {
	for flags in setup_flag_sets {
		mut r := new_test_ring(flags, false) or { continue }
		p := os.pipe()!
		assert prepare_poll(&r, p.read_fd, pollin)
		assert submit(&r) == 1
		mut cqes := unsafe { [2]&Cqe{} }
		assert peek_batch_cqe(&r, &cqes[0], 2) == 0
		assert C.write(p.write_fd, c'x', 1) == 1
		assert submit_and_wait(&r, 1) >= 0
		n := peek_batch_cqe(&r, &cqes[0], 2)
		assert n == 1
		assert cqes[0].user_data == encode_user_data(op_poll, voidptr(usize(p.read_fd)))
		assert decode_ext_fd(cqes[0].user_data) == p.read_fd
		assert u32(cqes[0].res) & pollin != 0
		cq_advance(&r, n)
		assert peek_batch_cqe(&r, &cqes[0], 2) == 0
		C.close(p.read_fd)
		C.close(p.write_fd)
		queue_exit(&r)
	}
}

fn test_submit_and_wait_timeout_returns_etime() {
	mut r := new_test_ring(0, false) or { return }
	defer {
		queue_exit(&r)
	}
	assert r.features & ioring_feat_ext_arg != 0
	ts := KernelTimespec{
		tv_nsec: i64(20 * time.millisecond)
	}
	sw := time.new_stopwatch()
	assert submit_and_wait_timeout(&r, 1, &ts) == -C.ETIME
	assert sw.elapsed() >= 15 * time.millisecond
}

fn test_submit_and_wait_timeout_without_ext_arg_uses_a_timeout_sqe() {
	// The pre-5.11 path: hide IORING_FEAT_EXT_ARG so the timeout goes in as an SQE.
	mut r := new_test_ring(0, false) or { return }
	defer {
		queue_exit(&r)
	}
	r.features &= ~ioring_feat_ext_arg
	ts := KernelTimespec{
		tv_nsec: i64(20 * time.millisecond)
	}
	sw := time.new_stopwatch()
	assert submit_and_wait_timeout(&r, 1, &ts) == 1
	assert sw.elapsed() >= 15 * time.millisecond
	mut cqes := unsafe { [2]&Cqe{} }
	n := peek_batch_cqe(&r, &cqes[0], 2)
	assert n == 1
	assert cqes[0].user_data == timeout_user_data
	assert cqes[0].res == -C.ETIME
	// The server's dispatcher must not mistake it for one of its own ops.
	assert decode_op_type(cqes[0].user_data) !in [op_accept, op_read, op_write, op_poll,
		op_accept_resume]
	cq_advance(&r, n)
}

// The accept-pause timer (#256): a pure timer that completes with -ETIME after
// its duration, tagged with the caller's user_data, even though no other CQE
// ever arrives. The timespec it was given is gone by then: the kernel read it
// at submit.
fn test_prepare_timeout_fires_after_its_duration() {
	mut r := new_test_ring(0, false) or { return }
	defer {
		queue_exit(&r)
	}
	mut ts := KernelTimespec{
		tv_nsec: i64(20 * time.millisecond)
	}
	tag := encode_user_data(op_accept_resume, unsafe { nil })
	assert prepare_timeout(&r, &ts, tag)
	sw := time.new_stopwatch()
	assert submit(&r) == 1
	ts.tv_nsec = 0
	assert submit_and_wait(&r, 1) >= 0
	assert sw.elapsed() >= 15 * time.millisecond
	mut cqes := unsafe { [2]&Cqe{} }
	n := peek_batch_cqe(&r, &cqes[0], 2)
	assert n == 1
	assert cqes[0].user_data == tag
	assert decode_op_type(cqes[0].user_data) == op_accept_resume
	assert cqes[0].res == -C.ETIME
	cq_advance(&r, n)
}

fn test_registered_ring_fd_is_used_for_enter() {
	mut r := new_test_ring(0, false) or { return }
	defer {
		queue_exit(&r)
	}
	ret := register_ring_fd(&r)
	if ret < 0 {
		eprintln('skip: register_ring_fd failed: ${ret} (kernel < 5.18)')
		return
	}
	assert ret == 1
	assert r.enter_flags == ioring_enter_registered_ring
	assert r.enter_fd != r.ring_fd
	assert register_ring_fd(&r) == -C.EEXIST
	sqe := get_sqe(&r)
	unsafe {
		*sqe = Sqe{
			user_data: 42
		}
	}
	assert submit_and_wait(&r, 1) == 1
	mut cqes := unsafe { [1]&Cqe{} }
	assert peek_batch_cqe(&r, &cqes[0], 1) == 1
	assert cqes[0].user_data == 42
	cq_advance(&r, 1)
}

fn test_queue_exit_closes_the_ring() {
	mut r := new_test_ring(0, false) or { return }
	fd := r.ring_fd
	assert C.fcntl(fd, C.F_GETFD, 0) != -1
	queue_exit(&r)
	assert r.ring_fd == -1
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
	queue_exit(&r) // a second call is a no-op
}

fn test_io_uring_available_for_holds_all_probe_rings() {
	if os.getenv('VANILLA_NO_IOURING') != '' {
		return
	}
	mut r := new_test_ring(0, false) or { return }
	queue_exit(&r)
	assert io_uring_available_for(4)
}
