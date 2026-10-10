module core

// Server push (vanilla#230): reaching a connection from any thread, and being
// told when it goes away.
//
// A taken-over connection (core.queue_takeover: WebSocket, SSE, h2) can
// SUBSCRIBE (event_loop.subscribe): it registers a wake fn, a core.WakeFn,
// that its OWN worker calls between client bursts, never concurrently with
// the connection's ConnHandler, for every event that is not a client byte:
//
//   .posted   — someone posted to the connection's ConnHandle (post_wake /
//               post_bytes, from any thread): event_loop.post_tag() and
//               event_loop.post_data() (a view valid during the call);
//   .timeout  — the timer armed with event_loop.wake_after(ms) expired;
//   .shutdown — Server.shutdown() was called (the mailbox is on): say
//               goodbye, e.g. a WebSocket close 1001, and return .close;
//   .closed   — the LAST call: the connection is gone, for whatever reason
//               (peer, error, timeout, pending-write cap, shutdown). `response`
//               is scratch. Unsubscribe from your registries and free the
//               subscription's state here: nothing references it after.
//
// The wake fn's parameters, as a WakeFn: ready_fd is the connection's fd,
// ready_fd_error is false, watch_payload is the sub_state given to subscribe.
// It appends to `response` (the connection's write buffer, as a ConnHandler
// does) and returns .done (keep going) or .close (what was appended is sent,
// then the connection closes; meanwhile it reads nothing more). A wake fn
// does not park: .suspend counts as .done and any watch it armed is torn
// down. While subscribed, the connection keeps reading client bytes: waiting
// for application events does not need a watch, so a subscription neither
// parks the connection nor holds Server.shutdown(grace).
//
// The wake fn reuses WakeFn, with the reason, tag and data read through the
// event loop, rather than a second continuation type: the same helpers serve
// both, a watch continuation and a wake fn can be one function, and the
// signature every existing continuation has stays as it is.
//
// The epoll plain worker implements subscriptions (`.closed` and wake_after
// always; posts only with ServerConfig.push_mailbox_slots > 0). Everywhere
// else subscribe returns a nil handle and posts report .unsupported.

// ConnHandle addresses one connection from any thread. It is a value (32
// bytes): copy it into your registries freely. The owning worker checks the
// generation on every delivery: `epoch` is that worker's close stamp for the
// fd when the handle was taken, and every close of the fd changes it. A
// handle taken before a close therefore never reaches the connection that
// later reuses the fd number: the post is dropped, and counted, on the owner.
pub struct ConnHandle {
pub:
	post  PostFn = unsafe { nil } // backend-installed; nil = no mailbox (posts report .unsupported)
	mbox  voidptr // the owning worker's mailbox, opaque to core
	fd    int = -1 // -1 = the nil handle: the backend cannot subscribe
	epoch u64 // the owning worker's close stamp for fd when the handle was taken
}

// PostFn is the backend's enqueue: never blocks, safe from any thread.
pub type PostFn = fn (mbox voidptr, fd int, epoch u64, tag u64, data []u8) PostResult

// PostResult is what a post did. .ok means ENQUEUED: a handle whose
// connection is gone is detected (and dropped) later, on its worker.
pub enum PostResult {
	ok          // enqueued
	full        // the owning worker's mailbox is full: retry, shed or coalesce
	too_big     // data does not fit a mailbox slot: keep it in your store, post a tag
	unsupported // nil handle, a backend without a mailbox, or push_mailbox_slots = 0
}

// is_nil reports whether this handle addresses nothing (subscribe was not
// possible here).
@[inline]
pub fn (h ConnHandle) is_nil() bool {
	return h.fd < 0
}

// post_wake wakes the connection with .posted and `tag` (no data). Never
// blocks; safe from any thread.
pub fn (h ConnHandle) post_wake(tag u64) PostResult {
	if h.post == unsafe { nil } || h.fd < 0 {
		return .unsupported
	}
	return h.post(h.mbox, h.fd, h.epoch, tag, []u8{})
}

// post_bytes wakes the connection with .posted, `tag` and a copy of `data`
// (inline in the mailbox slot, so nothing is allocated). Larger data reports
// .too_big: keep it in your store and post its tag. Never blocks; safe from
// any thread.
pub fn (h ConnHandle) post_bytes(tag u64, data []u8) PostResult {
	if h.post == unsafe { nil } || h.fd < 0 {
		return .unsupported
	}
	return h.post(h.mbox, h.fd, h.epoch, tag, data)
}

// SubscribeFn and WakeAfterFn are the backend-installed hooks behind
// EventLoop.subscribe / wake_after (named types, as RegisterFn). nil where
// the backend has no subscriptions.
pub type SubscribeFn = fn (mut event_loop EventLoop, wake_fn WakeFn, sub_state voidptr) ConnHandle

pub type WakeAfterFn = fn (mut event_loop EventLoop, ms int) bool

// subscribe registers `wake_fn` on the current connection (see the top of
// this file) and returns its handle. Call it from the upgrade handler right
// after core.queue_takeover, or later from the connection's ConnHandler or
// one of its continuations. A connection that is not (being) taken over
// cannot subscribe: HTTP/1.1 bytes pushed between responses would corrupt the
// stream. Subscribing again replaces the wake fn and its state (same handle).
// Returns the nil handle where subscriptions are not supported.
pub fn (mut event_loop EventLoop) subscribe(wake_fn WakeFn, sub_state voidptr) ConnHandle {
	if event_loop.subscribe_hook == unsafe { nil } || wake_fn == unsafe { nil } {
		return ConnHandle{}
	}
	return event_loop.subscribe_hook(mut event_loop, wake_fn, sub_state)
}

// wake_after arms a one-shot timer on the current, subscribed connection: in
// `ms` milliseconds its wake fn runs with .timeout (WebSocket pings, missed
// pong reaping, SSE heartbeats). Re-arming replaces the timer; ms <= 0
// cancels it. It needs no Limits timeout. False when the connection has no
// subscription or the backend has no timers.
pub fn (mut event_loop EventLoop) wake_after(ms int) bool {
	if event_loop.wake_after_hook == unsafe { nil } {
		return false
	}
	return event_loop.wake_after_hook(mut event_loop, ms)
}

// reason is why the running continuation or wake fn was called.
@[inline]
pub fn (event_loop &EventLoop) reason() WakeReason {
	return event_loop.reason
}

// post_tag is the tag of the post a wake fn is delivering (.posted), else 0.
@[inline]
pub fn (event_loop &EventLoop) post_tag() u64 {
	return event_loop.post_tag
}

// post_data is the data of the post a wake fn is delivering (.posted; empty
// for post_wake): a view into the mailbox slot, valid only during the call.
@[inline]
pub fn (event_loop &EventLoop) post_data() []u8 {
	if event_loop.post_len <= 0 {
		return []u8{}
	}
	return unsafe { (&u8(event_loop.post_ptr)).vbytes(event_loop.post_len) }
}
