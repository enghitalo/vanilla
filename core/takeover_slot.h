#ifndef VANILLA_TAKEOVER_SLOT_H
#define VANILLA_TAKEOVER_SLOT_H

/*
 * Per-thread hand-off slot for connection takeover (issue #136 — the
 * conn-mode seam).
 *
 * A request handler only receives the socket fd and the write buffer — it has
 * no reference to the worker's connection state. This slot is the backend-
 * agnostic channel a handler uses to hand the CONNECTION itself over to a
 * different state machine (a core.ConnHandler): append the switching response
 * (e.g. HTTP/1.1 101), queue the takeover, return .done — the worker flips the
 * connection's mode right after the handler returns. Thread-local like the
 * sendfile slot: the single-threaded worker owning the connection is the only
 * reader/writer — no locking.
 *
 * The two pointers are opaque to C: `cont` is a V fn pointer (core.ConnHandler)
 * and `state` is the caller's per-connection protocol state. Both are only
 * stored and handed back.
 */

#include <stdbool.h>

#if defined(__TINYC__)
// tcc cannot codegen thread-local storage (see sendfile_slot.h). Under tcc the
// slot is compiled INERT: enable is a no-op and queue reports "not taken", so
// a handler's upgrade attempt degrades to its own fallback (an error response)
// — correct, just without protocol takeover. -prod keeps the real path.
static inline void vanilla_to_enable(void) {}

static inline bool vanilla_to_queue(void* cont, void* state) {
	(void)cont;
	(void)state;
	return false;
}

static inline bool vanilla_to_take(void** out_cont, void** out_state) {
	(void)out_cont;
	(void)out_state;
	return false;
}
#else

#if defined(_MSC_VER)
#define VANILLA_TO_THREAD_LOCAL __declspec(thread)
#else
#define VANILLA_TO_THREAD_LOCAL _Thread_local
#endif

typedef struct vanilla_to_slot {
	bool  enabled; // worker can flip a connection's mode (set once per capable worker)
	bool  queued;  // a takeover is waiting to be installed
	void* cont;    // the core.ConnHandler fn pointer
	void* state;   // caller-owned per-connection protocol state
} vanilla_to_slot;

static VANILLA_TO_THREAD_LOCAL vanilla_to_slot vanilla_to = {0};

static inline void vanilla_to_enable(void) {
	vanilla_to.enabled = true;
}

static inline bool vanilla_to_queue(void* cont, void* state) {
	if (!vanilla_to.enabled) {
		return false;
	}
	vanilla_to.cont = cont;
	vanilla_to.state = state;
	vanilla_to.queued = true;
	return true;
}

// Reads and clears a queued takeover. Returns false (leaving outputs
// untouched) when nothing is queued. Always clears `queued`, so the slot
// holds at most one request's hand-off and never leaks into the next request.
static inline bool vanilla_to_take(void** out_cont, void** out_state) {
	if (!vanilla_to.queued) {
		return false;
	}
	*out_cont = vanilla_to.cont;
	*out_state = vanilla_to.state;
	vanilla_to.queued = false;
	return true;
}

#endif // __TINYC__

#endif // VANILLA_TAKEOVER_SLOT_H
