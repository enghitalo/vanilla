#ifndef VANILLA_QUEUED_BUF_SLOT_H
#define VANILLA_QUEUED_BUF_SLOT_H

/*
 * Per-thread hand-off slot for a BORROWED memory buffer (the send-from-memory
 * analog of sendfile_slot.h).
 *
 * A handler that wants to emit a large, immutable, process-lifetime buffer (e.g.
 * a preloaded static asset's full response) can hand it to the worker instead of
 * copying it through the per-connection write buffer. On the io_uring backend
 * that copy is expensive twice over: it memcpys the asset every request AND it
 * grows the per-conn response_buffer to the asset size, which the pool then frees
 * on release -> realloc churn + a multi-hundred-MB resident balloon at high
 * connection counts. Sending the borrowed buffer directly keeps response_buffer
 * at its base cap.
 *
 * LINUX-ONLY: the only consumer is the io_uring worker, which exists only on
 * Linux. The whole slot is therefore guarded by `#ifdef __linux__` so it adds
 * ZERO code on macOS/Windows (where core.queue_buf() is a V stub returning
 * false and the caller writes the bytes itself).
 *
 * The buffer is BORROWED: it must stay alive and unmodified until the send
 * completes. Static-asset responses are allocated once at boot and never freed or
 * mutated, so this holds.
 */

#include <stdbool.h>
#include <stdint.h>

#ifdef __linux__

#define VANILLA_QB_THREAD_LOCAL _Thread_local

typedef struct vanilla_qb_slot {
	bool        enabled; // worker can consume a queued buffer (set once per capable worker)
	bool        allowed; // borrowing is safe for the request being handled right now
	bool        queued;  // a buffer is waiting to be sent
	const void* ptr;     // borrowed (NOT owned/freed by the worker)
	int64_t     len;     // byte count to send
} vanilla_qb_slot;

static VANILLA_QB_THREAD_LOCAL vanilla_qb_slot vanilla_qb = {0};

static inline void vanilla_qb_enable(void) {
	vanilla_qb.enabled = true;
}

// Gate borrowing for the request about to be handled. The backend sets this to
// true only when the write buffer is empty (so a borrowed send is the whole
// response and cannot be reordered before/after other pending bytes).
static inline void vanilla_qb_set_allowed(bool allowed) {
	vanilla_qb.allowed = allowed;
}

static inline bool vanilla_qb_queue(const void* ptr, int64_t len) {
	if (!vanilla_qb.enabled || !vanilla_qb.allowed) {
		return false;
	}
	vanilla_qb.ptr = ptr;
	vanilla_qb.len = len;
	vanilla_qb.queued = true;
	return true;
}

// Reads and clears a queued buffer. Returns false (outputs untouched) when none
// is queued. Always clears `queued`, so the slot holds at most one request's
// hand-off and never leaks into the next request.
static inline bool vanilla_qb_take(const void** out_ptr, int64_t* out_len) {
	if (!vanilla_qb.queued) {
		return false;
	}
	*out_ptr = vanilla_qb.ptr;
	*out_len = vanilla_qb.len;
	vanilla_qb.queued = false;
	return true;
}

#endif // __linux__

#endif // VANILLA_QUEUED_BUF_SLOT_H
