#ifndef VANILLA_SENDFILE_SLOT_H
#define VANILLA_SENDFILE_SLOT_H

/*
 * Per-thread hand-off slot for sendfile(2).
 *
 * A request handler only receives the socket fd and the write buffer — it has
 * no reference to the worker's connection state. This slot is the backend-
 * agnostic channel a handler uses to ask the worker to send a file region with
 * sendfile(2) AFTER the headers it appended to the write buffer. It is a thread-
 * local, so the single-threaded worker that owns the current connection is the
 * only reader/writer — no locking, no cross-thread sharing.
 *
 * Pure C11 _Thread_local (with an MSVC fallback) keeps this independent of V's
 * `-enable-globals`, and the whole thing is inert on backends/OSes that never
 * call va_sf_enable(): va_sf_queue() then reports "not taken" and the handler
 * falls back to writing the body bytes itself.
 */

#include <stdbool.h>
#include <stdint.h>

#if defined(__TINYC__)
// tcc cannot codegen thread-local storage: "_Thread_local is not implemented"
// (and `__thread` is rejected too) — verified with V's bundled tccbin
// (thirdparty-linux-amd64) on both Linux and macOS. tcc is a dev-only fast
// compiler, so under it the whole slot is compiled INERT: enable is a no-op,
// queue/take report "not taken", and every caller falls back to writing the
// body bytes itself (correct, just without the sendfile(2) optimization).
// The static is not even declared — a plain non-TLS static would be SHARED
// across worker threads, a data race. -prod (clang/gcc) keeps the real
// _Thread_local fast path everywhere.
static inline void vanilla_sf_enable(void) {}

static inline bool vanilla_sf_queue(int file_fd, int64_t off, int64_t len) {
	(void)file_fd;
	(void)off;
	(void)len;
	return false;
}

static inline bool vanilla_sf_take(int* out_fd, int64_t* out_off, int64_t* out_len) {
	(void)out_fd;
	(void)out_off;
	(void)out_len;
	return false;
}
#else

#if defined(_MSC_VER)
#define VANILLA_THREAD_LOCAL __declspec(thread)
#else
#define VANILLA_THREAD_LOCAL _Thread_local
#endif

typedef struct vanilla_sf_slot {
	bool    enabled; // worker can consume a queued file (set once per capable worker)
	bool    queued;  // a file region is waiting to be sent
	int     file_fd; // borrowed (NOT owned/closed by the worker)
	int64_t off;     // byte offset to start from
	int64_t len;     // byte count to send
} vanilla_sf_slot;

static VANILLA_THREAD_LOCAL vanilla_sf_slot vanilla_sf = {0};

static inline void vanilla_sf_enable(void) {
	vanilla_sf.enabled = true;
}

static inline bool vanilla_sf_queue(int file_fd, int64_t off, int64_t len) {
	if (!vanilla_sf.enabled) {
		return false;
	}
	vanilla_sf.file_fd = file_fd;
	vanilla_sf.off = off;
	vanilla_sf.len = len;
	vanilla_sf.queued = true;
	return true;
}

// Reads and clears a queued file region. Returns false (leaving outputs
// untouched) when nothing is queued. Always clears `queued`, so the slot holds
// at most one request's hand-off and never leaks into the next request.
static inline bool vanilla_sf_take(int* out_fd, int64_t* out_off, int64_t* out_len) {
	if (!vanilla_sf.queued) {
		return false;
	}
	*out_fd = vanilla_sf.file_fd;
	*out_off = vanilla_sf.off;
	*out_len = vanilla_sf.len;
	vanilla_sf.queued = false;
	return true;
}

#endif // __TINYC__

#endif // VANILLA_SENDFILE_SLOT_H
