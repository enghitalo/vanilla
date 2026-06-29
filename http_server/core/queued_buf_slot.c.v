module core

// V interface to the per-thread borrowed-buffer hand-off slot (see
// queued_buf_slot.h) — the send-from-memory analog of queue_file().
//
// A pure `(req, fd, out)` handler uses this to ask the running worker to send a
// large, immutable, process-lifetime buffer (e.g. a preloaded static asset's
// full response) DIRECTLY, instead of copying it through the per-connection
// write buffer. Only the io_uring worker (Linux) consumes it; on every other
// platform queue_buf() returns false and the caller writes the bytes itself.
//
// LINUX-ONLY implementation: the C slot (queued_buf_slot.h) is guarded by
// `#ifdef __linux__`, and every C call below is gated behind `$if linux`, so on
// macOS/Windows these are pure V stubs that compile to nothing platform-specific.

#include "@VMODROOT/http_server/core/queued_buf_slot.h"

fn C.vanilla_qb_enable()
fn C.vanilla_qb_set_allowed(allowed bool)
fn C.vanilla_qb_queue(ptr voidptr, len i64) bool
fn C.vanilla_qb_take(out_ptr &voidptr, out_len &i64) bool

// QueuedBuf is a borrowed memory region a worker should send as the whole
// response. The buffer is NOT owned by the worker and must stay alive and
// unmodified until the send completes.
pub struct QueuedBuf {
pub:
	ptr voidptr
	len i64
}

// enable_queue_buf marks the calling worker thread as able to consume a queued
// borrowed buffer. Call once per capable worker (the io_uring worker). No-op off
// Linux.
@[inline]
pub fn enable_queue_buf() {
	$if linux {
		C.vanilla_qb_enable()
	}
}

// set_queue_buf_allowed gates borrowing for the request about to be handled. The
// backend passes true only when the write buffer is empty, so a borrowed send is
// the sole response and can never be reordered relative to other pending bytes.
@[inline]
pub fn set_queue_buf_allowed(allowed bool) {
	$if linux {
		C.vanilla_qb_set_allowed(allowed)
	}
}

// queue_buf hands a borrowed buffer to the current worker, to be sent as the
// whole response. Returns false when the running backend can't borrow-send (not
// the io_uring worker, not allowed because other bytes are already pending, or
// not Linux) — the caller MUST then write the bytes itself. The buffer must
// outlive the send.
@[inline]
pub fn queue_buf(ptr voidptr, len i64) bool {
	$if linux {
		// The backend tracks the borrowed length as an int; reject anything that
		// would not round-trip (a >2 GiB single response is not a realistic borrowed
		// asset), so the caller falls back to writing the bytes itself.
		if len < 0 || len > i64(2147483647) {
			return false
		}
		return C.vanilla_qb_queue(ptr, len)
	} $else {
		return false
	}
}

// take_queued_buf returns the buffer a handler queued during the request just
// handled, or none. Always clears the slot, so it never leaks into the next
// request. Always none off Linux.
@[inline]
pub fn take_queued_buf() ?QueuedBuf {
	$if linux {
		mut ptr := unsafe { nil }
		mut len := i64(0)
		if C.vanilla_qb_take(&ptr, &len) {
			return QueuedBuf{
				ptr: ptr
				len: len
			}
		}
	}
	return none
}
